// SPDX-License-Identifier: GPL-3.0-or-later
// Owns user-initiated update checks, private downloads and Android installer sessions.
package io.github.anisharyal09.anice.update

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
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

internal class AndroidUpdateManager(context: Context) {
    private val app = context.applicationContext
    private val discovery = ReleaseDiscovery(app)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var checkJob: Job? = null
    private var downloadJob: Job? = null
    private var downloaded: File? = null
    private val _status = MutableStateFlow<UpdateStatus>(UpdateStatus.Idle)
    val status: StateFlow<UpdateStatus> = _status.asStateFlow()
    private val _available = MutableStateFlow<AvailableRelease?>(null)
    val available: StateFlow<AvailableRelease?> = _available.asStateFlow()
    private val _includeBeta = MutableStateFlow(discovery.includeBeta)
    val includeBeta: StateFlow<Boolean> = _includeBeta.asStateFlow()
    private val prefs = app.getSharedPreferences("update_preferences", Context.MODE_PRIVATE)
    private val directory = File(app.cacheDir, "updates")

    init {
        // Remove downloads from prior processes; installer sessions own their copied bytes.
        directory.listFiles()?.forEach { it.delete() }
    }

    fun check(force: Boolean = false) {
        if (checkJob?.isActive == true || downloadJob?.isActive == true || _status.value == UpdateStatus.Installing ||
            _status.value is UpdateStatus.AwaitingConfirmation || _status.value == UpdateStatus.PermissionRequired) return
        checkJob = scope.launch {
            val currentName = app.packageManager.getPackageInfo(app.packageName, 0).versionName.orEmpty()
            val current = UpdateVersion.parse("v$currentName")
            if (current == null) { _status.value = UpdateStatus.Failed("Installed version is not supported for update checks."); return@launch }
            _status.value = UpdateStatus.Checking
            when (val result = discovery.check(current, force)) {
                is DiscoveryResult.Available -> { _available.value = result.release; _status.value = UpdateStatus.Idle }
                DiscoveryResult.UpToDate -> { _available.value = null; _status.value = UpdateStatus.UpToDate }
                DiscoveryResult.Deferred -> { _available.value = null; _status.value = UpdateStatus.Idle }
                is DiscoveryResult.Failed -> _status.value = UpdateStatus.Failed(result.message)
            }
        }
    }
    fun setIncludeBeta(value: Boolean) {
        discovery.includeBeta = value; _includeBeta.value = value
        if (!value && _available.value?.version?.prerelease == true && _status.value != UpdateStatus.Installing &&
            _status.value !is UpdateStatus.AwaitingConfirmation) {
            cancel(); _available.value = null
        }
        check(force = true)
    }
    fun skip() {
        if (_status.value == UpdateStatus.Installing || _status.value is UpdateStatus.AwaitingConfirmation) return
        _available.value?.let { discovery.skip(it.version.tag) }
        cancel(); _available.value = null
    }
    fun cancel() { downloadJob?.cancel(); downloadJob = null; downloaded?.delete(); downloaded = null; _status.value = UpdateStatus.Idle }

    fun downloadAndInstall() {
        val release = _available.value ?: return
        if (downloadJob?.isActive == true || checkJob?.isActive == true) return
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
                                    _status.value = UpdateStatus.Downloading(bytes, release.assetBytes ?: length)
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
                prefs.edit().remove("installer_session").apply()
                downloaded?.delete(); downloaded = null; _available.value = null
                _status.value = UpdateStatus.Idle
            }
            else -> {
                prefs.edit().remove("installer_session").apply()
                downloaded?.delete(); downloaded = null
                _status.value = UpdateStatus.Failed(intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE) ?: "Android could not install the update.")
            }
        }
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
