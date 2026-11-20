// SPDX-License-Identifier: GPL-3.0-or-later
// Owns silent route verification and bounded AudioTrack writes on one audio worker with immediate pause/flush interruption.
package io.github.anisharyal09.anice.features.privatelistening

import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.media.AudioTrack
import android.os.SystemClock
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlin.coroutines.coroutineContext

internal class PrivateListeningPlaybackError(val result: Long, message: String) : Exception(message)

internal data class ListeningPlaybackHealth(
    val sequence: Long,
    val positionFrames: Long,
    val queuedFrames: Int,
    val underruns: Long,
    val rebuffering: Boolean,
    val targetFrames: Int = 9600,
    val nativeQueuedFrames: Int = 0,
    val nativeBufferFrames: Int = 0,
    val nativeWriteLimitFrames: Int = 0,
    val droppedPackets: Long = 0,
    val performanceMode: Int = AudioTrack.PERFORMANCE_MODE_NONE,
    val routeType: Int = AudioDeviceInfo.TYPE_UNKNOWN,
    val gapRecoveries: Long = 0,
    val rebufferCount: Long = 0,
    val maximumArrivalGapMillis: Long = 0,
)

internal class PrivateListeningPlayer(
    makeTrack: () -> ListeningNativeTrack,
    confirmedRoutes: Set<String>,
    profile: ListeningBufferProfile = ListeningBufferProfile.BALANCED,
    now: () -> Long = { SystemClock.elapsedRealtime() },
    routeLost: () -> Unit,
) {
    constructor(audio: AudioManager, confirmedRoutes: Set<String>,
        profile: ListeningBufferProfile = ListeningBufferProfile.BALANCED, routeLost: () -> Unit) :
        this({ PrivateListeningNativeTrack.create(audio, confirmedRoutes) }, confirmedRoutes, profile,
            routeLost = routeLost)

    private val makeTrack = makeTrack
    private val confirmedRoutes = confirmedRoutes
    private val now = now
    private val routeLost = routeLost
    private val bufferProfile = profile
    private val policy = PrivateListeningBufferPolicy(profile)
    private val queue = PrivateListeningAudioQueue(targetFrames = profile.initialFrames)
    private val resampler = PrivateListeningResampler()
    private val playbackClock = PrivateListeningPlaybackClock()
    private val scratch = ByteArray(4096)
    private val silence = ByteArray(3840)
    private val nativeLock = Any()
    private val worker = Mutex()
    @Volatile private var track: ListeningNativeTrack? = null
    @Volatile private var closed = false
    @Volatile private var primingToken: Long? = null
    @Volatile private var paused = false
    @Volatile private var nativeFrames = 0
    @Volatile private var stagingFrames = 0
    @Volatile private var primingReservation = 0
    private var writtenFrames = 0L
    private var expectedOffset: Long? = null
    private var nativeWriteLimit = 0
    private var configuredTarget = 0
    private var configuredBuffer = 0
    private var configuredThreshold: Int? = null
    @Volatile private var hasSubmittedAudio = false
    private var hasPlayedAudio = false
    private var nativeProgressAt: Long? = null
    private var observedHead = 0L
    private var gapRecoveries = 0L
    private var rebufferCount = 0L
    private var lastArrivalAt = 0L
    private var maximumArrivalGapMillis = 0L
    private var fadeNext = false
    var performanceMode = AudioTrack.PERFORMANCE_MODE_NONE
        private set
    private val routing: () -> Unit = {
        if (!closed && primingToken == null && !paused && !safeRoute()) interruptRoute()
    }

    suspend fun prepare() = worker.withLock {
        if (closed) throw CancellationException()
        val native = makeTrack()
        synchronized(nativeLock) {
            if (closed) {
                native.release()
                throw CancellationException()
            }
            track = native
        }
        var prepared = false
        try {
            policy.buffering()
            if (!native.initialized || native.bufferSizeInFrames > PrivateListeningNativeBufferPolicy.MAXIMUM_NATIVE_FRAMES) {
                throw PrivateListeningPlaybackError(3, "Native playback buffer exceeds budget")
            }
            performanceMode = native.performanceMode
            configureNativeBuffer()
            val preparationToken = queue.beginPriming()
            primingToken = preparationToken
            native.setRoutingListener(routing)
            prime(preparationToken)
            prepared = true
        } finally { if (!prepared) close() }
    }

    fun offer(message: PrivateListeningMessage): Boolean {
        if (closed || paused) return false
        // Snapshot native/staging ownership under the same lock as writes before growing the software queue.
        return synchronized(nativeLock) {
            if (closed || paused) false
            else {
                val offered = queue.offer(message, maxOf(nativeFrames, primingReservation) + 1000)
                if (offered) {
                    val time = now()
                    if (lastArrivalAt != 0L) maximumArrivalGapMillis = maxOf(maximumArrivalGapMillis, time - lastArrivalAt)
                    lastArrivalAt = time
                    policy.arrived(message.number(1), time)
                }
                offered
            }
        }
    }

    fun pause() {
        paused = true
        queue.pause(discard = true)
        synchronized(nativeLock) {
            lastArrivalAt = 0
            policy.interrupted()
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
        policy.buffering()
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
        val deadline = now() + 2000
        try {
            var primed = 0
            var target = primingFrames()
            while (primed < target && now() < deadline) {
                coroutineContext.ensureActive()
                primingReservation = target
                queue.trimToMaximum(target + 1000)
                val count = synchronized(nativeLock) {
                    if (closed || paused || !queue.currentPreparation(token)) throw CancellationException()
                    val count = native.write(silence, 0, minOf(silence.size, (target - primed) * 4))
                    if (count > 0) writtenFrames += count / 4
                    if (count > 0 && !native.playing) native.play()
                    count
                }
                if (count < 0 || count % 4 != 0) throw PrivateListeningPlaybackError(8, "Silent priming failed ($count)")
                primed += count / 4
                target = primingFrames()
                if (count == 0) delay(5)
            }
            if (primed < target) throw PrivateListeningPlaybackError(8, "Silent priming timed out")
            while (now() < deadline) {
                coroutineContext.ensureActive()
                if (closed || paused || !queue.currentPreparation(token)) throw CancellationException()
                if (safeRoute()) {
                    configureNativeBuffer()
                    updateNativeFrames()
                    // Do not leave a second silent native buffer ahead of the first real PCM.
                    if (nativeFrames != 0) { delay(5); continue }
                    resampler.reset(combinedTarget())
                    expectedOffset = null
                    synchronized(nativeLock) {
                        if (closed || paused || !queue.currentPreparation(token)) throw CancellationException()
                        if (!native.setVolume(1f)) {
                            throw PrivateListeningPlaybackError(8, "Audio volume setup failed")
                        }
                    }
                    if (!queue.primed(token)) throw CancellationException()
                    updateNativeFrames()
                    return
                }
                delay(10)
            }
            if (safeRoute()) throw PrivateListeningPlaybackError(8, "Native headphone playback stopped progressing")
            throw PrivateListeningPlaybackError(6, "Audio is not routed only to approved headphones")
        } finally {
            primingReservation = 0
            if (primingToken == token) primingToken = null
        }
    }

    suspend fun pump(health: (ListeningPlaybackHealth) -> Unit) {
        var reportAt = 0L
        var rebuffering = true
        var playbackRevision = -1L
        while (!closed) {
            coroutineContext.ensureActive()
            if (paused || primingToken != null) { delay(10); continue }
            if (playbackRevision != queue.revision) {
                playbackRevision = queue.revision
                rebuffering = true
            }
            rebuffering = worker.withLock { pumpOnce(rebuffering) }
            val time = now()
            if (time - reportAt >= 1000) {
                reportAt = time
                health(ListeningPlaybackHealth(queue.highestSequence,
                    synchronized(nativeLock) { playbackClock.sourcePosition },
                    (queue.queuedFrames + nativeFrames + stagingFrames + resampler.bufferedFrames).coerceAtMost(38400),
                    synchronized(nativeLock) { track?.underrunCount?.toLong()?.coerceAtLeast(0) ?: 0 },
                    rebuffering, combinedTarget(), nativeFrames, configuredBuffer,
                    nativeWriteLimit, queue.droppedPackets, performanceMode,
                    synchronized(nativeLock) { track?.routes?.firstOrNull()?.type ?: AudioDeviceInfo.TYPE_UNKNOWN },
                    gapRecoveries, rebufferCount, synchronized(nativeLock) { maximumArrivalGapMillis }))
            }
            delay(2)
        }
    }

    private suspend fun pumpOnce(wasRebuffering: Boolean): Boolean {
            if (closed || paused || primingToken != null) return true
            var rebuffering = wasRebuffering
            updateNativeFrames()
            val time = now()
            val underruns = synchronized(nativeLock) { track?.underrunCount?.toLong()?.coerceAtLeast(0) ?: 0 }
            policy.underruns(underruns, time, playing = hasSubmittedAudio && !rebuffering)
            configureNativeBuffer()
            val target = combinedTarget()
            queue.setTargetFrames(target)
            if (!safeRoute()) { interruptRoute(); throw PrivateListeningPlaybackError(6, "Headphone route lost") }
            val head = synchronized(nativeLock) { playbackClock.playedFrames }
            if (nativeFrames > 0 && queue.queuedFrames > 0) {
                if (nativeProgressAt == null || head != observedHead) nativeProgressAt = time
                else if (time - requireNotNull(nativeProgressAt) >= 2000) {
                    throw PrivateListeningPlaybackError(8, "Native headphone playback stopped progressing")
                }
            } else nativeProgressAt = null
            observedHead = head
            if (queue.queuedFrames == 0 && nativeFrames == 0) {
                if (!rebuffering && hasSubmittedAudio) { policy.starved(time); rebufferCount++ }
                rebuffering = true
            }
            if (rebuffering) policy.buffering()
            var pending = queue.queuedFrames + nativeFrames
            if (pending > target + maxOf(1920, target / 2)) {
                if (nativeFrames > target + 960) {
                    rebufferCount++
                    queue.trimToTarget()
                    if (queue.writeGateOpen) prime()
                    return true
                }
                // Healthy native output can continue while obsolete software packets are removed.
                // The next source boundary resets interpolation/ramp; no silent re-priming loop.
                queue.trimToTarget(nativeFrames)
                pending = queue.queuedFrames + nativeFrames
            }
            if (rebuffering && pending < target) return true
            if (rebuffering) {
                queue.trimToTarget(nativeFrames)
                queue.consumeDiscontinuity()
                resampler.reset(target)
                expectedOffset = null
                fadeNext = hasPlayedAudio
                rebuffering = false
            }
            if (nativeFrames >= nativeWriteLimit) return rebuffering
            val packet = queue.take()
            if (packet == null) return rebuffering
            val token = queue.revision
            if (!queue.permitsWrite(token)) return true
            val discontinuity = queue.consumeDiscontinuity()
            if (discontinuity || (expectedOffset != null && expectedOffset != packet.offset)) {
                // A missing source slot is not lost route authorization. Keep current PCM instead of
                // dropping it and paying a full native pause/flush/silent preparation on every gap.
                gapRecoveries++
                resampler.reset(target)
                expectedOffset = null
                fadeNext = true
            }
            resampler.correct(queue.queuedFrames + nativeFrames + 960, target)
            val bytes = resampler.process(packet.pcm, scratch)
            if (fadeNext) { fadeIn(scratch, bytes); fadeNext = false }
            stagingFrames = bytes / 4
            var offset = 0
            var progressAt = now()
            var previousNativeFrames = nativeFrames
            while (offset < bytes && !closed && !paused && primingToken == null && queue.permitsWrite(token)) {
                coroutineContext.ensureActive()
                if (!safeRoute()) { interruptRoute(); throw PrivateListeningPlaybackError(6, "Headphone route lost") }
                updateNativeFrames()
                if (nativeFrames < previousNativeFrames) progressAt = now()
                previousNativeFrames = nativeFrames
                if (now() - progressAt >= 2000) {
                    throw PrivateListeningPlaybackError(8, "Native headphone playback stopped progressing")
                }
                if (queue.queuedFrames + nativeFrames + stagingFrames > target + maxOf(1920, target / 2)) {
                    queue.trimToTarget(nativeFrames + stagingFrames)
                }
                val available = (nativeWriteLimit - nativeFrames).coerceAtLeast(0)
                if (available == 0) { delay(2); continue }
                val count = synchronized(nativeLock) {
                    if (closed || paused || primingToken != null || !queue.permitsWrite(token)) 0 else {
                        val count = track?.write(scratch, offset, minOf(bytes - offset, available * 4)) ?: -1
                        if (count > 0) writtenFrames += count / 4
                        count
                    }
                }
                if (count < 0 || count % 4 != 0) throw PrivateListeningPlaybackError(8, "Audio write failed ($count)")
                offset += count
                if (count > 0) progressAt = now()
                stagingFrames = (bytes - offset) / 4
                if (count == 0) delay(5)
                updateNativeFrames()
            }
            if (offset == bytes && queue.permitsWrite(token)) {
                val submitted = synchronized(nativeLock) {
                    if (closed || paused || !queue.permitsWrite(token)) return@synchronized false
                    playbackClock.submitted(writtenFrames, bytes / 4, packet.offset)
                    true
                }
                if (submitted) {
                    expectedOffset = packet.offset + 960
                    hasSubmittedAudio = true
                    hasPlayedAudio = true
                    if (nativeFrames > 0 || queue.queuedFrames > 0) policy.healthy(now())
                }
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
                    native.release()
                }
            }
            nativeFrames = 0
            stagingFrames = 0
            primingReservation = 0
            hasSubmittedAudio = false
        }
    }

    fun checkRoute() {
        if (!closed && primingToken == null && !paused && !safeRoute()) interruptRoute()
    }

    private fun safeRoute(): Boolean = synchronized(nativeLock) {
        val native = track ?: return@synchronized false
        PrivateListeningRoutes.approved(native.routes, confirmedRoutes)
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
        hasSubmittedAudio = false
        nativeProgressAt = null
        observedHead = 0
    }

    private fun configureNativeBuffer() = synchronized(nativeLock) {
        val native = track ?: throw CancellationException()
        val target = policy.targetFrames
        val currentBuffer = native.bufferSizeInFrames
        val currentThreshold = native.startThresholdInFrames
        if (configuredTarget == target && configuredBuffer == currentBuffer &&
            configuredThreshold == currentThreshold) return@synchronized
        val requested = PrivateListeningNativeBufferPolicy.requestedFrames(target, bufferProfile)
        // Android may round or reject the requested size; account for the actual buffer and startup floor.
        // Buffer reconfiguration is a best-effort latency hint, not a new playback requirement.
        native.setBufferSizeInFrames(requested)
        val actual = native.bufferSizeInFrames
        if (actual !in 1..PrivateListeningNativeBufferPolicy.MAXIMUM_NATIVE_FRAMES) {
            throw PrivateListeningPlaybackError(3, "Native playback buffer exceeds budget")
        }
        native.setStartThresholdInFrames(minOf(requested, actual))
        val threshold = native.startThresholdInFrames
        nativeWriteLimit = PrivateListeningNativeBufferPolicy.writeLimit(requested, actual, threshold)
        configuredTarget = target
        configuredBuffer = actual
        configuredThreshold = threshold
    }

    private fun primingFrames(): Int = synchronized(nativeLock) {
        val native = track ?: throw CancellationException()
        val actual = native.bufferSizeInFrames
        if (actual !in 1..PrivateListeningNativeBufferPolicy.MAXIMUM_NATIVE_FRAMES) {
            throw PrivateListeningPlaybackError(3, "Native playback buffer exceeds budget")
        }
        maxOf(960, native.startThresholdInFrames?.coerceIn(1, actual) ?: actual)
    }

    private fun combinedTarget(): Int =
        PrivateListeningNativeBufferPolicy.combinedTarget(policy.targetFrames, nativeWriteLimit)

    private fun fadeIn(pcm: ByteArray, bytes: Int) {
        val frames = minOf(240, bytes / 4) // A 5-ms boundary ramp, with no extra queued audio.
        for (frame in 0 until frames) for (channel in 0..1) {
            val offset = frame * 4 + channel * 2
            val sample = ((pcm[offset].toInt() and 255) or (pcm[offset + 1].toInt() shl 8)).toShort().toInt()
            val value = sample * frame / frames
            pcm[offset] = value.toByte()
            pcm[offset + 1] = (value shr 8).toByte()
        }
    }

    companion object {
        val ATTRIBUTES: AudioAttributes by lazy {
            AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build()
        }
    }
}
