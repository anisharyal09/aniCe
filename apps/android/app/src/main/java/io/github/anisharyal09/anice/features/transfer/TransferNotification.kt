// SPDX-License-Identifier: GPL-3.0-or-later
// Delivers one silent background offer notice while TransferService owns the required foreground notice.
package io.github.anisharyal09.anice.features.transfer

import android.annotation.SuppressLint
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.SystemClock
import android.text.format.Formatter
import androidx.core.app.NotificationCompat
import androidx.core.net.toUri
import io.github.anisharyal09.anice.MainActivity
import io.github.anisharyal09.anice.R
import java.util.UUID

class TransferNotification(
    private val context: Context,
    private val controller: TransferController,
    private val isForeground: () -> Boolean = { false },
) {
    private val manager = context.getSystemService(NotificationManager::class.java)
    private var announcedOffer: String? = null
    private var announcedNeedsApp: Boolean? = null
    private var lastProgressAt = 0L

    init {
        manager.createNotificationChannel(NotificationChannel(CHANNEL_ID, "File transfer", NotificationManager.IMPORTANCE_LOW).apply {
            description = "Required transfer service and incoming file offers"
            setShowBadge(false)
        })
    }

    @SuppressLint("NotificationPermission")
    fun update(force: Boolean = false) {
        activeProgressNotice()?.let { progress ->
            val now = SystemClock.elapsedRealtime()
            if (force || lastProgressAt == 0L || now - lastProgressAt >= PROGRESS_UPDATE_INTERVAL_MS) {
                manager.notify(NOTIFICATION_ID, progress.build())
                lastProgressAt = now
            }
            announcedOffer = null
            announcedNeedsApp = null
            return
        }
        lastProgressAt = 0L

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
        val decline = cancelIntent(context, UUID.fromString(offer.batch.id).toString(), requestCode = 1)
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
            .setSmallIcon(R.drawable.ic_file_send)
            .setContentTitle(title)
            .setContentText(body)
            .setContentIntent(open).setAutoCancel(true).setSilent(true).setOnlyAlertOnce(true)
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "Decline", decline)
            .build()
        manager.notify(NOTIFICATION_ID, notice)
    }

    private inner class ProgressNotice(
        val title: String,
        val detail: String,
        val progress: Int?,
    ) {
        fun build(): android.app.Notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_file_send)
            .setContentTitle(title)
            .setContentText(detail)
            .setContentIntent(openIntent(context))
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setProgress(PROGRESS_MAX, progress ?: 0, progress == null)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "Cancel transfer",
                cancelIntent(context, controller.operationID.toString(), requestCode = 2))
            .build()
    }

    private fun activeProgressNotice(): ProgressNotice? {
        if (!controller.backgroundAllowed || !controller.isBusy) return null
        if (controller.preparing) return ProgressNotice("Preparing files", "Getting files ready to send", null)
        return when (val state = controller.state) {
            is TransferState.Transferring -> {
                val total = state.batch.totalBytes
                val completed = state.totalBytes.coerceIn(0L, total)
                val percent = if (total > 0L) ((completed.toDouble() / total) * PROGRESS_MAX).toInt().coerceIn(0, PROGRESS_MAX) else null
                val percentLabel = if (total > 0L) (completed.toDouble() * 100 / total).toInt() else 0
                val direction = if (controller.receiving) "Receiving from" else "Sending to"
                val currentFile = state.fileIndex.coerceIn(1, state.batch.files.size)
                val detail = if (total > 0L) {
                    "$percentLabel% · ${Formatter.formatFileSize(context, completed)} of ${Formatter.formatFileSize(context, total)} · File $currentFile/${state.batch.files.size}"
                } else "File $currentFile of ${state.batch.files.size}"
                ProgressNotice("$direction ${state.batch.peerName}", detail, percent)
            }
            is TransferState.Paused -> {
                val total = state.batch.totalBytes
                val completed = state.totalBytes.coerceIn(0L, total)
                val percent = if (total > 0L) ((completed.toDouble() / total) * PROGRESS_MAX).toInt().coerceIn(0, PROGRESS_MAX) else null
                val detail = if (total > 0L) {
                    "Paused · ${Formatter.formatFileSize(context, completed)} of ${Formatter.formatFileSize(context, total)}"
                } else "Paused · waiting to reconnect"
                ProgressNotice("Transfer paused", detail, percent)
            }
            is TransferState.Connecting -> ProgressNotice("Connecting to ${state.peerName}", "Preparing file transfer", null)
            is TransferState.WaitingForPeerApproval -> ProgressNotice(
                "Waiting for ${state.batch.peerName}",
                "${state.batch.files.size} file${if (state.batch.files.size == 1) "" else "s"} · ${Formatter.formatFileSize(context, state.batch.totalBytes)}",
                null,
            )
            is TransferState.IncomingOffer -> {
                val pending = controller.pendingAutomaticReceive
                if (pending?.batchId != state.batch.id || controller.automaticReceiveNeedsApp) return null
                ProgressNotice("Preparing to receive from ${state.batch.peerName}",
                    "${state.batch.files.size} file${if (state.batch.files.size == 1) "" else "s"} · ${Formatter.formatFileSize(context, state.batch.totalBytes)}", null)
            }
            else -> null
        }
    }

    private fun openIntent(context: Context): PendingIntent = PendingIntent.getActivity(
        context, 0, Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

    private fun cancelIntent(context: Context, operationId: String, requestCode: Int): PendingIntent {
        // Distinct PendingIntent data prevents an old notification from acquiring a newer job's action.
        val intent = Intent(context, TransferActionReceiver::class.java)
            .setAction(TransferActionReceiver.ACTION_CANCEL)
            .setData("anice-transfer://cancel/$operationId".toUri())
            .putExtra(TransferActionReceiver.EXTRA_OPERATION_ID, operationId)
        return PendingIntent.getBroadcast(context, requestCode, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }

    companion object {
        const val CHANNEL_ID = "anice_file_transfer"
        const val NOTIFICATION_ID = 2002
        private const val PROGRESS_MAX = 1000
        private const val PROGRESS_UPDATE_INTERVAL_MS = 1000L
    }
}
