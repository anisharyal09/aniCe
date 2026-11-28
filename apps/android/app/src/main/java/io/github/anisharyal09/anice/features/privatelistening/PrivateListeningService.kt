// SPDX-License-Identifier: GPL-3.0-or-later
// Promotes one authenticated listening ticket to native media playback with focus, power and headphone lifecycle ownership.
package io.github.anisharyal09.anice.features.privatelistening

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import io.github.anisharyal09.anice.AniCeApplication
import io.github.anisharyal09.anice.MainActivity
import io.github.anisharyal09.anice.R
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout

class PrivateListeningService : Service() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val app get() = application as AniCeApplication
    private val controller get() = app.privateListening
    private val audio by lazy { getSystemService(AudioManager::class.java) }
    private val handler = Handler(Looper.getMainLooper())
    private var request: PrivateListeningRequest? = null
    private var player: PrivateListeningPlayer? = null
    private var audioWorker: PrivateListeningAudioWorker? = null
    private var job: Job? = null
    private var powerJob: Job? = null
    private var focus: AudioFocusRequest? = null
    private var wake: PowerManager.WakeLock? = null
    private var wifi: WifiManager.WifiLock? = null
    private var noisyRegistered = false
    private var devicesRegistered = false
    private var focusGranted = false
    private var powerRefreshAt = 0L
    private val noisy = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == AudioManager.ACTION_AUDIO_BECOMING_NOISY) {
                recoverRoute()
            }
        }
    }
    private fun recoverRoute() {
        val ticket = request ?: return
        if (ticket.priming) return // Coalesce noisy/routing/device callbacks for this recovery.
        if (!ticket.speakerFallback || !ticket.ready || player?.prepareSpeakerFallback() != true) {
            controller.stop(reason = 2, message = "Approved audio route lost.")
            return
        }
        controller.outputRouteChanged(ticket)
    }
    private val devices = object : AudioDeviceCallback() {
        override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>) {
            player?.checkRoute()
        }
    }

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
        request = ticket
        var attached = false
        try {
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(NotificationChannel(CHANNEL,
                getString(R.string.listening_title), NotificationManager.IMPORTANCE_LOW).apply {
                setSound(null, null); enableVibration(false); setShowBadge(false)
            })
            ServiceCompat.startForeground(this, ID, notification(ticket),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
            val output = PrivateListeningPlayer(audio, app.listeningConfirmedRoutes(), ticket.bufferProfile,
                ticket.speakerFallback) {
                handler.post { if (request === ticket) recoverRoute() }
            }
            player = output
            val worker = PrivateListeningAudioWorker()
            audioWorker = worker
            val binding = object : PrivateListeningOutput {
                override fun offer(message: PrivateListeningMessage) = output.offer(message)
                override fun pause() {
                    try { output.pause() }
                    finally { if (ticket.focusPaused) releasePower() }
                }
                override fun beginResume() = output.beginResume()
                override suspend fun resume() {
                    if (!focusGranted) throw CancellationException("Audio focus is not granted")
                    acquirePower()
                    withContext(worker.dispatcher) { output.resume() }
                }
                override fun close() = output.close()
            }
            if (!controller.serviceAttached(ticket, this, binding)) {
                request = null
                player = null
                audioWorker = null
                output.close()
                worker.close()
                stopSelfResult(startId)
                return START_NOT_STICKY
            }
            attached = true
            focus = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(PrivateListeningPlayer.ATTRIBUTES)
                .setAcceptsDelayedFocusGain(false).setWillPauseWhenDucked(true)
                .setOnAudioFocusChangeListener({ change ->
                    if (request !== ticket) return@setOnAudioFocusChangeListener
                    when (change) {
                        AudioManager.AUDIOFOCUS_LOSS -> {
                            focusGranted = false
                            controller.focusChanged(ticket, false, permanent = true)
                        }
                        AudioManager.AUDIOFOCUS_LOSS_TRANSIENT,
                        AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> {
                            focusGranted = false
                            controller.focusChanged(ticket, false)
                        }
                        AudioManager.AUDIOFOCUS_GAIN -> {
                            focusGranted = true
                            controller.focusChanged(ticket, true)
                        }
                    }
                }, handler).build()
            if (audio.requestAudioFocus(requireNotNull(focus)) != AudioManager.AUDIOFOCUS_REQUEST_GRANTED) {
                controller.failed(ticket, 5, "Phone audio focus was denied.")
                stopSelfResult(startId)
                return START_NOT_STICKY
            }
            focusGranted = true
            acquirePower()
            ContextCompat.registerReceiver(this, noisy, IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY),
                ContextCompat.RECEIVER_EXPORTED)
            noisyRegistered = true
            audio.registerAudioDeviceCallback(devices, handler)
            devicesRegistered = true
            powerJob = scope.launch {
                var previousState = controller.state
                var previousRoute = controller.diagnostics?.routeType
                while (request === ticket && controller.request(id, instance) === ticket) {
                    if (focusGranted && android.os.SystemClock.elapsedRealtime() - powerRefreshAt >= 30000) acquirePower()
                    if (previousState != controller.state || previousRoute != controller.diagnostics?.routeType) {
                        previousState = controller.state
                        previousRoute = controller.diagnostics?.routeType
                        getSystemService(NotificationManager::class.java).notify(ID, notification(ticket))
                        app.listeningMediaStateChanged()
                    }
                    delay(1000)
                }
            }
            job = scope.launch {
                try {
                    withTimeout(4000) {
                        while (!app.listeningTransferReady()) delay(20)
                        withContext(worker.dispatcher) { output.prepare() }
                    }
                    if (request !== ticket || controller.request(id, instance) !== ticket) return@launch
                    if (!focusGranted || ticket.focusPaused) {
                        controller.failed(ticket, 5, "Phone audio focus changed during preparation.")
                        return@launch
                    }
                    controller.ready(ticket)
                    if (controller.request(id, instance) !== ticket) return@launch
                    withContext(worker.dispatcher) {
                        output.pump { health -> scope.launch { controller.playbackHealth(ticket, health) } }
                    }
                } catch (error: kotlinx.coroutines.TimeoutCancellationException) {
                    controller.failed(ticket, 9, "Audio output preparation timed out.")
                } catch (error: CancellationException) {
                    if (controller.request(id, instance) === ticket) controller.failed(ticket, 8, "Audio preparation was cancelled.")
                } catch (error: PrivateListeningPlaybackError) {
                    controller.failed(ticket, error.result, error.message.orEmpty())
                } catch (_: Exception) {
                    controller.failed(ticket, 8, "Native audio playback failed.")
                }
            }
        } catch (_: SecurityException) {
            failStart(ticket, startId, attached, 4, "Phone audio service was not authorized.")
        } catch (_: IllegalStateException) {
            failStart(ticket, startId, attached, 8, "Phone audio service could not start.")
        } catch (_: IllegalArgumentException) {
            failStart(ticket, startId, attached, 8, "Phone audio setup was rejected.")
        }
        return START_NOT_STICKY
    }

    private fun failStart(ticket: PrivateListeningRequest, startId: Int, attached: Boolean, result: Long, message: String) {
        if (!attached && request === ticket) {
            request = null
            try { player?.close() } catch (_: Exception) {}
            player = null
            audioWorker?.close()
            audioWorker = null
        }
        controller.failed(ticket, result, message)
        stopSelfResult(startId)
    }

    private fun rejectStart(startId: Int): Int {
        if (request == null) stopSelfResult(startId)
        return START_NOT_STICKY
    }

    private fun notification(ticket: PrivateListeningRequest): Notification {
        val stop = PendingIntent.getService(this, 0, Intent(this, PrivateListeningService::class.java)
            .setAction(STOP).setData(Uri.Builder().scheme("anice-listening").authority("stop")
                .appendPath(ticket.id).appendPath(ticket.descriptor.instance).build())
            .putExtra(STREAM, ticket.id).putExtra(INSTANCE, ticket.descriptor.instance),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java)
            .putExtra(OPEN, true), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        return Notification.Builder(this, CHANNEL).setSmallIcon(R.drawable.ic_notification_small)
            .setContentTitle(getString(R.string.listening_title))
            .setContentText(when (controller.state) {
                2L -> if (controller.diagnostics?.routeType == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER)
                    getString(R.string.listening_speaker_active)
                    else getString(R.string.listening_notification_peer, ticket.descriptor.peer.deviceName)
                4L -> getString(R.string.listening_renewing)
                3L -> getString(R.string.listening_focus_paused)
                5L -> getString(R.string.listening_buffering)
                else -> getString(R.string.listening_notification_peer, ticket.descriptor.peer.deviceName)
            })
            .setContentIntent(open).setOngoing(true).setOnlyAlertOnce(true).setShowWhen(false)
            .addAction(Notification.Action.Builder(null, getString(R.string.listening_stop), stop).build())
            .setStyle(Notification.MediaStyle().setMediaSession(app.listeningMediaToken()))
            .build()
    }

    private fun acquirePower() {
        if (request == null) throw CancellationException("Listening service ended")
        if (wake == null) {
            wake = getSystemService(PowerManager::class.java).newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK, "$packageName:private-listening").apply {
                setReferenceCounted(false)
            }
        }
        // Service ownership is bounded by stream watchdogs; lock timeout prevents leaked native ownership.
        wake?.acquire(60000)
        powerRefreshAt = android.os.SystemClock.elapsedRealtime()
        if (wifi == null) {
            val mode = if (Build.VERSION.SDK_INT < 34) WifiManager.WIFI_MODE_FULL_HIGH_PERF
                else WifiManager.WIFI_MODE_FULL_LOW_LATENCY
            try {
                wifi = applicationContext.getSystemService(WifiManager::class.java).createWifiLock(mode,
                    "$packageName:private-listening").apply { setReferenceCounted(false) }
            } catch (_: SecurityException) { /* Radio scheduling is best-effort; CPU/service ownership remains. */ }
        }
        try { if (wifi?.isHeld != true) wifi?.acquire() } catch (_: SecurityException) {}
    }

    private fun releasePower() {
        try { if (wifi?.isHeld == true) wifi?.release() }
        finally { if (wake?.isHeld == true) wake?.release() }
    }

    override fun onDestroy() {
        val ticket = request
        request = null
        job?.cancel(); job = null
        powerJob?.cancel(); powerJob = null
        try { player?.close() }
        finally {
            try {
                player = null
                audioWorker?.close(); audioWorker = null
                if (noisyRegistered) {
                    noisyRegistered = false
                    try { unregisterReceiver(noisy) } catch (_: IllegalArgumentException) {}
                }
                if (devicesRegistered) {
                    devicesRegistered = false
                    audio.unregisterAudioDeviceCallback(devices)
                }
            } finally {
                try { focus?.let { audio.abandonAudioFocusRequest(it) } }
                finally {
                    focus = null; focusGranted = false
                    try { releasePower() }
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
    }

    override fun onBind(intent: Intent?): IBinder? = null

    companion object {
        const val STREAM = "privateListeningStream"
        const val INSTANCE = "privateListeningChannel"
        const val OPEN = "io.github.anisharyal09.anice.OPEN_PRIVATE_LISTENING"
        private const val CHANNEL = "private_listening_v1"
        private const val ID = 4102
        private const val STOP = "io.github.anisharyal09.anice.STOP_PRIVATE_LISTENING"
    }
}
