// SPDX-License-Identifier: GPL-3.0-or-later
// Owns the mediaProjection foreground service and native capture for one user-authorized reverse operation.
package io.github.anisharyal09.anice.features.privatelistening

import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioManager
import android.media.projection.MediaProjectionManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import androidx.core.app.ServiceCompat
import io.github.anisharyal09.anice.AniCeApplication
import io.github.anisharyal09.anice.MainActivity
import io.github.anisharyal09.anice.R
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

class PhoneAudioService : Service() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val app get() = application as AniCeApplication
    private val controller get() = app.phoneAudio
    private val audio by lazy { getSystemService(AudioManager::class.java) }
    private val handler = Handler(Looper.getMainLooper())
    private var request: PhoneAudioRequest? = null
    private var capture: PhoneAudioCapture? = null
    private var captureWorker: PrivateListeningAudioWorker? = null
    private var job: Job? = null
    private var powerJob: Job? = null
    private var wake: PowerManager.WakeLock? = null
    private var modeListener: Any? = null
    private var powerRefreshAt = 0L

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val id = intent?.getStringExtra(STREAM) ?: return rejectStart(startId)
        val instance = intent.getStringExtra(INSTANCE) ?: return rejectStart(startId)
        if (intent.action == STOP) {
            if (request != null && controller.request(id, instance) === request) controller.stop()
            else if (request == null) stopSelfResult(startId)
            return START_NOT_STICKY
        }
        val ticket = controller.request(id, instance) ?: return rejectStart(startId)
        if (request === ticket) return START_NOT_STICKY
        if (request != null) return START_NOT_STICKY
        val resultCode = intent.getIntExtra(RESULT_CODE, Activity.RESULT_CANCELED)
        val projection = projectionData(intent)
        // The delivered Intent must not retain a projection token after this single-use handoff.
        intent.removeExtra(RESULT_DATA)
        if (resultCode != Activity.RESULT_OK || projection == null) {
            controller.captureFailed(ticket, "Screen capture consent is required to send phone audio.")
            return rejectStart(startId)
        }
        request = ticket
        var attached = false
        try {
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(NotificationChannel(CHANNEL,
                getString(R.string.phone_audio_title), NotificationManager.IMPORTANCE_LOW).apply {
                setSound(null, null); enableVibration(false); setShowBadge(false)
            })
            // Android 14+ requires the projection foreground-service type before getMediaProjection.
            ServiceCompat.startForeground(this, ID, notification(ticket),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
            val mediaProjection = getSystemService(MediaProjectionManager::class.java)
                .getMediaProjection(resultCode, projection)
                ?: throw IllegalStateException("MediaProjection was not available")
            val native = try {
                PhoneAudioCapture(this, mediaProjection, onStopped = { cause ->
                    handler.post {
                        if (request === ticket) controller.captureStopped(ticket, cause)
                    }
                }, diagnostics = ticket.diagnostics)
            } catch (error: Exception) {
                mediaProjection.stop()
                throw error
            }
            capture = native
            val worker = PrivateListeningAudioWorker("aniCe phone audio capture")
            captureWorker = worker
            val control = object : PhoneAudioCaptureControl {
                override fun start() = startCapture(ticket, native, worker)
                override fun close() { native.close() }
                override val available get() = native.available
            }
            if (!controller.serviceAttached(ticket, this, control)) {
                request = null
                native.close()
                capture = null
                worker.close()
                captureWorker = null
                stopSelfResult(startId)
                return START_NOT_STICKY
            }
            attached = true
            controller.callActiveChanged(ticket, inCallMode(audio.mode))
            if (Build.VERSION.SDK_INT >= 31) {
                val listener = AudioManager.OnModeChangedListener { mode ->
                    handler.post { if (request === ticket) controller.callActiveChanged(ticket, inCallMode(mode)) }
                }
                modeListener = listener
                audio.addOnModeChangedListener(mainExecutor, listener)
            }
            acquireWake()
            powerJob = scope.launch {
                var displayedState = 1L
                var displayedCall = controller.callActive
                while (request === ticket && controller.request(id, instance) === ticket) {
                    val inCall = inCallMode(audio.mode)
                    if (inCall != controller.callActive) controller.callActiveChanged(ticket, inCall)
                    if (displayedState != controller.state || displayedCall != controller.callActive) {
                        displayedState = controller.state
                        displayedCall = controller.callActive
                        manager.notify(ID, notification(ticket))
                    }
                    if (android.os.SystemClock.elapsedRealtime() - powerRefreshAt >= 30000) acquireWake()
                    delay(1000)
                }
            }
        } catch (_: SecurityException) {
            failStart(ticket, startId, attached, "Phone audio service was not authorized.")
        } catch (_: IllegalStateException) {
            failStart(ticket, startId, attached, "Phone audio service could not start.")
        } catch (_: IllegalArgumentException) {
            failStart(ticket, startId, attached, "Phone audio capture setup was rejected.")
        }
        return START_NOT_STICKY
    }

    private fun inCallMode(mode: Int): Boolean =
        mode == AudioManager.MODE_IN_CALL || mode == AudioManager.MODE_IN_COMMUNICATION

    private fun failStart(ticket: PhoneAudioRequest, startId: Int, attached: Boolean, message: String) {
        if (!attached && request === ticket) {
            request = null
            capture?.close()
            capture = null
            captureWorker?.close()
            captureWorker = null
        }
        controller.captureFailed(ticket, message)
        stopSelfResult(startId)
    }

    private fun startCapture(ticket: PhoneAudioRequest, native: PhoneAudioCapture, worker: PrivateListeningAudioWorker) {
        if (job != null || request !== ticket) return
        job = scope.launch(worker.dispatcher) {
            try {
                native.prepare()
                scope.launch { controller.capturePrepared(ticket) }
                native.run { sequence, pcm -> controller.capturePacket(ticket, sequence, pcm) }
            } catch (_: Exception) {
                scope.launch { controller.captureFailed(ticket, "Phone app audio could not be captured.") }
            }
        }
    }

    private fun projectionData(intent: Intent): Intent? =
        if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(RESULT_DATA, Intent::class.java)
        else @Suppress("DEPRECATION") intent.getParcelableExtra(RESULT_DATA)

    private fun rejectStart(startId: Int): Int {
        if (request == null) stopSelfResult(startId)
        return START_NOT_STICKY
    }

    private fun notification(ticket: PhoneAudioRequest): Notification {
        val stop = PendingIntent.getService(this, 0, Intent(this, PhoneAudioService::class.java)
            .setAction(STOP).setData(Uri.Builder().scheme("anice-phone-audio").authority("stop")
                .appendPath(ticket.id).appendPath(ticket.descriptor.instance).build())
            .putExtra(STREAM, ticket.id).putExtra(INSTANCE, ticket.descriptor.instance),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java)
            .putExtra(OPEN, true), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        return Notification.Builder(this, CHANNEL).setSmallIcon(R.drawable.ic_notification_small)
            .setContentTitle(getString(R.string.phone_audio_title))
            .setContentText(when (controller.state) {
                2L -> if (controller.callActive) getString(R.string.phone_audio_call_excluded)
                    else getString(R.string.phone_audio_notification_active, ticket.descriptor.peer.deviceName)
                4L -> getString(R.string.phone_audio_renewing)
                else -> getString(R.string.phone_audio_preparing)
            })
            .setContentIntent(open).setOngoing(true).setOnlyAlertOnce(true).setShowWhen(false)
            .addAction(Notification.Action.Builder(null, getString(R.string.phone_audio_stop), stop).build())
            .build()
    }

    private fun acquireWake() {
        if (wake == null) {
            wake = getSystemService(PowerManager::class.java).newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK, "$packageName:phone-audio").apply {
                setReferenceCounted(false)
            }
        }
        wake?.acquire(60000)
        powerRefreshAt = android.os.SystemClock.elapsedRealtime()
    }

    private fun releaseWake() {
        try { if (wake?.isHeld == true) wake?.release() } catch (_: Exception) {}
        wake = null
    }

    override fun onDestroy() {
        val ticket = request
        request = null
        job?.cancel(); job = null
        powerJob?.cancel(); powerJob = null
        try {
            if (Build.VERSION.SDK_INT >= 31) {
                (modeListener as? AudioManager.OnModeChangedListener)?.let {
                    audio.removeOnModeChangedListener(it)
                }
            }
            modeListener = null
            capture?.close()
        }
        finally {
            try { capture = null; captureWorker?.close(); captureWorker = null }
            finally {
                try { releaseWake() }
                finally {
                    try { ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE) }
                    finally {
                        try { if (ticket != null) controller.serviceDestroyed(ticket, this) }
                        finally {
                            scope.coroutineContext[Job]?.cancel()
                            super.onDestroy()
                        }
                    }
                }
            }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    companion object {
        const val STREAM = "phoneAudioStream"
        const val INSTANCE = "phoneAudioChannel"
        const val RESULT_CODE = "phoneAudioProjectionResult"
        const val RESULT_DATA = "phoneAudioProjectionData"
        const val OPEN = "io.github.anisharyal09.anice.OPEN_PRIVATE_LISTENING"
        private const val CHANNEL = "phone_audio_v1"
        private const val ID = 4103
        private const val STOP = "io.github.anisharyal09.anice.STOP_PHONE_AUDIO"
    }
}
