// SPDX-License-Identifier: GPL-3.0-or-later
// Delivers one silent offer notice and a live progress notice while TransferService owns foreground work.
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
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class TransferNotification(
    private val context: Context,
    private val controller: TransferController,
    private val isForeground: () -> Boolean = { false },
) {
    private val manager = context.getSystemService(NotificationManager::class.java)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var announcedOffer: Pair<String, Boolean>? = null
    private var announcedCompletion: String? = null
    private var lastProgressAt = 0L
    private var lastProgressKey: String? = null

    init {
        manager.createNotificationChannel(NotificationChannel(CHANNEL_ID, "File transfer", NotificationManager.IMPORTANCE_LOW).apply {
            description = "Required transfer service and incoming file offers"
            setShowBadge(false)
        })
        manager.cancel(OFFER_NOTIFICATION_ID)
        manager.cancel(RESULT_NOTIFICATION_ID)
    }

    @SuppressLint("NotificationPermission")
    fun update(force: Boolean = false) {
        updateOffer()
        updateResult()
        val progress = activeProgressNotice()
        if (progress != null) {
            val now = SystemClock.elapsedRealtime()
            if (force || progress.key != lastProgressKey || lastProgressAt == 0L || now - lastProgressAt >= PROGRESS_UPDATE_INTERVAL_MS) {
                manager.notify(NOTIFICATION_ID, progress.build())
                lastProgressAt = now
                lastProgressKey = progress.key
            }
            return
        }
        lastProgressAt = 0L
        lastProgressKey = null

        if (!controller.backgroundAllowed || !controller.isBusy) manager.cancel(NOTIFICATION_ID)
    }

    @SuppressLint("NotificationPermission")
    internal fun updateOffer() {
        val offer = controller.state as? TransferState.IncomingOffer
        if (offer == null || controller.backgroundAllowed) {
            clearOffer()
            return
        }
        val needsApp = controller.automaticReceiveNeedsApp
        if (!needsApp && controller.pendingAutomaticReceive?.batchId == offer.batch.id) {
            clearOffer()
            return
        }
        if (isForeground()) {
            // Keep the announcement recorded so leaving the app does not revive it.
            manager.cancel(OFFER_NOTIFICATION_ID)
            return
        }
        val offerKey = offer.batch.id to needsApp
        if (announcedOffer == offerKey) return
        val operationId = UUID.fromString(offer.batch.id).toString()
        val files = "${offer.batch.files.size} file${if (offer.batch.files.size == 1) "" else "s"}"
        val title = if (needsApp) "Open aniCe to receive" else "Incoming files from ${offer.batch.peerName}"
        val body = if (needsApp) "$files from ${offer.batch.peerName}"
            else "${files} (${Formatter.formatFileSize(context, offer.batch.totalBytes)})"
        val notice = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_file_send)
            .setContentTitle(title)
            .setContentText(body).setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setContentIntent(openIntent(context, operationId)).setAutoCancel(true).setSilent(true).setOnlyAlertOnce(true)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "Decline",
                cancelIntent(context, operationId, requestCode = 1))
            .build()
        manager.notify(OFFER_NOTIFICATION_ID, notice)
        announcedOffer = offerKey
    }

    private fun clearOffer() {
        if (announcedOffer == null) return
        manager.cancel(OFFER_NOTIFICATION_ID)
        announcedOffer = null
    }

    @SuppressLint("NotificationPermission")
    private fun updateResult() {
        val completed = controller.state as? TransferState.Completed
        if (completed == null) {
            if (controller.isBusy) manager.cancel(RESULT_NOTIFICATION_ID)
            return
        }
        if (!controller.receiving || completed.fileCount <= 0 || isForeground()) return
        if (announcedCompletion == completed.batchId) return
        announcedCompletion = completed.batchId
        val operationId = controller.operationID.toString()
        val files = "${completed.fileCount} file${if (completed.fileCount == 1) "" else "s"} (${Formatter.formatFileSize(context, completed.totalBytes)})"
        val prefs = controller.destinationPreferences
        scope.launch {
            val destination = if (prefs != null) {
                withContext(Dispatchers.IO) { prefs.summary() }
            } else {
                "Downloads/aniCe"
            }
            val current = controller.state as? TransferState.Completed
            if (current?.batchId != completed.batchId || !controller.receiving || isForeground()) return@launch
            val body = "$files saved to $destination."
            val notice = NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_file_send)
                .setContentTitle("Files received")
                .setContentText(body).setStyle(NotificationCompat.BigTextStyle().bigText(body))
                .setContentIntent(openIntent(context, operationId))
                .setAutoCancel(true)
                .setOnlyAlertOnce(true)
                .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
                .build()
            manager.notify(RESULT_NOTIFICATION_ID, notice)
        }
    }

    private inner class ProgressNotice(
        val title: String,
        val detail: String,
        val progress: Int?,
    ) {
        private val operationId = controller.operationID.toString()
        val key = "$operationId:${controller.state::class.java.name}:${controller.receiving}:" +
            ((controller.state as? TransferState.Transferring)?.fileIndex ?: 0)
        fun build(): android.app.Notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_file_send)
            .setContentTitle(title)
            .setContentText(detail).setStyle(NotificationCompat.BigTextStyle().bigText(detail))
            .setContentIntent(openIntent(context, operationId))
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setProgress(PROGRESS_MAX, progress ?: 0, progress == null)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "Cancel transfer",
                cancelIntent(context, operationId, requestCode = 2))
            .build()
    }

    private fun activeProgressNotice(): ProgressNotice? {
        // An active transfer is visible even while the app is open; the ongoing notice is the only
        // progress surface when the screen is covered, and mirrors the in-app bar otherwise.
        if (!controller.isBusy) return null
        if (controller.preparing) return ProgressNotice("Preparing files", "Getting files ready to send", null)
        return when (val state = controller.state) {
            is TransferState.Transferring -> {
                val total = state.batch.totalBytes
                val completed = state.totalBytes.coerceIn(0L, total)
                val percent = if (total > 0L) ((completed.toDouble() / total) * PROGRESS_MAX).toInt().coerceIn(0, PROGRESS_MAX) else null
                val percentLabel = if (total > 0L) (completed.toDouble() * 100 / total).toInt() else 0
                val direction = if (controller.receiving) "Receiving from" else "Sending to"
                val currentFile = state.fileIndex.coerceIn(1, state.batch.files.size)
                val summary = if (total > 0L) {
                    "$percentLabel% · ${Formatter.formatFileSize(context, completed)} of ${Formatter.formatFileSize(context, total)} · File $currentFile/${state.batch.files.size}"
                } else "File $currentFile of ${state.batch.files.size}"
                ProgressNotice("$direction ${state.batch.peerName}", "$summary\n${state.fileName}", percent)
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

    private fun openIntent(context: Context, operationId: String): PendingIntent = PendingIntent.getActivity(
        context, 0, Intent(context, MainActivity::class.java).setAction(OPEN)
            .setData("anice-transfer://review/$operationId".toUri())
            .putExtra(TransferActionReceiver.EXTRA_OPERATION_ID, operationId).apply {
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
        const val OPEN = "io.github.anisharyal09.anice.action.OPEN_TRANSFER"
        const val CHANNEL_ID = "anice_file_transfer"
        const val NOTIFICATION_ID = 2002
        // Foregrounding can remove an offer without removing the service's progress notice.
        internal const val OFFER_NOTIFICATION_ID = 2004
        internal const val RESULT_NOTIFICATION_ID = 2005
        private const val PROGRESS_MAX = 1000
        private const val PROGRESS_UPDATE_INTERVAL_MS = 1000L
    }
}
