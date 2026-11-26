// SPDX-License-Identifier: GPL-3.0-or-later
// Owns release checks, private downloads and Android installer sessions independently of review presentation.
package io.github.anisharyal09.anice.update

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.os.Build
import android.os.SystemClock
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.io.File
import java.net.URL
import java.util.zip.ZipFile
import javax.net.ssl.HttpsURLConnection

internal sealed interface UpdateStatus {
    data object Idle : UpdateStatus
    data object Checking : UpdateStatus
    data object UpToDate : UpdateStatus
    data class Downloading(val bytes: Long, val total: Long?) : UpdateStatus
    data object PermissionRequired : UpdateStatus
    data object Installing : UpdateStatus
    data class AwaitingConfirmation(val intent: Intent) : UpdateStatus
    data class Failed(val message: String) : UpdateStatus
}

internal class AndroidUpdateManager(
    context: Context,
    private val discovery: ReleaseDiscovery = ReleaseDiscovery(context),
    private val automaticLifecycleEnabled: Boolean = context.packageName == "io.github.anisharyal09.anice",
) {
    private val app = context.applicationContext
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var checkJob: Job? = null
    private var checkAgain = false
    private var checkAgainUserInitiated = false
    private var checkingAutomatically = false
    // Cached reads cannot replace results from newer checks or preference changes.
    private var selectionGeneration = 0L
    private var reviewGeneration = 0L
    private var reviewRestoreJob: Job? = null
    private var dismissRefreshJob: Job? = null
    private var foregroundActivities = 0
    private var downloadJob: Job? = null
    private var downloaded: File? = null
    private val _status = MutableStateFlow<UpdateStatus>(UpdateStatus.Idle)
    val status: StateFlow<UpdateStatus> = _status.asStateFlow()
    private val _available = MutableStateFlow<AvailableRelease?>(null)
    val available: StateFlow<AvailableRelease?> = _available.asStateFlow()
    private val _includeBeta = MutableStateFlow(discovery.includeBeta)
    val includeBeta: StateFlow<Boolean> = _includeBeta.asStateFlow()
    private val _automaticChecks = MutableStateFlow(discovery.automaticChecks)
    val automaticChecks: StateFlow<Boolean> = _automaticChecks.asStateFlow()
    val automaticSchedulingEnabled: Boolean get() = _automaticChecks.value && automaticLifecycleEnabled
    private val _reviewing = MutableStateFlow(false)
    val reviewing: StateFlow<Boolean> = _reviewing.asStateFlow()
    private val prefs = app.getSharedPreferences("update_preferences", Context.MODE_PRIVATE)
    private val directory = File(app.cacheDir, "updates")
    private val notification by lazy { UpdateNotification(app) }
    private val currentVersion = UpdateVersion.parse("v${app.packageManager.getPackageInfo(app.packageName, 0).versionName.orEmpty()}")

    init {
        // Remove downloads from prior processes; installer sessions own their copied bytes.
        directory.listFiles()?.forEach { it.delete() }
    }

    fun foregroundStarted() {
        foregroundActivities++
        if (!automaticLifecycleEnabled) return
        scope.launch {
            restoreCachedRelease()
            if (_available.value == null) notification.clear()
            if (_automaticChecks.value && discovery.nextAutomaticCheck() <= System.currentTimeMillis()) check()?.join()
            scheduleNextCheck()
        }
    }

    private suspend fun restoreCachedRelease() {
        if (_available.value != null) return
        val generation = selectionGeneration
        val cached = currentVersion?.let { discovery.cachedNotice(it) }
        if (generation == selectionGeneration && _available.value == null) {
            _available.value = cached?.takeIf(discovery::isEligible)
        }
    }

    fun foregroundStopped() { foregroundActivities = (foregroundActivities - 1).coerceAtLeast(0) }

    fun review(expectedTag: String? = null): Job? {
        val current = _available.value
        if (current != null && expectedTag != null && current.version.tag != expectedTag) return null
        val myReviewGen = ++reviewGeneration
        reviewRestoreJob?.cancel()
        reviewRestoreJob = null
        if (current != null) {
            showReview()
            return null
        }
        return scope.launch {
            restoreCachedRelease()
            val found = _available.value
            if (reviewGeneration == myReviewGen && found != null &&
                (expectedTag == null || found.version.tag == expectedTag)) showReview()
        }.also { reviewRestoreJob = it }
    }

    private fun showReview() {
        dismissRefreshJob?.cancel()
        dismissRefreshJob = null
        _reviewing.value = true
        notification.clear()
    }

    fun dismissReview(refreshAutomatic: Boolean = true) {
        reviewGeneration++
        reviewRestoreJob?.cancel()
        reviewRestoreJob = null
        val wasReviewing = _reviewing.value
        _reviewing.value = false
        if (!wasReviewing || !refreshAutomatic || !_automaticChecks.value) return
        dismissRefreshJob?.cancel()
        dismissRefreshJob = scope.launch { check()?.join(); scheduleNextCheck() }
    }

    fun hostDestroyed(changingConfigurations: Boolean) {
        if (!changingConfigurations) dismissReview(refreshAutomatic = false)
    }

    fun stopBackgroundCheck(job: Job?) {
        if (foregroundActivities == 0 && checkingAutomatically && job != null && job === checkJob) {
            // A queued explicit check is independent of the automatic job's lifetime.
            job.cancel()
        }
    }

    fun scheduleNextCheck() {
        if (!automaticSchedulingEnabled || currentVersion == null) {
            cancelScheduledUpdateCheck(app)
            return
        }
        val now = System.currentTimeMillis()
        val busy = (_reviewing.value && _available.value != null) || downloadJob?.isActive == true || _status.value == UpdateStatus.Installing ||
            _status.value is UpdateStatus.AwaitingConfirmation || _status.value == UpdateStatus.PermissionRequired
        scheduleUpdateCheck(app, if (busy) UpdateSchedule.latestEvening(now) + UpdateSchedule.DAY else discovery.nextAutomaticCheck(now))
    }

    fun check(force: Boolean = false, userInitiated: Boolean = force): Job? {
        if (!userInitiated && !_automaticChecks.value) return null
        checkJob?.takeIf { !it.isCompleted }?.let {
            if (force) {
                checkAgain = true
                checkAgainUserInitiated = checkAgainUserInitiated || userInitiated
            }
            return it
        }
        if ((!force && _reviewing.value && _available.value != null) || downloadJob?.isActive == true || _status.value == UpdateStatus.Installing ||
            _status.value is UpdateStatus.AwaitingConfirmation || _status.value == UpdateStatus.PermissionRequired) return null
        if (force) selectionGeneration++
        checkingAutomatically = !userInitiated
        // Publish ownership before immediate/cached completion or a queued check can replace it.
        val job = scope.launch(start = CoroutineStart.LAZY) {
            try {
                if (!force) {
                    reviewRestoreJob?.join()
                    if (_reviewing.value && _available.value != null) {
                        _status.value = UpdateStatus.Idle
                        return@launch
                    }
                    selectionGeneration++
                }
                val current = currentVersion
                if (current == null) { _status.value = UpdateStatus.Failed("Installed version is not supported for update checks."); return@launch }
                restoreCachedRelease()
                if (!force && _reviewing.value && _available.value != null) { _status.value = UpdateStatus.Idle; return@launch }
                _status.value = UpdateStatus.Checking
                val result = discovery.check(current, force)
                selectionGeneration++
                if (!force && _reviewing.value && _available.value != null && result !is DiscoveryResult.Failed) {
                    _status.value = UpdateStatus.Idle
                    return@launch
                }
                when (result) {
                    is DiscoveryResult.Available -> {
                        val found = result.release.takeIf(discovery::isEligible)
                        _available.value = found
                        if (found == null) dismissReview(refreshAutomatic = false)
                        _status.value = UpdateStatus.Idle
                        if (found != null && foregroundActivities == 0 && app.packageName == "io.github.anisharyal09.anice" &&
                            discovery.shouldNotify(found) && notification.post(found)) discovery.markNotified(found)
                    }
                    DiscoveryResult.UpToDate -> {
                        _available.value = null; dismissReview(refreshAutomatic = false)
                        _status.value = UpdateStatus.UpToDate; notification.clear()
                    }
                    DiscoveryResult.Deferred -> _status.value = UpdateStatus.Idle
                    is DiscoveryResult.Failed -> _status.value = UpdateStatus.Failed(result.message)
                }
            } finally {
                if (_status.value == UpdateStatus.Checking) _status.value = UpdateStatus.Idle
                checkJob = null
                checkingAutomatically = false
                if (checkAgain) {
                    val requestedByUser = checkAgainUserInitiated
                    checkAgain = false; checkAgainUserInitiated = false
                    check(force = true, userInitiated = requestedByUser)
                }
                else if (foregroundActivities > 0) scheduleNextCheck()
            }
        }
        checkJob = job
        job.start()
        return job
    }
    fun setAutomaticChecks(value: Boolean) {
        if (_automaticChecks.value == value) return
        discovery.automaticChecks = value
        _automaticChecks.value = value
        if (!value) {
            dismissRefreshJob?.cancel()
            dismissRefreshJob = null
            if (checkingAutomatically) {
                checkJob?.cancel()
                if (_status.value == UpdateStatus.Checking) _status.value = UpdateStatus.Idle
            }
            notification.clear()
        }
        scheduleNextCheck()
        if (value && foregroundActivities > 0 && automaticLifecycleEnabled) {
            val previous = checkJob
            scope.launch {
                previous?.join()
                if (_automaticChecks.value) check()?.join()
                scheduleNextCheck()
            }
        }
    }
    fun setIncludeBeta(value: Boolean) {
        selectionGeneration++
        discovery.includeBeta = value; _includeBeta.value = value
        if (!value) notification.clear()
        if (!value && _available.value?.version?.prerelease == true && _status.value != UpdateStatus.Installing &&
            _status.value !is UpdateStatus.AwaitingConfirmation) {
            cancel(); _available.value = null; dismissReview(refreshAutomatic = false); notification.clear()
        }
        if (_automaticChecks.value) check(force = true, userInitiated = false)
    }
    fun skip(version: UpdateVersion) {
        if (_available.value?.version != version) return
        if (_status.value == UpdateStatus.Installing || _status.value is UpdateStatus.AwaitingConfirmation) return
        selectionGeneration++
        _available.value?.let { discovery.skip(it.version.tag) }
        cancel(); _available.value = null; dismissReview(refreshAutomatic = false); notification.clear()
        scheduleNextCheck()
    }
    fun cancel() {
        downloadJob?.cancel(); downloadJob = null; downloaded?.delete(); downloaded = null
        _status.value = UpdateStatus.Idle; scheduleNextCheck()
    }

    fun downloadAndInstall(version: UpdateVersion) {
        val release = _available.value?.takeIf { it.version == version } ?: return
        if (downloadJob?.isActive == true || checkJob?.isCompleted == false) return
        downloadJob = scope.launch {
            var file: File? = null
            try {
                _status.value = UpdateStatus.Downloading(0, release.assetBytes)
                val staged = withContext(Dispatchers.IO) { download(release) }
                file = staged; downloaded = staged
                withContext(Dispatchers.IO) { validateApk(staged, release) }
                install()
            } catch (cancelled: CancellationException) {
                file?.delete(); if (downloaded == file) downloaded = null
                throw cancelled
            } catch (error: Exception) {
                file?.delete(); if (downloaded == file) downloaded = null
                _status.value = UpdateStatus.Failed(error.message ?: "Could not prepare the update.")
            } finally {
                if (downloadJob === currentCoroutineContext().job) {
                    downloadJob = null
                    scheduleNextCheck()
                }
            }
        }
    }

    private suspend fun download(release: AvailableRelease): File {
        require(directory.isDirectory || directory.mkdirs()) { "Cannot create update storage." }
        val file = File.createTempFile("update-", ".apk", directory)
        try {
            var target = URL(release.assetUrl)
            repeat(6) {
                require(trustedUpdateURL(target)) { "Untrusted update download address." }
                val connection = (target.openConnection() as HttpsURLConnection).apply {
                    connectTimeout = 15_000; readTimeout = 15_000; instanceFollowRedirects = false
                }
                try {
                    val status = connection.responseCode
                    if (status in 300..399) {
                        target = URL(target, connection.getHeaderField("Location") ?: error("Update redirect is missing."))
                    } else {
                        check(status == 200) { "Download failed (HTTP $status)." }
                        val length = connection.contentLengthLong.takeIf { it >= 0 }
                        require(length == null || length in 1..MAX_UPDATE_BYTES) { "Update size is invalid." }
                        require(release.assetBytes == null || length == null || release.assetBytes == length) { "Update size does not match the release." }
                        var bytes = 0L
                        var lastProgress = 0L
                        connection.inputStream.use { input -> file.outputStream().use { output ->
                            val buffer = ByteArray(64 * 1024)
                            while (true) {
                                currentCoroutineContext().ensureActive()
                                val count = input.read(buffer)
                                if (count < 0) break
                                currentCoroutineContext().ensureActive()
                                bytes += count
                                require(bytes <= MAX_UPDATE_BYTES) { "Update exceeds the size limit." }
                                output.write(buffer, 0, count)
                                val now = SystemClock.elapsedRealtime()
                                if (now - lastProgress >= 250 || bytes == (release.assetBytes ?: length)) {
                                    lastProgress = now
                                    withContext(Dispatchers.Main.immediate) {
                                        ensureActive()
                                        _status.value = UpdateStatus.Downloading(bytes, release.assetBytes ?: length)
                                    }
                                }
                            }
                        } }
                        require(bytes > 0 && (length == null || bytes == length) && (release.assetBytes == null || bytes == release.assetBytes)) { "Update download is incomplete." }
                        return file
                    }
                } finally { connection.disconnect() }
            }
            error("Too many update redirects.")
        } catch (error: Throwable) { file.delete(); throw error }
    }

    @Suppress("DEPRECATION")
    private fun validateApk(file: File, release: AvailableRelease) {
        ZipFile(file).use { require(it.size() > 0) { "Downloaded APK is empty." } }
        val manager = app.packageManager
        val candidate = manager.getPackageArchiveInfo(file.path, PackageManager.GET_SIGNING_CERTIFICATES) ?: error("Downloaded APK is invalid.")
        val installed = manager.getPackageInfo(app.packageName, PackageManager.GET_SIGNING_CERTIFICATES)
        require(candidate.packageName == app.packageName && candidate.versionName == release.version.tag.removePrefix("v") &&
            candidate.longVersionCode == release.version.code.toLong() && candidate.longVersionCode > installed.longVersionCode) { "Downloaded APK does not match this update." }
        require(compatibleSigners(installed, candidate)) { "Downloaded APK has a different signing identity." }
    }

    private fun compatibleSigners(installed: PackageInfo, candidate: PackageInfo): Boolean {
        val old = installed.signingInfo ?: return false
        val next = candidate.signingInfo ?: return false
        return compatibleSigningCertificates(
            old.hasMultipleSigners(), old.apkContentsSigners.map { it.toByteArray() },
            next.hasMultipleSigners(), next.apkContentsSigners.map { it.toByteArray() },
            next.signingCertificateHistory?.map { it.toByteArray() },
        )
    }

    fun install() {
        if (_status.value == UpdateStatus.Installing || _status.value is UpdateStatus.AwaitingConfirmation) return
        val file = downloaded
        if (file == null || !file.isFile || file.length() <= 0L) {
            downloaded = null
            _status.value = UpdateStatus.Failed("The downloaded update is no longer available. Download it again.")
            return
        }
        if (!app.packageManager.canRequestPackageInstalls()) { _status.value = UpdateStatus.PermissionRequired; return }
        _status.value = UpdateStatus.Installing
        scope.launch {
            try {
                withContext(Dispatchers.IO) {
                    val installer = app.packageManager.packageInstaller
                    val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL).apply {
                        setAppPackageName(app.packageName); setSize(file.length())
                        if (Build.VERSION.SDK_INT >= 31) setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_REQUIRED)
                    }
                    val id = installer.createSession(params)
                    try {
                        installer.openSession(id).use { session ->
                            session.openWrite("update.apk", 0, file.length()).use { output ->
                                file.inputStream().use { it.copyTo(output) }
                                output.flush()
                                session.fsync(output)
                            }
                            prefs.edit().putInt("installer_session", id).commit()
                            val intent = Intent(app, UpdateInstallReceiver::class.java).setAction("${app.packageName}.UPDATE_INSTALL")
                            val flags = PendingIntent.FLAG_UPDATE_CURRENT or if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0
                            val callback = PendingIntent.getBroadcast(app, id, intent, flags)
                            session.commit(callback.intentSender)
                        }
                    } catch (error: Exception) {
                        installer.abandonSession(id)
                        prefs.edit().remove("installer_session").apply()
                        throw error
                    }
                }
            } catch (error: Exception) { _status.value = UpdateStatus.Failed(error.message ?: "Could not open the Android installer.") }
        }
    }

    fun confirmationOpened() { _status.value = UpdateStatus.Installing }
    fun confirmationFailed() { _status.value = UpdateStatus.Failed("Could not open the Android installer.") }
    fun settingsFailed() { _status.value = UpdateStatus.Failed("Could not open Android install settings.") }

    @Suppress("DEPRECATION")
    fun onInstallStatus(intent: Intent) {
        val id = intent.getIntExtra(PackageInstaller.EXTRA_SESSION_ID, -1)
        if (id < 0 || id != prefs.getInt("installer_session", -2)) return
        when (intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                val action = if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
                    else intent.getParcelableExtra(Intent.EXTRA_INTENT)
                _status.value = if (action != null) UpdateStatus.AwaitingConfirmation(action) else UpdateStatus.Failed("Android did not provide an installation confirmation.")
            }
            PackageInstaller.STATUS_SUCCESS -> {
                selectionGeneration++
                prefs.edit().remove("installer_session").apply()
                downloaded?.delete(); downloaded = null; _available.value = null
                dismissReview(refreshAutomatic = false)
                notification.clear()
                _status.value = UpdateStatus.Idle
            }
            else -> {
                prefs.edit().remove("installer_session").apply()
                downloaded?.delete(); downloaded = null
                _status.value = UpdateStatus.Failed(intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE) ?: "Android could not install the update.")
            }
        }
        scheduleNextCheck()
    }
}

