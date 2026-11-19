// SPDX-License-Identifier: GPL-3.0-or-later
// Retains one native enrollment attempt through activity recreation and fences late approval results.
package io.github.anisharyal09.anice.features.backgroundprobe

import android.app.Application
import android.bluetooth.le.ScanFilter
import android.companion.*
import android.content.IntentSender
import android.os.*
import androidx.compose.runtime.*
import androidx.core.content.ContextCompat
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import io.github.anisharyal09.anice.AniCeApplication
import io.github.anisharyal09.anice.infrastructure.bluetooth.BlePayloadCodec
import io.github.anisharyal09.anice.infrastructure.connections.CompanionProbe
import io.github.anisharyal09.anice.infrastructure.connections.CompanionSetupTarget
import io.github.anisharyal09.anice.infrastructure.connections.displayName
import io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity
import java.util.UUID
import kotlinx.coroutines.*

internal enum class CompanionSetupPhase {
    LOADING, READY, PREPARING, PERMISSION, APPROVAL, SAVING, COMPLETE, FAILED;
    val busy get() = this in listOf(LOADING, PREPARING, PERMISSION, APPROVAL, SAVING, COMPLETE)
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

@Suppress("DEPRECATION") // Android 12/12L return a BluetoothDevice instead of AssociationInfo.
internal class CompanionSetupViewModel(application: Application) : AndroidViewModel(application) {
    private val app = application as AniCeApplication
    private val controller get() = app.sessionController
    private val probe get() = CompanionProbe.get(app)
    private val manager get() = app.getSystemService(CompanionDeviceManager::class.java)
    private var initialized = false
    private var closed = false
    private var startRequested = false
    private var permissionContinuation: Int? = null
    private var quick = false
    private var finishOnSuccess = false
    private var generation = 0
    private var probeToken = -1
    // Do not discard an in-flight result on Cancel: it must not be attributed to a later attempt.
    private var chooserGeneration by mutableStateOf<Int?>(null)
    private var permissionGeneration by mutableStateOf<Int?>(null)
    private val approvalGate = CompanionApprovalGate()
    private var savingAssociation: CompanionAssociation? = null
    private var work: Job? = null
    private var expiry: Job? = null
    private var target: CompanionSetupTarget? = null
    var peer by mutableStateOf<DeviceIdentity?>(null)
        private set
    private var initialName by mutableStateOf("Your Mac")
    val peerName get() = peer?.displayName ?: initialName
    var phase by mutableStateOf(CompanionSetupPhase.LOADING)
        private set
    var notice by mutableStateOf("")
        private set
    var pendingApproval by mutableStateOf<CompanionApproval?>(null)
        private set
    var permissionRequest by mutableStateOf<Int?>(null)
        private set
    var complete by mutableStateOf(false)
        private set
    val configured get() = hasConnectionSetup(peer, probe.peerId, probe.fingerprint)
    val armed get() = configured && probe.armed
    val available get() = probe.available
    val policyStatus get() = probe.status
    val replacesOtherMac get() = probe.peerId != null && !configured
    val canEnable get() = automaticSetupReady(peer, available, phase.busy) &&
        chooserGeneration == null && permissionGeneration == null && !closed

    fun initialize(peerId: String?, quick: Boolean, enable: Boolean, restored: Boolean) {
        if (initialized) return
        initialized = true
        this.quick = quick
        finishOnSuccess = enable
        // Rotation retains this model. A new process never silently relaunches a lost chooser.
        startRequested = enable && !restored
        val selected = controller.selected
        if (selected != null && selected.deviceId == peerId) initialName = selected.displayName
        val op = generation
        viewModelScope.launch {
            try {
                val trusted = probe.trustedPeer(requireNotNull(peerId))
                if (!current(op)) return@launch
                peer = trusted
                phase = if (restored && enable) CompanionSetupPhase.FAILED else CompanionSetupPhase.READY
                if (restored && enable) notice = "Setup was interrupted. Your devices are still paired."
            } catch (error: CancellationException) { throw error }
            catch (_: Exception) { fail("Select a trusted Mac in Devices before enabling auto-reconnect.", op) }
        }
    }

