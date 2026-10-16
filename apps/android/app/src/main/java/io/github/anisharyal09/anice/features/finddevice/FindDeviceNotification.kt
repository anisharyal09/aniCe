// SPDX-License-Identifier: GPL-3.0-or-later
// Admits one identifier-bound ringing lease and presents its native foreground notification and Stop action.
package io.github.anisharyal09.anice.features.finddevice

import android.Manifest
import android.app.*
import android.content.*
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import androidx.core.net.toUri
import io.github.anisharyal09.anice.AniCeApplication
import io.github.anisharyal09.anice.MainActivity
import io.github.anisharyal09.anice.R
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.withTimeoutOrNull

internal class FindDeviceRing(val identifier: String, val peerName: String, val deadline: Long) {
    val ready = CompletableDeferred<FindResult>()
    var started = false
    var stop: (() -> Unit)? = null
}
class FindDeviceNotification(private val context: Context) : FindDeviceNotifying {
    private val manager = context.getSystemService(NotificationManager::class.java)
    private var current: FindDeviceRing? = null
    init {
        manager.createNotificationChannel(NotificationChannel(CHANNEL, context.getString(R.string.find_title), NotificationManager.IMPORTANCE_DEFAULT))
        manager.activeNotifications.filter { it.tag?.startsWith("find-device-") == true || it.id == ID }.forEach { manager.cancel(it.tag, it.id) }
    }
    fun permitted() = (Build.VERSION.SDK_INT < 33 || ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) &&
        manager.areNotificationsEnabled() && manager.getNotificationChannel(CHANNEL)?.importance?.let { it != NotificationManager.IMPORTANCE_NONE } == true

    override suspend fun post(identifier: String, peerName: String): FindResult {
        if (!permitted()) return FindResult.BLOCKED
        if (current != null) return FindResult.BUSY
        val ring = FindDeviceRing(identifier, peerName, SystemClock.elapsedRealtime() + 60000)
        current = ring
        var result = FindResult.FAILED
        try {
            ContextCompat.startForegroundService(context, Intent(context, FindDeviceRingService::class.java).putExtra(EXTRA_IDENTIFIER, identifier))
            result = withTimeoutOrNull(4000) { ring.ready.await() } ?: FindResult.FAILED
            return result
        } catch (_: SecurityException) { return FindResult.FAILED }
        catch (_: IllegalStateException) { return FindResult.FAILED }
        finally { if (result != FindResult.SUBMITTED) clear(identifier) }
    }
    internal fun request(identifier: String): FindDeviceRing? = current?.takeIf {
        it.identifier == identifier && SystemClock.elapsedRealtime() < it.deadline
    }
    internal fun notification(ring: FindDeviceRing): Notification {
        val dismiss = PendingIntent.getBroadcast(context, 0,
            Intent(context, FindDeviceDismissReceiver::class.java).setAction(DISMISS).setData("anice-find://dismiss/${ring.identifier}".toUri()),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val open = PendingIntent.getActivity(context, 0, Intent(context, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        return NotificationCompat.Builder(context, CHANNEL)
            .setSmallIcon(R.drawable.ic_launcher).setContentTitle(context.getString(R.string.find_ringing_title))
            .setContentText(context.getString(R.string.find_notification_body, ring.peerName))
            .setStyle(NotificationCompat.BigTextStyle().bigText(context.getString(R.string.find_notification_body, ring.peerName)))
            .setContentIntent(open).setDeleteIntent(dismiss).setAutoCancel(false).setOnlyAlertOnce(true).setSilent(true)
            .setTimeoutAfter(maxOf(1, ring.deadline - SystemClock.elapsedRealtime()))
            .addExtras(Bundle().apply { putString(EXTRA_IDENTIFIER, ring.identifier) })
            .addAction(0, context.getString(R.string.find_stop_ringing), dismiss).build()
    }
    override fun clear(identifier: String) {
        val ring = current?.takeIf { it.identifier == identifier } ?: return
        current = null
        ring.ready.complete(FindResult.STALE)
        ring.stop?.invoke()
        manager.cancel(ID)
    }
    companion object {
        const val CHANNEL = "anice_find_device"
        const val ID = 2003
        const val DISMISS = "io.github.anisharyal09.anice.FIND_DISMISS"
        const val EXTRA_IDENTIFIER = "findDeviceIdentifier"
    }
}
class FindDeviceDismissReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != FindDeviceNotification.DISMISS || intent.data?.scheme != "anice-find" || intent.data?.host != "dismiss") return
        val identifier = intent.data?.lastPathSegment ?: return
        val app = context.applicationContext as AniCeApplication
        app.findDevice.dismiss(identifier)
        app.findDeviceNotification.clear(identifier)
    }
}