internal fun trustedUpdateURL(url: URL): Boolean = url.protocol == "https" && url.userInfo == null &&
    (url.port == -1 || url.port == 443) && url.host.lowercase() in setOf("github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com", "github-releases.githubusercontent.com")

class UpdateInstallReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != "${context.packageName}.UPDATE_INSTALL") return
        (context.applicationContext as io.github.anisharyal09.anice.AniCeApplication).updates.onInstallStatus(intent)
    }
}

// A rotation must contain the installed current signer in the candidate's proven lineage.
internal fun compatibleSigningCertificates(
    oldMultiple: Boolean, oldCurrent: List<ByteArray>, nextMultiple: Boolean,
    nextCurrent: List<ByteArray>, nextHistory: List<ByteArray>?,
): Boolean {
    if (oldCurrent.isEmpty() || nextCurrent.isEmpty()) return false
    if (oldMultiple || nextMultiple) {
        if (!oldMultiple || !nextMultiple) return false
        val oldSet = oldCurrent.map { it.toList() }.toSet()
        val nextSet = nextCurrent.map { it.toList() }.toSet()
        return oldSet.size == oldCurrent.size && nextSet.size == nextCurrent.size && oldSet == nextSet
    }
    val old = oldCurrent.singleOrNull() ?: return false
    val next = nextCurrent.singleOrNull() ?: return false
    val history = nextHistory ?: return false
    return history.isNotEmpty() && history.last().contentEquals(next) && history.any { it.contentEquals(old) }
}
