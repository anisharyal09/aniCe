// SPDX-License-Identifier: GPL-3.0-or-later
// Connects one trusted Mac before native background approval and fences retired enrollment results.
package io.github.anisharyal09.anice.features.backgroundprobe

import android.app.Application
import android.bluetooth.le.ScanFilter
import android.companion.AssociationInfo
import android.companion.AssociationRequest
import android.companion.BluetoothLeDeviceFilter
import android.companion.CompanionDeviceManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.IntentSender
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.os.SystemClock
import androidx.compose.runtime.*
import androidx.core.content.ContextCompat
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import io.github.anisharyal09.anice.AniCeApplication
import io.github.anisharyal09.anice.infrastructure.bluetooth.BlePayloadCodec
import io.github.anisharyal09.anice.infrastructure.connections.CompanionProbe
import io.github.anisharyal09.anice.infrastructure.connections.CompanionSetupTarget
import io.github.anisharyal09.anice.infrastructure.connections.companionSetupPeerMatches
import io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity
import java.util.UUID
import kotlinx.coroutines.*

internal enum class CompanionSetupPhase {
    READY, CONNECTING, PERMISSION, PREPARING, APPROVAL, SAVING, FAILED;
    val busy get() = this !in listOf(READY, FAILED)
    // Android owns the visible scan/approval progress once its IntentSender is claimed.
    val showsProgress get() = busy && this != APPROVAL
}

/** One UI launch per attempt, independent of recomposition, focus and activity recreation. */
internal class CompanionApprovalGate {
    private var claimed = -1
    fun claim(generation: Int): Boolean {
        if (generation <= claimed) return false
        claimed = generation
        return true
    }
    fun owns(generation: Int) = claimed == generation
}

internal data class CompanionApproval(val generation: Int, val sender: IntentSender)
internal data class CompanionAssociation(val address: String?, val id: Int)

/** No broad chooser or wire-supplied address: this filter names only the authenticated native locator. */
internal fun companionApprovalFilter(target: CompanionSetupTarget): BluetoothLeDeviceFilter =
    BluetoothLeDeviceFilter.Builder().setScanFilter(ScanFilter.Builder()
        .setServiceUuid(ParcelUuid(UUID.fromString(BlePayloadCodec.SERVICE_UUID)))
        .setDeviceAddress(target.address).build()).build()

// Android owns the consent title and body; the filter only pins the authenticated Mac. Do not use
// hidden profile/self-managed APIs to impersonate different platform copy or extra permissions.
internal fun companionApprovalRequest(target: CompanionSetupTarget): AssociationRequest =
    AssociationRequest.Builder().addDeviceFilter(companionApprovalFilter(target)).setSingleDevice(true).build()

@Suppress("DEPRECATION") // Android 12/12L return a BluetoothDevice instead of AssociationInfo.
internal class CompanionSetupViewModel(application: Application) : AndroidViewModel(application) {
    private val app = application as AniCeApplication
    private val controller get() = app.sessionController
    private val probe get() = CompanionProbe.get(app)
    private val manager get() = app.getSystemService(CompanionDeviceManager::class.java)
    private var closed = false
    private var generation = 0
    private var probeToken = -1
    // Keep in-flight result ownership after cancellation; it cannot be attributed to a later request.
    private var chooserGeneration by mutableStateOf<Int?>(null)
    private var permissionGeneration by mutableStateOf<Int?>(null)
    private var permissionContinuation: Int? = null
    private val approvalGate = CompanionApprovalGate()
    private var savingAssociation: CompanionAssociation? = null
    private var work: Job? = null
    private var expiry: Job? = null
    private var target: CompanionSetupTarget? = null
    var peer by mutableStateOf<DeviceIdentity?>(null)
        private set
    var phase by mutableStateOf(CompanionSetupPhase.READY)
        private set
    var notice by mutableStateOf("")
        private set
    var showing by mutableStateOf(false)
        private set
    var startRequested by mutableStateOf(false)
        private set
    var pendingApproval by mutableStateOf<CompanionApproval?>(null)
        private set
    var permissionRequest by mutableStateOf<Int?>(null)
        private set
    val canStart get() = !closed && !showing && !startRequested && !phase.busy &&
        chooserGeneration == null && permissionGeneration == null
    val canRetry get() = !closed && phase == CompanionSetupPhase.FAILED &&
        chooserGeneration == null && permissionGeneration == null

