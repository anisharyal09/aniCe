// SPDX-License-Identifier: GPL-3.0-or-later
// Posts silent release notices using existing notification permission and opens review without installing.
package io.github.anisharyal09.anice.update

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import androidx.core.net.toUri
import io.github.anisharyal09.anice.MainActivity

internal class UpdateNotification(private val context: Context) {
    private val manager = context.getSystemService(NotificationManager::class.java)

    init {
        manager.createNotificationChannel(NotificationChannel(CHANNEL, "App updates", NotificationManager.IMPORTANCE_LOW).apply {
            description = "New aniCe releases"
            setShowBadge(false)
            setSound(null, null)
            enableVibration(false)
        })
    }

    fun post(release: AvailableRelease): Boolean {
        if (Build.VERSION.SDK_INT >= 33 &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return false
        if (!manager.areNotificationsEnabled() ||
            manager.getNotificationChannel(CHANNEL)?.importance?.let { it != NotificationManager.IMPORTANCE_NONE } != true) return false
        val open = PendingIntent.getActivity(context, ID, Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
            data = "anice-update://review/${release.version.tag}".toUri()
            putExtra(OPEN_REVIEW, true)
            putExtra(EXTRA_VERSION_TAG, release.version.tag)
        }, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val notice = NotificationCompat.Builder(context, CHANNEL)
            .setSmallIcon(android.R.drawable.stat_sys_download_done)
            .setContentTitle("aniCe ${release.version.tag} is available")
            .setContentText("Review release notes when you’re ready.")
            .setContentIntent(open)
            .setAutoCancel(true)
            .setSilent(true)
            .setOnlyAlertOnce(true)
            .build()
        return try {
            manager.notify(ID, notice)
            true
        } catch (_: SecurityException) {
            false
        }
    }

    fun clear() { manager.cancel(ID) }

    companion object {
        const val OPEN_REVIEW = "io.github.anisharyal09.anice.update.OPEN_REVIEW"
        const val EXTRA_VERSION_TAG = "io.github.anisharyal09.anice.update.VERSION_TAG"
        private const val CHANNEL = "app_updates"
        private const val ID = 730
    }
}
