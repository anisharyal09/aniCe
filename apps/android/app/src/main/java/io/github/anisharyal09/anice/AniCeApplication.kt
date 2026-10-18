// SPDX-License-Identifier: GPL-3.0-or-later
// Assembles shared identity, trust and independent transport owners for the Android process.
package io.github.anisharyal09.anice

import android.app.Application
import kotlinx.coroutines.launch
import android.os.Build
import io.github.anisharyal09.anice.infrastructure.identity.AndroidIdentityKeys
import io.github.anisharyal09.anice.infrastructure.identity.AndroidIdentityMetadata
import io.github.anisharyal09.anice.infrastructure.identity.IdentityService

class AniCeApplication : Application() {
    private val mediaNotification by lazy { io.github.anisharyal09.anice.features.nowplaying.MediaNotification(this,nowPlaying) }
    override fun onCreate() {
        super.onCreate()
        nowPlaying.presentationChanged={ mediaNotification.update() }
        mediaNotification.update()
        lanSessionController.onUnleasedBackgroundWork = {
            if (transfer.isBusy && (transfer.activeChannel?.descriptor?.transport == "lan" ||
                    transfer.state is io.github.anisharyal09.anice.features.transfer.TransferState.Connecting)) {
                transfer.cancelTransfer(); true
            } else false
        }
        lanSessionController.onDemandFailure = { reason -> transfer.onLanUnavailable(reason) }
        nowPlaying.onNetworkDemand = lanSessionController::updateMediaLease
        transfer.onPickerChanged = { picking ->
            updateTransferOwnership()
            if (picking) lanSessionController.requestAutomaticConnection()
        }
        transfer.onDemandLanConnection = { lanSessionController.connectPreferred() }
        // A paused batch asks the normal automatic policy for one bounded LAN attempt; an explicit
        // Disconnect still wins because requestAutomaticConnection respects it.
        transfer.onLanRequired = { lanSessionController.requestAutomaticConnection() }
        transfer.onChannelChanged = { updateTransferOwnership() }
        transfer.onLeaseChanged = { approved ->
            transferNotification.update()
            if (approved) {
                if (lanSessionController.foreground || bleOwner.isInitialized() && bleOwner.value.foreground) {
                    try {
                        transfer.backgroundAllowed = true
                        androidx.core.content.ContextCompat.startForegroundService(this,
                            android.content.Intent(this, io.github.anisharyal09.anice.features.transfer.TransferService::class.java))
                    } catch (_: IllegalStateException) { transfer.backgroundAllowed = false }
                    catch (_: SecurityException) { transfer.backgroundAllowed = false }
                }
            } else if (!approved) {
                transfer.backgroundAllowed = false
                stopService(android.content.Intent(this, io.github.anisharyal09.anice.features.transfer.TransferService::class.java))
            }
            updateTransferOwnership()
        }
        transfer.onStateChanged = { _ ->
            transferNotification.update()
            updateTransferOwnership()
            if (!transfer.isBusy) {
                lanSessionController.onWorkIdle()
            }
        }
        if(applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE!=0) {
            val timingTag="AniCeMediaTiming"
            nowPlaying.trace={ event,time ->
                if(android.util.Log.isLoggable(timingTag,android.util.Log.DEBUG)) {
                    android.util.Log.d(timingTag,"$event $time")
                }
            }
        }
    }
    private fun updateTransferOwnership() {
        val transport = transfer.activeChannel?.descriptor?.transport
        val connecting = transfer.state is io.github.anisharyal09.anice.features.transfer.TransferState.Connecting
        val bleSecured = bleOwner.isInitialized() && bleOwner.value.state ==
            io.github.anisharyal09.anice.infrastructure.connections.ConnectionState.SECURED
        val leases = io.github.anisharyal09.anice.infrastructure.connections.transferLeases(
            activeTransport = transport,
            connecting = connecting,
            backgroundAllowed = transfer.backgroundAllowed,
            selectingFiles = transfer.selectingFiles,
            bleSecured = bleSecured,
            paused = transfer.isPaused,
            busy = transfer.isBusy,
        )
        lanSessionController.updateWorkLease(leases.lanWork, leases.lanPicker)
        if (bleOwner.isInitialized()) bleOwner.value.updateWorkLease(leases.bleWork, leases.blePicker)
    }