    private val screenOff = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (showing && intent?.action == Intent.ACTION_SCREEN_OFF) dismiss()
        }
    }
    init {
        ContextCompat.registerReceiver(app, screenOff, IntentFilter(Intent.ACTION_SCREEN_OFF),
            ContextCompat.RECEIVER_NOT_EXPORTED)
    }

    /** Nearby pairing, QR/PIN pairing and Devices all enter the same retained request. */
    fun start(trusted: DeviceIdentity) {
        if (!canStart) return
        peer = trusted
        notice = ""
        // Re-enabling an existing association is a quiet resume; the inline setup card is only
        // needed when Android must ask again or when a failure needs an explicit retry.
        showing = !canResumeQuietly(trusted)
        phase = CompanionSetupPhase.READY
        startRequested = true
    }

    /** An armed Mac with a live association only needs the silent resume fast path. */
    private fun canResumeQuietly(trusted: DeviceIdentity): Boolean =
        controller.missingPermissions().isEmpty() &&
            hasConnectionSetup(trusted, probe.peerId, probe.fingerprint) &&
            runCatching { probe.associationAvailable() }.getOrDefault(false)

    /** Only resumed presentation starts work; recreating a process never queues an old request. */
    fun startWhenReady() {
        permissionContinuation?.let { op ->
            permissionContinuation = null
            prepare(op)
            return
        }
        if (!startRequested) return
        startRequested = false
        enable()
    }

    fun retry() { if (canRetry) enable() }

    private fun enable() {
        if (closed || peer == null || phase.busy || chooserGeneration != null || permissionGeneration != null) return
        notice = ""
        val op = ++generation
        if (!probe.available || peer?.platform != "macos") {
            fail("Auto connect is unavailable on this phone.", op)
        } else if (controller.missingPermissions().isNotEmpty()) {
            phase = CompanionSetupPhase.PERMISSION
            permissionRequest = op
        } else prepare(op)
    }

    private fun prepare(op: Int) {
        if (!current(op)) return
        phase = CompanionSetupPhase.CONNECTING
        launchWork {
            try {
                val selected = requireNotNull(peer)
                check(unlocked() && controller.foreground)
                val configured = hasConnectionSetup(selected, probe.peerId, probe.fingerprint)
                val trusted = probe.trustedPeer(selected.deviceId, selected.fingerprint.takeIf { configured })
                check(companionSetupPeerMatches(selected, trusted))
                check(current(op) && unlocked())
                if (configured && probe.associationAvailable()) {
                    phase = CompanionSetupPhase.PREPARING
                    check(hasConnectionSetup(selected, probe.peerId, probe.fingerprint))
                    if (!probe.armed) probe.resumeNow(stillCurrent = {
                        current(op) && unlocked() &&
                            hasConnectionSetup(selected, probe.peerId, probe.fingerprint)
                    })
                    succeed(op)
                    return@launchWork
                }
                // The fast path is the only invisible one; fresh connection or approval gets the card.
                showing = true
                withTimeout(45_000) { controller.connectForCompanionSetup(selected) }
                check(current(op) && unlocked())
                // Replace only after this Mac is verified; keep its secured foreground link intact.
                if (probe.peerId != null || probe.address != null)
                    probe.stop("Auto-connect setup changed.", preserveForegroundSession = true)
                val expected = requireNotNull(controller.beginCompanionSetup(selected))
                target = expected
                probeToken = probe.beginSetup()
                expiry = viewModelScope.launch {
                    delay((expected.expiresAt - SystemClock.elapsedRealtime()).coerceAtLeast(0))
                    fail("Setup expired. Try again.", op)
                }
                phase = CompanionSetupPhase.PREPARING
                if (!app.companionSetup.prepare(expected)) {
                    fail("Your Mac couldn't prepare auto connect. Try again when connected.", op)
                    return@launchWork
                }
                check(current(op) && controller.companionSetupCurrent(expected))
                associate(expected, op)
            } catch (error: TimeoutCancellationException) {
                fail("Couldn't connect to your Mac. Keep it nearby and try again.", op)
            } catch (error: CancellationException) {
                currentCoroutineContext().ensureActive()
                fail("Auto-connect setup was cancelled.", op)
            }
            catch (_: Exception) { fail("Couldn't set up auto connect. Keep your Mac connected and try again.", op) }
        }
    }

    private fun associate(expected: CompanionSetupTarget, op: Int) {
        val callback = object : CompanionDeviceManager.Callback() {
            override fun onDeviceFound(sender: IntentSender) = pending(sender)
            override fun onAssociationPending(sender: IntentSender) = pending(sender)
            private fun pending(sender: IntentSender) {
                if (!current(op) || phase != CompanionSetupPhase.PREPARING ||
                    approvalGate.owns(op) || pendingApproval != null) return
                if (!unlocked() || !controller.companionSetupCurrent(expected)) {
                    fail("Setup expired. Try again.", op)
                    return
                }
                pendingApproval = CompanionApproval(op, sender)
            }
            override fun onAssociationCreated(info: AssociationInfo) {
                if (Build.VERSION.SDK_INT >= 33)
                    acceptAssociation(CompanionAssociation(info.deviceMacAddress?.toString(), info.id), op)
            }
            override fun onFailure(error: CharSequence?) { fail("Auto connect wasn't enabled.", op) }
        }
        val request = companionApprovalRequest(expected)
        if (Build.VERSION.SDK_INT >= 33)
            manager.associate(request, ContextCompat.getMainExecutor(app), callback)
        else manager.associate(request, callback, Handler(Looper.getMainLooper()))
    }

    fun claimPermission(op: Int): Array<String> {
        if (!current(op) || permissionRequest != op) return emptyArray()
        permissionRequest = null
        permissionGeneration = op
        return controller.missingPermissions()
    }
    fun permissionsReturned() {
        val op = permissionGeneration
        permissionGeneration = null
        if (op == null || !current(op) || phase != CompanionSetupPhase.PERMISSION) return
        if (controller.missingPermissions().isNotEmpty()) fail("Allow Nearby Devices in app settings to use auto connect.", op)
        else {
            permissionContinuation = op
            phase = CompanionSetupPhase.READY
        }
    }
    fun permissionLaunchFailed(op: Int) {
        if (permissionGeneration != op) return
        permissionGeneration = null
        fail("Bluetooth approval couldn't open. Try again.", op)
    }
    fun claimApproval(approval: CompanionApproval): IntentSender? {
        if (!current(approval.generation) || pendingApproval !== approval ||
            chooserGeneration != null || !approvalGate.claim(approval.generation)) return null
        val expected = target
        if (!unlocked() || expected == null || !controller.companionSetupCurrent(expected)) {
            fail("Setup expired. Try again.", approval.generation)
            return null
        }
        chooserGeneration = approval.generation
        android.util.Log.i("aniCe-setup", "approval_launch generation=${approval.generation}")
        pendingApproval = null
        phase = CompanionSetupPhase.APPROVAL
        return approval.sender
    }
    fun approvalLaunchFailed(op: Int) {
        if (chooserGeneration != op) return
        chooserGeneration = null
        fail("Android's approval couldn't open. Try again.", op)
    }
    fun approvalReturned(success: Boolean, association: CompanionAssociation?) {
        val op = chooserGeneration
        chooserGeneration = null
        if (op == null || !current(op)) {
            association?.let { removeAssociation(it.address, it.id) }
            if (!success && op != null && phase == CompanionSetupPhase.FAILED) dismiss()
            return
        }
        if (!success) dismiss() // Denial does not undo trust or repeatedly request approval.
        else if (association != null) acceptAssociation(association, op)
        else if (Build.VERSION.SDK_INT < 33) fail("Android returned no device. Try again.", op)
    }

    private fun acceptAssociation(association: CompanionAssociation, op: Int) {
        val address = association.address
        val id = association.id
        if (current(op) && phase == CompanionSetupPhase.SAVING &&
            savingAssociation?.let { it.id == id && address.equals(it.address, ignoreCase = true) } == true) return
        val expected = target
        if (!current(op) || !approvalGate.owns(op) || phase != CompanionSetupPhase.APPROVAL ||
            expected == null || address == null || !unlocked() ||
            !controller.companionSetupCurrent(expected) || !address.equals(expected.address, ignoreCase = true)) {
            removeAssociation(address, id)
            if (current(op)) fail("Setup changed. Try again.", op)
            return
        }
        savingAssociation = association
        phase = CompanionSetupPhase.SAVING
        launchWork {
            try {
                probe.arm(expected.peer, address, id, probeToken, stillCurrent = {
                    current(op) && unlocked() && target === expected && controller.companionSetupCurrent(expected)
                })
                succeed(op)
            } catch (error: CancellationException) { throw error }
            catch (_: Exception) { fail("Auto connect couldn't be enabled. Try again.", op) }
            finally { removeAssociation(address, id) }
        }
    }

    fun dismiss() {
        generation++
        startRequested = false
        releaseAttempt()
        phase = CompanionSetupPhase.READY
        showing = false
        notice = ""
    }
    fun presentationStopped(changingConfigurations: Boolean) {
        // Android's chooser can cover Home; unrelated background loss cannot defer an approval until later.
        // A quiet resume still owns connection work even when no inline card is visible.
        if ((showing || startRequested || phase.busy) && !changingConfigurations &&
            chooserGeneration == null && permissionGeneration == null) dismiss()
    }
    private fun succeed(op: Int) { if (current(op)) dismiss() }
    private fun fail(message: String, op: Int) {
        if (!current(op)) return
        android.util.Log.i("aniCe-setup", "setup_failed generation=$op phase=$phase")
        generation++
        startRequested = false
        releaseAttempt()
        phase = CompanionSetupPhase.FAILED
        notice = message
        // Quiet resumes stay invisible until they fail; then the user gets a clear retry path.
        showing = true
    }
    private fun current(op: Int) = !closed && op == generation
    private fun unlocked() = app.getSystemService(android.app.KeyguardManager::class.java)?.isKeyguardLocked != true
    private fun launchWork(block: suspend () -> Unit) {
        val job = viewModelScope.launch(start = CoroutineStart.LAZY) {
            try { block() } finally { if (work === currentCoroutineContext().job) work = null }
        }
        work = job
        job.start()
    }
    private fun releaseAttempt() {
        work?.cancel(); work = null
        expiry?.cancel(); expiry = null
        pendingApproval = null
        permissionRequest = null
        permissionContinuation = null
        savingAssociation = null
        probe.cancelSetup(probeToken)
        probeToken = -1
        target?.let { app.companionSetup.finish(it); controller.endCompanionSetup(it) }
        target = null
    }
    private fun removeAssociation(address: String?, id: Int) {
        val tracked = if (Build.VERSION.SDK_INT >= 33 && id >= 0)
            probe.associationId == id && address != null && address.equals(probe.address, ignoreCase = true)
        else address != null && address.equals(probe.address, ignoreCase = true)
        if (tracked) return
        try {
            if (Build.VERSION.SDK_INT >= 33 && id >= 0) manager.disassociate(id)
            else if (address != null) manager.disassociate(address)
        } catch (_: IllegalArgumentException) {} catch (_: SecurityException) {}
    }
    override fun onCleared() {
        closed = true
        generation++
        releaseAttempt()
        app.unregisterReceiver(screenOff)
    }
}