    /** The activity calls this only once its initial content is drawn and it is resumed. */
    fun startWhenReady() {
        permissionContinuation?.let { op ->
            permissionContinuation = null
            prepare(op)
            return
        }
        if (!startRequested || phase != CompanionSetupPhase.READY) return
        startRequested = false
        if (!available) {
            fail("Background auto-reconnect isn't supported on this Android device.", generation)
            return
        }
        enable()
    }

    fun enable() {
        if (!canEnable) return
        notice = ""
        val op = ++generation
        if (controller.missingPermissions().isNotEmpty()) {
            phase = CompanionSetupPhase.PERMISSION
            permissionRequest = op
            return
        }
        prepare(op)
    }

    private fun prepare(op: Int) {
        if (!current(op)) return
        if (app.getSystemService(android.app.KeyguardManager::class.java)?.isKeyguardLocked == true) {
            fail("Unlock your phone and try again; your devices are still paired.", op)
            return
        }
        phase = CompanionSetupPhase.PREPARING
        if (configured && probe.address != null) {
            if (armed) { succeed(op); return }
            launchWork {
                try {
                    probe.resume(stillCurrent = { current(op) && unlocked() })
                    succeed(op)
                } catch (error: CancellationException) { throw error }
                catch (_: Exception) { fail("Device setup is unavailable. Reset connection setup, then try again.", op) }
            }
            return
        }
        // Replacement is explicit and scoped to the native setup, never identity or pairing.
        if (probe.peerId != null || probe.address != null) probe.stop("Connection setup changed.")
        target = peer?.let(controller::beginCompanionSetup)
        if (target == null && !quick) controller.cancel()
        probeToken = probe.beginSetup()
        target?.let { expected ->
            expiry = viewModelScope.launch {
                delay((expected.expiresAt - SystemClock.elapsedRealtime()).coerceAtLeast(0))
                fail("Setup expired. Try again; your devices are still paired.", op)
            }
        }
        launchWork {
            try {
                val expected = target
                if (expected != null) {
                    check(app.companionSetup.prepare(expected))
                    check(current(op) && controller.companionSetupCurrent(expected))
                } else if (quick) error("Connect before quick enrollment")
                if (!current(op)) return@launchWork
                val filter = ScanFilter.Builder().setServiceUuid(ParcelUuid(UUID.fromString(BlePayloadCodec.SERVICE_UUID)))
                if (expected != null) filter.setDeviceAddress(expected.address)
                val request = AssociationRequest.Builder().addDeviceFilter(BluetoothLeDeviceFilter.Builder()
                    .setScanFilter(filter.build()).build()).setSingleDevice(expected != null).build()
                val callback = object : CompanionDeviceManager.Callback() {
                    override fun onDeviceFound(sender: IntentSender) = pending(sender)
                    override fun onAssociationPending(sender: IntentSender) = pending(sender)
                    private fun pending(sender: IntentSender) {
                        if (!current(op) || phase != CompanionSetupPhase.PREPARING ||
                            approvalGate.owns(op) || pendingApproval != null) return
                        if (expected != null && !controller.companionSetupCurrent(expected)) {
                            fail("Setup expired. Try again; your devices are still paired.", op)
                            return
                        }
                        pendingApproval = CompanionApproval(op, sender)
                    }
                    override fun onAssociationCreated(info: AssociationInfo) {
                        if (Build.VERSION.SDK_INT < 33) return
                        acceptAssociation(CompanionAssociation(info.deviceMacAddress?.toString(), info.id), op)
                    }
                    override fun onFailure(error: CharSequence?) {
                        fail("Android couldn't finish setup. Try again; your devices are still paired.", op)
                    }
                }
                if (Build.VERSION.SDK_INT >= 33)
                    manager.associate(request, ContextCompat.getMainExecutor(app), callback)
                else manager.associate(request, callback, Handler(Looper.getMainLooper()))
            } catch (error: CancellationException) { throw error }
            catch (_: Exception) { fail("Your devices are paired. Connect your Mac and try auto-reconnect again.", op) }
        }
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
        if (controller.missingPermissions().isNotEmpty()) {
            fail("Bluetooth access is needed for auto-reconnect. You can allow it in app settings.", op)
        } else {
            permissionContinuation = op
            phase = CompanionSetupPhase.READY
        }
    }
    fun permissionLaunchFailed(op: Int) {
        if (permissionGeneration != op) return
        permissionGeneration = null
        fail("Bluetooth approval couldn't open. Try again in Devices.", op)
    }
    fun claimApproval(approval: CompanionApproval): IntentSender? {
        if (!current(approval.generation) || pendingApproval !== approval ||
            chooserGeneration != null || !approvalGate.claim(approval.generation)) return null
        val expected = target
        if (!unlocked() || expected != null && !controller.companionSetupCurrent(expected)) {
            fail("Setup expired. Try again; your devices are still paired.", approval.generation)
            return null
        }
        chooserGeneration = approval.generation
        pendingApproval = null
        phase = CompanionSetupPhase.APPROVAL
        return approval.sender
    }
    fun approvalLaunchFailed(op: Int) {
        if (chooserGeneration != op) return
        chooserGeneration = null
        fail("Android's approval couldn't open. Try again in Devices.", op)
    }
    fun approvalReturned(success: Boolean, association: CompanionAssociation?) {
        val op = chooserGeneration
        chooserGeneration = null
        if (op == null || !current(op)) {
            association?.let { removeAssociation(it.address, it.id) }
            return
        }
        if (!success) fail("Auto-reconnect wasn't enabled. Your devices are still paired.", op)
        else if (Build.VERSION.SDK_INT < 33) {
            if (association == null) fail("Android returned no device. Try again.", op)
            else acceptAssociation(association, op)
        }
    }

