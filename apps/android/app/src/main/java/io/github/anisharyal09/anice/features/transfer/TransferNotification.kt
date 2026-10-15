// SPDX-License-Identifier: GPL-3.0-or-later
// Presents file transfer progress and cancellation actions in the native Android notification shade.
package io.github.anisharyal09.anice.features.transfer

import android.annotation.SuppressLint
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import androidx.core.app.NotificationCompat
import io.github.anisharyal09.anice.MainActivity
import io.github.anisharyal09.anice.R

class TransferNotification(private val context: Context, private val controller: TransferController) {
    private val manager = context.getSystemService(NotificationManager::class.java)

    init {
        val channel = NotificationChannel(
            CHANNEL_ID,
            "File Transfer",
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "Shows progress of active local file transfers"
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    private var lastNotifyTime = 0L

    @SuppressLint("NotificationPermission")
    fun update() {
        val state = controller.state
        when (state) {
            is TransferState.Transferring -> {
                val now = android.os.SystemClock.elapsedRealtime()
                if (now - lastNotifyTime < 250L) return
                lastNotifyTime = now

                // An empty batch has no proportion to report; a determinate zero would read as a stall.
                val determinate = state.batch.totalBytes > 0
                val percent = if (determinate) {
                    ((state.totalBytes * 100) / state.batch.totalBytes).toInt().coerceIn(0, 100)
                } else 0

                val openIntent = PendingIntent.getActivity(
                    context,
                    0,
                    Intent(context, MainActivity::class.java),
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                )

                val cancelIntent = PendingIntent.getBroadcast(
                    context,
                    1,
                    Intent(context, TransferActionReceiver::class.java).setAction(TransferActionReceiver.ACTION_CANCEL),
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                )

                val progress = "${state.fileName} (${state.fileIndex}/${state.batch.files.size})"
                val speedMb = String.format(java.util.Locale.ROOT, "%.1f", state.speedBps / (1024.0 * 1024.0))
                val content = if (state.speedBps > 0) "$progress • $speedMb MB/s" else progress

                val notification = NotificationCompat.Builder(context, CHANNEL_ID)
                    .setSmallIcon(R.drawable.ic_launcher)
                    .setContentTitle(if (controller.receiving) "Receiving files" else "Sending files")
                    .setContentText(content)
                    .setProgress(100, percent, !determinate)
                    .setContentIntent(openIntent)
                    .setOngoing(true)
                    .setOnlyAlertOnce(true)
                    .addAction(android.R.drawable.ic_menu_close_clear_cancel, "Cancel", cancelIntent)
                    .build()

                manager.notify(NOTIFICATION_ID, notification)
            }
            is TransferState.Completed -> {
                lastNotifyTime = 0L
                val files = "${state.fileCount} file${if (state.fileCount == 1) "" else "s"}"
                val notification = NotificationCompat.Builder(context, CHANNEL_ID)
                    .setSmallIcon(R.drawable.ic_launcher)
                    .setContentTitle("File transfer complete")
                    .setContentText(
                        if (controller.receiving) "Saved $files to the folder you chose"
                        else "Sent $files successfully"
                    )
                    .setAutoCancel(true)
                    .build()
                manager.notify(NOTIFICATION_ID, notification)
            }
            is TransferState.Failed -> {
                lastNotifyTime = 0L
                val notification = NotificationCompat.Builder(context, CHANNEL_ID)
                    .setSmallIcon(R.drawable.ic_launcher)
                    .setContentTitle("File transfer failed")
                    .setContentText(state.reason)
                    .setAutoCancel(true)
                    .build()
                manager.notify(NOTIFICATION_ID, notification)
            }
            else -> {
                lastNotifyTime = 0L
                manager.cancel(NOTIFICATION_ID)
            }
        }
    }

    companion object {
        const val CHANNEL_ID = "anice_file_transfer"
        const val NOTIFICATION_ID = 2002
    }
}
