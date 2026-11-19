// SPDX-License-Identifier: GPL-3.0-or-later
// Owns silent route verification and bounded AudioTrack writes on one audio worker with immediate pause/flush interruption.
package io.github.anisharyal09.anice.features.privatelistening

import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRouting
import android.media.AudioTrack
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlin.coroutines.coroutineContext
import kotlin.math.max

internal class PrivateListeningPlaybackError(val result: Long, message: String) : Exception(message)

internal data class ListeningPlaybackHealth(
    val sequence: Long,
    val positionFrames: Long,
    val queuedFrames: Int,
    val underruns: Long,
    val rebuffering: Boolean,
)

internal class PrivateListeningPlayer(
    private val audio: AudioManager,
    private val confirmedRoutes: Set<String>,
    private val routeLost: () -> Unit,
) {
    private val queue = PrivateListeningAudioQueue()
    private val resampler = PrivateListeningResampler()
    private val playbackClock = PrivateListeningPlaybackClock()
    private val scratch = ByteArray(4096)
    private val silence = ByteArray(3840)
    private val nativeLock = Any()
    private val worker = Mutex()
    @Volatile private var track: AudioTrack? = null
    @Volatile private var closed = false
    @Volatile private var primingToken: Long? = null
    @Volatile private var paused = false
    @Volatile private var nativeFrames = 0
    @Volatile private var stagingFrames = 0
    private var writtenFrames = 0L
    private var expectedOffset: Long? = null
    var performanceMode = AudioTrack.PERFORMANCE_MODE_NONE
        private set
    private val routing = AudioRouting.OnRoutingChangedListener {
        if (!closed && primingToken == null && !paused && !safeRoute()) interruptRoute()
    }

    suspend fun prepare() = worker.withLock {
        val minimum = AudioTrack.getMinBufferSize(48000, AudioFormat.CHANNEL_OUT_STEREO,
            AudioFormat.ENCODING_PCM_16BIT)
        if (minimum <= 0 || minimum / 4 > 37400) throw PrivateListeningPlaybackError(3, "Audio buffer unsupported")
        val candidate = audio.getDevices(AudioManager.GET_DEVICES_OUTPUTS).firstOrNull {
            PrivateListeningRoutes.privateOutput(it.route(), confirmedRoutes)
        } ?: throw PrivateListeningPlaybackError(6, "Connect or confirm your headphones")
        fun create(mode: Int): AudioTrack = AudioTrack.Builder()
            .setAudioAttributes(ATTRIBUTES)
            .setAudioFormat(AudioFormat.Builder().setSampleRate(48000).setChannelMask(AudioFormat.CHANNEL_OUT_STEREO)
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT).build())
            .setTransferMode(AudioTrack.MODE_STREAM)
            .setBufferSizeInBytes(max(minimum, 15360))
            .setPerformanceMode(mode).build()
        val native = try { create(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY) }
            catch (_: IllegalArgumentException) { create(AudioTrack.PERFORMANCE_MODE_NONE) }
        synchronized(nativeLock) {
            if (closed) {
                native.release()
                throw CancellationException()
            }
            track = native
        }
        var prepared = false
        try {
            if (native.state != AudioTrack.STATE_INITIALIZED || native.bufferSizeInFrames > 37400) {
                throw PrivateListeningPlaybackError(3, "Native playback buffer exceeds budget")
            }
            performanceMode = native.performanceMode
            if (!native.setPreferredDevice(candidate)) {
                throw PrivateListeningPlaybackError(6, "Headphone route unavailable")
            }
            native.addOnRoutingChangedListener(routing, Handler(Looper.getMainLooper()))
            prime()
            prepared = true
        } finally { if (!prepared) close() }
    }

    fun offer(message: PrivateListeningMessage): Boolean {
        if (closed || paused) return false
        // Reserve one maximum resampler output while the worker owns a packet outside the FIFO.
        return queue.offer(message, nativeFrames + 1000)
    }

    fun pause() {
        paused = true
        queue.pause(discard = true)
        synchronized(nativeLock) {
            track?.setVolume(0f)
            track?.pause()
            track?.flush()
            resetCounters()
        }
    }

    suspend fun resume() {
        if (closed) return
        val token = primingToken ?: return
        worker.withLock {
            if (closed || paused || !queue.currentPreparation(token)) throw CancellationException()
            prime(token)
        }
    }

    fun beginResume() {
        if (closed) return
        // Wire admission resumes immediately; only silent priming may write until route verification.
        primingToken = queue.beginPriming()
        paused = false
    }

    private suspend fun prime(resumeToken: Long? = null) {
        val native = track ?: throw PrivateListeningPlaybackError(8, "AudioTrack missing")
        val token = resumeToken ?: queue.beginPriming()
        if (paused || !queue.currentPreparation(token)) throw CancellationException()
        primingToken = token
        queue.consumeDiscontinuity()
        synchronized(nativeLock) {
            if (closed) throw CancellationException()
            native.pause()
            native.flush()
            native.setVolume(0f)
            resetCounters()
        }
        val deadline = SystemClock.elapsedRealtime() + 2000
        try {
            var primed = 0
            val target = max(3840, native.bufferSizeInFrames)
            while (primed < target && SystemClock.elapsedRealtime() < deadline) {
                coroutineContext.ensureActive()
                val count = synchronized(nativeLock) {
                    if (closed || paused || !queue.currentPreparation(token)) throw CancellationException()
                    val count = native.write(silence, 0, silence.size, AudioTrack.WRITE_NON_BLOCKING)
                    if (count > 0) writtenFrames += count / 4
                    if (count > 0 && native.playState != AudioTrack.PLAYSTATE_PLAYING) native.play()
                    count
                }
                if (count < 0 || count % 4 != 0) throw PrivateListeningPlaybackError(8, "Silent priming failed ($count)")
                primed += count / 4
                if (count == 0) delay(5)
            }
            if (primed < target) throw PrivateListeningPlaybackError(8, "Silent priming timed out")
            while (SystemClock.elapsedRealtime() < deadline) {
                coroutineContext.ensureActive()
                if (closed || paused || !queue.currentPreparation(token)) throw CancellationException()
                if (safeRoute()) {
                    resampler.reset()
                    expectedOffset = null
                    synchronized(nativeLock) {
                        if (closed || paused || !queue.currentPreparation(token)) throw CancellationException()
                        if (native.setVolume(1f) != AudioTrack.SUCCESS) {
                            throw PrivateListeningPlaybackError(8, "Audio volume setup failed")
                        }
                    }
                    if (!queue.primed(token)) throw CancellationException()
                    updateNativeFrames()
                    return
                }
                delay(10)
            }
            throw PrivateListeningPlaybackError(6, "Audio is not routed only to approved headphones")
        } finally { if (primingToken == token) primingToken = null }
    }

    suspend fun pump(health: (ListeningPlaybackHealth) -> Unit) {
        var reportAt = 0L
        var rebuffering = true
        while (!closed) {
            coroutineContext.ensureActive()
            if (paused || primingToken != null) { delay(10); continue }
            rebuffering = worker.withLock { pumpOnce(rebuffering) }
            val now = SystemClock.elapsedRealtime()
            if (now - reportAt >= 1000) {
                reportAt = now
                health(ListeningPlaybackHealth(queue.highestSequence,
                    synchronized(nativeLock) { playbackClock.sourcePosition },
                    (queue.queuedFrames + nativeFrames + stagingFrames).coerceAtMost(38400),
                    synchronized(nativeLock) { track?.underrunCount?.toLong()?.coerceAtLeast(0) ?: 0 },
                    rebuffering))
            }
            delay(2)
        }
    }

    private suspend fun pumpOnce(wasRebuffering: Boolean): Boolean {
            if (closed || paused || primingToken != null) return true
            var rebuffering = wasRebuffering
            updateNativeFrames()
            if (!safeRoute()) { interruptRoute(); throw PrivateListeningPlaybackError(6, "Headphone route lost") }
            if (queue.queuedFrames == 0 && nativeFrames == 0) {
                rebuffering = true
            }
            if (rebuffering && queue.queuedFrames + nativeFrames < queue.targetFrames) return true
            if (rebuffering) {
                queue.trimToTarget()
                queue.consumeDiscontinuity()
                resampler.reset()
                expectedOffset = null
                rebuffering = false
            }
            val packet = queue.take()
            if (packet == null) return rebuffering
            val token = queue.revision
            val discontinuity = queue.consumeDiscontinuity()
            if (discontinuity || (expectedOffset != null && expectedOffset != packet.offset)) {
                if (queue.permitsWrite(token)) prime()
                return true
            }
            resampler.correct(queue.queuedFrames + nativeFrames + 960)
            val bytes = resampler.process(packet.pcm, scratch)
            stagingFrames = bytes / 4
            var offset = 0
            while (offset < bytes && !closed && !paused && primingToken == null && queue.permitsWrite(token)) {
                coroutineContext.ensureActive()
                if (!safeRoute()) { interruptRoute(); throw PrivateListeningPlaybackError(6, "Headphone route lost") }
                val count = synchronized(nativeLock) {
                    if (closed || paused || primingToken != null || !queue.permitsWrite(token)) 0 else {
                        val count = track?.write(scratch, offset, bytes - offset, AudioTrack.WRITE_NON_BLOCKING) ?: -1
                        if (count > 0) writtenFrames += count / 4
                        count
                    }
                }
                if (count < 0 || count % 4 != 0) throw PrivateListeningPlaybackError(8, "Audio write failed ($count)")
                offset += count
                stagingFrames = (bytes - offset) / 4
                if (count == 0) delay(5)
                updateNativeFrames()
            }
            if (offset == bytes && queue.permitsWrite(token)) {
                synchronized(nativeLock) {
                    playbackClock.submitted(writtenFrames, bytes / 4, packet.offset)
                }
                expectedOffset = packet.offset + 960
            }
            stagingFrames = 0
            return rebuffering
    }

    fun close() {
        closed = true
        queue.close()
        synchronized(nativeLock) {
            val native = track
            track = null
            if (native != null) {
                try {
                    native.setVolume(0f)
                    native.pause()
                    native.flush()
                } finally {
                    native.removeOnRoutingChangedListener(routing)
                    native.release()
                }
            }
            nativeFrames = 0
        }
    }

    fun checkRoute() {
        if (!closed && primingToken == null && !paused && !safeRoute()) interruptRoute()
    }

    private fun safeRoute(): Boolean = synchronized(nativeLock) {
        val native = track ?: return@synchronized false
        val routes = if (Build.VERSION.SDK_INT >= 36) native.routedDevices
            else listOfNotNull(native.routedDevice)
        PrivateListeningRoutes.approved(routes.map { it.route() }, confirmedRoutes)
    }

    private fun interruptRoute() {
        try { pause() } finally { routeLost() }
    }

    private fun updateNativeFrames() {
        synchronized(nativeLock) {
            val played = playbackClock.head(track?.playbackHeadPosition ?: 0)
            nativeFrames = (writtenFrames - played).coerceIn(0, 38400).toInt()
        }
    }

    private fun resetCounters() {
        writtenFrames = 0
        playbackClock.reset()
        nativeFrames = 0
    }

    private fun AudioDeviceInfo.route() = ListeningRoute(type, address.orEmpty(), productName.toString())

    companion object {
        val ATTRIBUTES: AudioAttributes = AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build()
    }
}
