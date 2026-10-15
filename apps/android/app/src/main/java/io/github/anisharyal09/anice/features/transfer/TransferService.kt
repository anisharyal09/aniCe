// SPDX-License-Identifier: GPL-3.0-or-later
// Presents approved LAN/BLE transfer ownership through a connected-device foreground service without creating a transfer owner.
package io.github.anisharyal09.anice.features.transfer

import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import io.github.anisharyal09.anice.AniCeApplication
import io.github.anisharyal09.anice.R

class TransferService : Service() {
    private var lease: java.util.UUID? = null
    private val app get() = application as AniCeApplication

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (!app.transfer.backgroundAllowed || !app.transfer.isBusy ||
            !app.transfer.peerConnected && app.transfer.state !is TransferState.Connecting) {
            stopSelf(startId)
            return START_NOT_STICKY
        }
        lease = app.transfer.operationID
        val notification = NotificationCompat.Builder(this, TransferNotification.CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_launcher)
            .setContentTitle("Local file transfer")
            .setContentText("Transferring with your trusted device")
            .setOngoing(true).setOnlyAlertOnce(true).build()
        try {
            ServiceCompat.startForeground(this, TransferNotification.NOTIFICATION_ID, notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        } catch (_: SecurityException) {
            app.transfer.backgroundAllowed = false
            stopSelf(startId)
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        if (lease == app.transfer.operationID) {
            app.transferServiceStopped()
        }
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
