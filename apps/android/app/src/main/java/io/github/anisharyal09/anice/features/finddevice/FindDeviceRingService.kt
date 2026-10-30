// SPDX-License-Identifier: GPL-3.0-or-later
// Owns native alarm-stream playback and audio focus only for a live bounded Find Device lease on the main thread.
package io.github.anisharyal09.anice.features.finddevice

import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import androidx.core.app.ServiceCompat
import io.github.anisharyal09.anice.AniCeApplication
import java.io.IOException

class FindDeviceRingService : Service() {
    private val handler = Handler(Looper.getMainLooper())
    private val app get() = application as AniCeApplication
    private val presenter get() = app.findDeviceNotification
    private val audio by lazy { getSystemService(AudioManager::class.java) }
    private var lease: FindDeviceRing? = null
    private var player: MediaPlayer? = null
    private var focus: AudioFocusRequest? = null
    private var expiry: Runnable? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val ring = intent?.getStringExtra(FindDeviceNotification.EXTRA_IDENTIFIER)?.let(presenter::request)
        if (ring == null) {
            if (lease == null) stopSelfResult(startId)
            return START_NOT_STICKY
        }
        if (lease === ring) return START_NOT_STICKY
        releaseAudio()
        lease = ring
        ring.stop = { if (lease === ring) finish(ring, FindResult.STALE) }
        if (!presenter.permitted()) { finish(ring, FindResult.BLOCKED); return START_NOT_STICKY }
        try {
            ServiceCompat.startForeground(this, FindDeviceNotification.ID, presenter.notification(ring), ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
            if (audio.getStreamVolume(AudioManager.STREAM_ALARM) == 0 || audio.isStreamMute(AudioManager.STREAM_ALARM)) {
                finish(ring, FindResult.FAILED); return START_NOT_STICKY
            }
            val attributes = AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build()
            val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
                .setAudioAttributes(attributes).setAcceptsDelayedFocusGain(false)
                .setOnAudioFocusChangeListener({ change -> if (change < 0 && lease === ring) finish(ring, FindResult.FAILED) }, handler).build()
            focus = request
            if (audio.requestAudioFocus(request) != AudioManager.AUDIOFOCUS_REQUEST_GRANTED) {
                finish(ring, FindResult.FAILED); return START_NOT_STICKY
            }
            val tone = RingtoneManager.getActualDefaultRingtoneUri(this, RingtoneManager.TYPE_ALARM)
                ?: RingtoneManager.getActualDefaultRingtoneUri(this, RingtoneManager.TYPE_RINGTONE)
            if (tone == null) { finish(ring, FindResult.FAILED); return START_NOT_STICKY }
            val native = MediaPlayer()
            player = native
            native.setAudioAttributes(attributes)
            native.setWakeMode(this, PowerManager.PARTIAL_WAKE_LOCK)
            native.setOnPreparedListener {
                if (lease !== ring || presenter.request(ring.identifier) !== ring || player !== native) return@setOnPreparedListener
                try {
                    native.isLooping = true
                    native.start()
                    ring.started = true
                    ring.ready.complete(FindResult.SUBMITTED)
                } catch (_: IllegalStateException) { finish(ring, FindResult.FAILED) }
            }
            native.setOnErrorListener { _, _, _ -> if (lease === ring) finish(ring, FindResult.FAILED); true }
            // Preparation consumes the original lease; starting audio does not extend its ringing deadline.
            expiry = Runnable { if (lease === ring) finish(ring, FindResult.STALE) }.also {
                handler.postDelayed(it, maxOf(1, ring.deadline - SystemClock.elapsedRealtime()))
            }
            native.setDataSource(this, tone)
            native.prepareAsync()
        } catch (_: SecurityException) { finish(ring, FindResult.FAILED) }
        catch (_: IOException) { finish(ring, FindResult.FAILED) }
        catch (_: IllegalArgumentException) { finish(ring, FindResult.FAILED) }
        catch (_: IllegalStateException) { finish(ring, FindResult.FAILED) }
        return START_NOT_STICKY
    }
    private fun finish(ring: FindDeviceRing, result: FindResult) {
        if (lease !== ring) return
        lease = null
        ring.stop = null
        releaseAudio()
        ring.ready.complete(result)
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        if (ring.started) {
            app.findDevice.dismiss(ring.identifier)
            presenter.clear(ring.identifier)
        }
        stopSelf()
    }
    private fun releaseAudio() {
        expiry?.let(handler::removeCallbacks); expiry = null
        player?.release(); player = null
        focus?.let { audio.abandonAudioFocusRequest(it) }; focus = null
    }
    override fun onDestroy() {
        val ring = lease
        lease = null
        releaseAudio()
        if (ring != null) {
            ring.stop = null
            ring.ready.complete(FindResult.FAILED)
            if (ring.started) {
                app.findDevice.dismiss(ring.identifier)
                presenter.clear(ring.identifier)
            }
        }
        super.onDestroy()
    }
    override fun onBind(intent: Intent?): IBinder? = null
}
