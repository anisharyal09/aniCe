// SPDX-License-Identifier: GPL-3.0-or-later
// Assembles shared identity, trust and independent transport owners for the Android process.
package io.github.anisharyal09.anice

import android.app.Application
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
        transfer.onPickerChanged = { updateTransferOwnership() }
        transfer.onDemandLanConnection = { lanSessionController.connectPreferred() }
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
        lanSessionController.updateWorkLease(transfer.backgroundAllowed && (transport == "lan" || connecting),
            transfer.selectingFiles && transport != "ble")
        if (bleOwner.isInitialized()) bleOwner.value.updateWorkLease(
            transfer.backgroundAllowed && transport == "ble", transfer.selectingFiles && transport == "ble")
    }

    internal fun transferServiceStopped() {
        transfer.backgroundAllowed = false
        lanSessionController.onWorkServiceStopped()
        if (bleOwner.isInitialized()) bleOwner.value.onWorkServiceStopped()
    }

    val nowPlaying = io.github.anisharyal09.anice.features.nowplaying.MediaController()
    val transfer = io.github.anisharyal09.anice.features.transfer.TransferController(this)
    private val transferNotification by lazy { io.github.anisharyal09.anice.features.transfer.TransferNotification(this, transfer) }
    val features = io.github.anisharyal09.anice.infrastructure.connections.FeatureDispatch().also {
        it.register(nowPlaying)
        it.register(transfer)
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
