// SPDX-License-Identifier: GPL-3.0-or-later
// Delivers one silent background offer notice while TransferService owns the required foreground notice.
package io.github.anisharyal09.anice.features.transfer

import android.annotation.SuppressLint
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.text.format.Formatter
import androidx.core.app.NotificationCompat
import io.github.anisharyal09.anice.MainActivity
import io.github.anisharyal09.anice.R

class TransferNotification(
    private val context: Context,
    private val controller: TransferController,
    private val isForeground: () -> Boolean = { false },
) {
    private val manager = context.getSystemService(NotificationManager::class.java)
    private var announcedOffer: String? = null
    private var announcedNeedsApp: Boolean? = null

    init {
        manager.createNotificationChannel(NotificationChannel(CHANNEL_ID, "File transfer", NotificationManager.IMPORTANCE_LOW).apply {
            description = "Required transfer service and incoming file offers"
            setShowBadge(false)
        })
    }

    @SuppressLint("NotificationPermission")
    fun update() {
        val offer = controller.state as? TransferState.IncomingOffer
            ?: (controller.interruptedOffer as? TransferState.IncomingOffer)
        if (offer == null) {
            announcedOffer = null
            announcedNeedsApp = null
            // The service owns its single ongoing notice; progress ticks do not resubmit notifications.
            if (!controller.backgroundAllowed || !controller.isBusy) manager.cancel(NOTIFICATION_ID)
            return
        }
        val paused = controller.state is TransferState.Paused
        val needsApp = controller.automaticReceiveNeedsApp || paused
        val autoAccepted = !paused && controller.pendingAutomaticReceive?.batchId == offer.batch.id && !needsApp
        if (autoAccepted) {
            announcedOffer = offer.batch.id
            announcedNeedsApp = null
            return
        }
        if (isForeground() || announcedOffer == offer.batch.id && announcedNeedsApp == needsApp) return
        // State delivery can announce the offer before foreground eligibility is known; replace the notice when it changes.
        announcedOffer = offer.batch.id
        announcedNeedsApp = needsApp
        val open = PendingIntent.getActivity(context, 0, Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val decline = PendingIntent.getBroadcast(context, 1,
            Intent(context, TransferActionReceiver::class.java).setAction(TransferActionReceiver.ACTION_CANCEL),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val files = "${offer.batch.files.size} file${if (offer.batch.files.size == 1) "" else "s"}"
        val title = when {
            paused && controller.automaticReceiveNeedsApp -> "Open aniCe to receive"
            paused -> "Open aniCe to review files"
            needsApp -> "Open aniCe to receive"
            else -> "Incoming files from ${offer.batch.peerName}"
        }
        val body = if (needsApp) "$files from ${offer.batch.peerName}"
            else "${files} (${Formatter.formatFileSize(context, offer.batch.totalBytes)})"
        val notice = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_launcher)
            .setContentTitle(title)
            .setContentText(body)
            .setContentIntent(open).setAutoCancel(true).setSilent(true).setOnlyAlertOnce(true)
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "Decline", decline)
            .build()
        manager.notify(NOTIFICATION_ID, notice)
    }

    companion object {
        const val CHANNEL_ID = "anice_file_transfer"
        const val NOTIFICATION_ID = 2002
    }
}