    internal fun transferServiceStopped() {
        transfer.backgroundAllowed = false
        lanSessionController.onWorkServiceStopped()
        if (bleOwner.isInitialized()) bleOwner.value.onWorkServiceStopped()
    }

    private val clipboardOwner = lazy {
        io.github.anisharyal09.anice.features.clipboard.ClipboardController(
            native = io.github.anisharyal09.anice.features.clipboard.AndroidClipboard(this),
            history = io.github.anisharyal09.anice.features.clipboard.ClipboardHistory(io.github.anisharyal09.anice.features.clipboard.ClipboardHistoryFile(java.io.File(noBackupFilesDir, "clipboard/history.json"))),
            preferences = io.github.anisharyal09.anice.features.clipboard.ClipboardPreferences(getSharedPreferences("clipboard_preferences", MODE_PRIVATE))
        ).also { it.onLanRequired = { lanSessionController.requestAutomaticConnection() } }
    }
    val clipboard get() = clipboardOwner.value
    val findDeviceNotification by lazy { io.github.anisharyal09.anice.features.finddevice.FindDeviceNotification(this) }
    val findDevice by lazy { io.github.anisharyal09.anice.features.finddevice.FindDeviceController(findDeviceNotification) }
    val nowPlaying = io.github.anisharyal09.anice.features.nowplaying.MediaController()
    val transfer = io.github.anisharyal09.anice.features.transfer.TransferController(this)
    private val transferNotification by lazy { io.github.anisharyal09.anice.features.transfer.TransferNotification(this, transfer) }
    // Notification adapters need the base context attached by Android after Application construction.
    val features by lazy {
        io.github.anisharyal09.anice.infrastructure.connections.FeatureDispatch().also {
            it.applicationActivity = lanSessionController::onApplicationActivity
            it.register(lanSessionController.rendezvous)
            it.register(nowPlaying)
            it.register(transfer)
            it.register(findDevice)
            it.register(clipboard)
        }
    }
    val sessionPeers = io.github.anisharyal09.anice.infrastructure.session.SessionPeerReservation()
    private val lanOwner = lazy { io.github.anisharyal09.anice.infrastructure.connections.LanSessionController(this) }
    val lanSessionController get() = lanOwner.value
    // UI and system-bound probe share one transport/operation owner; sessions never enter durable storage.
    private val bleOwner = lazy {
        io.github.anisharyal09.anice.infrastructure.connections.SessionController(this).also { it.companionOwnershipChanged = nowPlaying::companionOwnershipChanged }
    }

    val sessionController get() = bleOwner.value
    private fun invalidateSessions() {
        nowPlaying.invalidate()
        if (clipboardOwner.isInitialized()) {
            android.os.Handler(android.os.Looper.getMainLooper()).post {
                clipboard.invalidate()
                kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Main).launch {
                    val peers = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
                        try { trustStore.list(identityService.getOrCreateIdentity().identity.fingerprint).map { it.peer } }
                        catch (_: Exception) { null }
                    }
                    if (peers != null) clipboard.prune(peers, confirmedTrust = true) else clipboard.select(null)
                }
            }
        }
        if (bleOwner.isInitialized()) bleOwner.value.securityInvalidated()
        if (lanOwner.isInitialized()) lanOwner.value.securityInvalidated()
    }

    @Volatile
    private var sharedTrust: io.github.anisharyal09.anice.infrastructure.pairing.PeerTrustStore? =
        null
    var trustStore: io.github.anisharyal09.anice.infrastructure.pairing.PeerTrustStore
        get() =
            synchronized(this) {
                sharedTrust
                    ?: io.github.anisharyal09.anice.infrastructure.pairing
                        .PeerTrustStore(java.io.File(noBackupFilesDir, "trusted_peers.json"))
                        .also { it.onInvalidated = ::invalidateSessions; sharedTrust = it }
            }
        set(value) {
            invalidateSessions()
            synchronized(this) { value.onInvalidated = ::invalidateSessions; sharedTrust = value }
        }

    // Share one service across activity recreation so identity operations stay serialized.
    val identityService by lazy {
        IdentityService(AndroidIdentityMetadata(this), AndroidIdentityKeys(), { Build.MODEL })
            .also { it.onInvalidated = ::invalidateSessions }
    }
}