    private fun acceptAssociation(association: CompanionAssociation, op: Int) {
        val address = association.address
        val id = association.id
        if (current(op) && phase == CompanionSetupPhase.SAVING &&
            savingAssociation?.let { it.id == id && address.equals(it.address, ignoreCase = true) } == true) return
        if (!current(op) || !approvalGate.owns(op) || phase != CompanionSetupPhase.APPROVAL ||
            address == null || !unlocked()) {
            removeAssociation(address, id)
            if (current(op)) fail("Android's approval is no longer current. Unlock your phone and try again.", op)
            return
        }
        savingAssociation = association
        phase = CompanionSetupPhase.SAVING
        launchWork {
            try {
                val peer = requireNotNull(peer)
                val expected = target
                if (quick) check(expected != null)
                if (expected != null) check(address.equals(expected.address, ignoreCase = true))
                probe.arm(peer, address, id, probeToken, stillCurrent = {
                    current(op) && unlocked() && target === expected &&
                        (expected == null || controller.companionSetupCurrent(expected))
                })
                succeed(op)
            } catch (error: CancellationException) { throw error }
            catch (_: Exception) { fail("Auto-reconnect couldn't be enabled. Try again; your devices are still paired.", op) }
            finally { removeAssociation(address, id) }
        }
    }

    fun cancel() {
        generation++
        startRequested = false
        releaseAttempt()
        phase = CompanionSetupPhase.READY
        notice = "Auto-reconnect wasn't enabled. Your devices are still paired."
    }
    fun disable() {
        if (!configured || phase.busy) return
        cancel()
        probe.disable()
        notice = ""
    }
    fun reset() {
        if (!configured || phase.busy) return
        cancel()
        probe.stop("Connection setup cleared. Your devices are still paired.")
        notice = ""
    }
    private fun succeed(op: Int) {
        if (!current(op)) return
        generation++
        releaseAttempt()
        notice = "Auto-reconnect is enabled."
        phase = if (finishOnSuccess) CompanionSetupPhase.COMPLETE else CompanionSetupPhase.READY
        complete = finishOnSuccess
    }
    private fun fail(message: String, op: Int) {
        if (!current(op)) return
        generation++
        startRequested = false
        releaseAttempt()
        phase = CompanionSetupPhase.FAILED
        notice = message
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
        // Cancellation fences signing/lookup even when their underlying native operation completes later.
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
    }
}
