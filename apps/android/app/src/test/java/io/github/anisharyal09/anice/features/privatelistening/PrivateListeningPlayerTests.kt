// SPDX-License-Identifier: GPL-3.0-or-later
// Drives the real playback worker with a native-track fake; tests never open AudioTrack or audible outputs.
package io.github.anisharyal09.anice.features.privatelistening

import android.media.AudioDeviceInfo
import android.media.AudioTrack
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.*
import org.junit.Test

class PrivateListeningPlayerTests {
    private class Track(
        private val now: () -> Long,
        private val modern: Boolean = true,
        private val adjustable: Boolean = true,
        var safe: Boolean = true,
        var advances: Boolean = true,
    ) : ListeningNativeTrack {
        override val initialized = true
        override var bufferSizeInFrames = 11724
            private set
        private var threshold = 11724
        override val startThresholdInFrames: Int? get() = if (modern) threshold else null
        override val performanceMode = AudioTrack.PERFORMANCE_MODE_NONE
        override var playing = false
            private set
        private var started = false
        var flushes = 0
            private set
        private var at = now()
        private var pending = 0
        private var head = 0
        override val playbackHeadPosition get(): Int { drain(); return head }
        override val underrunCount = 0
        override val routes get() = if (!playing) emptyList() else listOf(ListeningRoute(
            if (safe) AudioDeviceInfo.TYPE_WIRED_HEADPHONES else AudioDeviceInfo.TYPE_BUILTIN_SPEAKER, "", "Fixture"))
        var volume = 0f
            private set
        var nonzeroFrames = 0
            private set
        var maximumAudiblePending = 0
            private set
        var maximumPending = 0
            private set
        var released = false
            private set
        var maxWriteFrames = 1000
        var changed: () -> Unit = {}
        override fun setBufferSizeInFrames(frames: Int): Int {
            if (adjustable) bufferSizeInFrames = frames.coerceIn(1, 11724)
            return bufferSizeInFrames
        }
        override fun setStartThresholdInFrames(frames: Int) {
            if (modern) threshold = frames.coerceIn(1, bufferSizeInFrames)
        }
        override fun setRoutingListener(changed: () -> Unit) { this.changed = changed }
        override fun setVolume(volume: Float): Boolean { this.volume = volume; return true }
        override fun pause() { drain(); playing = false }
        override fun flush() { flushes++; pending = 0; head = 0; started = false; at = now() }
        override fun play() {
            playing = true
            if (pending >= minOf(threshold, bufferSizeInFrames)) started = true
            at = now()
        }
        override fun write(bytes: ByteArray, offset: Int, count: Int): Int {
            check(!released)
            drain()
            val frames = minOf(count / 4, maxWriteFrames, (bufferSizeInFrames - pending).coerceAtLeast(0))
            if (frames == 0) return 0
            val audible = (offset until offset + frames * 4).any { bytes[it] != 0.toByte() }
            if (audible) {
                check(safe && volume == 1f) { "Nonzero PCM escaped the route/volume gate" }
                nonzeroFrames += frames
            }
            pending += frames
            maximumPending = maxOf(maximumPending, pending)
            if (audible) maximumAudiblePending = maxOf(maximumAudiblePending, pending)
            if (playing && pending >= minOf(threshold, bufferSizeInFrames)) started = true
            return frames * 4
        }
        override fun release() { released = true; playing = false }
        private fun drain() {
            val time = now()
            if (playing && started && advances) {
                val frames = minOf(pending.toLong(), maxOf(0, time - at) * 48).toInt()
                pending -= frames
                head += frames
            }
            at = time
        }
    }

    private val id = "01234567-89ab-4cde-8fab-0123456789ab"
    private fun packet(sequence: Long) = PrivateListeningMessage.audio(id, sequence,
        ByteArray(3840) { if (it % 2 == 0) 40 else 0 })
    private fun clock(): () -> Long {
        val origin = System.nanoTime()
        return { 1000 + (System.nanoTime() - origin) / 1_000_000 }
    }

    @Test fun workerKeepsModernNativeWritesSmallEvenWhenPlatformCapacityIsLarge() = runBlocking {
        val now = clock()
        val track = Track(now, adjustable = false)
        val player = PrivateListeningPlayer({ track }, emptySet(), ListeningBufferProfile.LOWER_DELAY,
            now = now) { fail("Safe route must not be retired") }
        player.prepare()
        assertEquals(0, track.nonzeroFrames)
        assertEquals(11724, track.bufferSizeInFrames)
        for (sequence in 1L..6) player.offer(packet(sequence))
        val pumping = launch { player.pump {} }
        try {
            withTimeout(3000) { while (track.nonzeroFrames < 960) delay(5) }
            assertTrue("Native writes must not fill allocated capacity", track.maximumAudiblePending <= 960)
            assertTrue(track.maximumPending <= 960)
        } finally { player.close(); pumping.cancelAndJoin() }
        assertTrue(track.released)
    }

    @Test fun unsafeNativeRouteAllowsOnlySilentPreparationAndFailsClosed() = runBlocking {
        var time = 0L
        val now = { time += 25; time }
        val track = Track(now, safe = false)
        val player = PrivateListeningPlayer({ track }, emptySet(), ListeningBufferProfile.LOWER_DELAY,
            now = now) {}
        try {
            player.prepare()
            fail("Speaker route must not complete preparation")
        } catch (error: PrivateListeningPlaybackError) {
            assertEquals(6L, error.result)
        }
        assertEquals(0, track.nonzeroFrames)
        assertEquals(0f, track.volume, 0f)
        assertTrue(track.released)
    }

    @Test fun pauseAndSilentResumeFenceWritesAndAcceptCurrentAudioDuringPriming() = runBlocking {
        val now = clock()
        val track = Track(now)
        val player = PrivateListeningPlayer({ track }, emptySet(), ListeningBufferProfile.LOWER_DELAY,
            now = now) { fail("Safe route must not be retired") }
        player.prepare()
        player.pause()
        assertFalse(player.offer(packet(1)))
        val before = track.nonzeroFrames
        player.beginResume()
        for (sequence in 2L..7) assertTrue(player.offer(packet(sequence)))
        assertEquals(before, track.nonzeroFrames)
        player.resume()
        assertEquals(before, track.nonzeroFrames)
        val pumping = launch { player.pump {} }
        try {
            withTimeout(3000) { while (track.nonzeroFrames == before) delay(5) }
            player.pause()
            val paused = track.nonzeroFrames
            delay(20)
            assertEquals(paused, track.nonzeroFrames)
            assertEquals(0f, track.volume, 0f)
        } finally { player.close(); pumping.cancelAndJoin() }
    }

    @Test fun olderPlatformStartupFloorIsHonoredWithoutDeadlockingTheWorker() = runBlocking {
        val now = clock()
        val track = Track(now, modern = false, adjustable = false)
        val player = PrivateListeningPlayer({ track }, emptySet(), ListeningBufferProfile.LOWER_DELAY,
            now = now) {}
        player.prepare()
        for (sequence in 1L..15) player.offer(packet(sequence))
        var health: ListeningPlaybackHealth? = null
        val pumping = launch { player.pump { health = it } }
        try {
            withTimeout(3000) { while (track.nonzeroFrames == 0 || health == null) delay(5) }
            assertEquals(11724, health!!.targetFrames)
            assertEquals(11724, health!!.nativeWriteLimitFrames)
            assertTrue(health!!.queuedFrames <= 38400)
        } finally { player.close(); pumping.cancelAndJoin() }
    }

    @Test fun aStalledNativeHeadCannotHoldThePlaybackWorkerIndefinitely() = runBlocking {
        var time = 0L
        val now = { time += 20; time }
        val track = Track(now)
        val player = PrivateListeningPlayer({ track }, emptySet(), ListeningBufferProfile.LOWER_DELAY,
            now = now) {}
        player.prepare()
        track.advances = false
        for (sequence in 1L..6) player.offer(packet(sequence))
        try {
            withTimeout(3000) { player.pump {} }
            fail("A stalled native head must fail")
        } catch (error: PrivateListeningPlaybackError) {
            assertEquals(8L, error.result)
            assertTrue(error.message!!.contains("progressing"))
        } finally { player.close() }
    }

    @Test fun routeLossAfterReadyPausesImmediatelyAndNeverWritesToTheSpeaker() = runBlocking {
        val now = clock()
        val track = Track(now)
        var losses = 0
        val player = PrivateListeningPlayer({ track }, emptySet(), ListeningBufferProfile.LOWER_DELAY,
            now = now) { losses++ }
        player.prepare()
        track.safe = false
        track.changed()
        assertEquals(1, losses)
        assertFalse(player.offer(packet(1)))
        assertEquals(0, track.nonzeroFrames)
        assertEquals(0f, track.volume, 0f)
        assertFalse(track.playing)
        player.close()
    }

    @Test fun aLargeArrivalBurstIsTrimmedOnceThenCurrentAudioActuallyPlays() = runBlocking {
        val now = clock()
        val track = Track(now)
        val player = PrivateListeningPlayer({ track }, emptySet(), ListeningBufferProfile.LOWER_DELAY,
            now = now) {}
        player.prepare()
        for (sequence in 1L..30) player.offer(packet(sequence))
        var health: ListeningPlaybackHealth? = null
        val pumping = launch { player.pump { health = it } }
        try {
            withTimeout(3000) { while (track.nonzeroFrames == 0 || health == null) delay(5) }
            assertTrue(health!!.droppedPackets > 0)
            assertTrue(health!!.queuedFrames <= health!!.targetFrames + 960)
            assertTrue(track.maximumAudiblePending <= 1920)
        } finally { player.close(); pumping.cancelAndJoin() }
    }

    @Test fun repeatedPartialNativeWritesDoNotDuplicateTheSourceIntervalOrExceedTheLimit() = runBlocking {
        val now = clock()
        val track = Track(now).apply { maxWriteFrames = 120 }
        val player = PrivateListeningPlayer({ track }, emptySet(), ListeningBufferProfile.LOWER_DELAY,
            now = now) {}
        player.prepare()
        for (sequence in 1L..4) assertTrue(player.offer(packet(sequence)))
        val pumping = launch { player.pump {} }
        try {
            withTimeout(3000) { while (track.nonzeroFrames < 958) delay(2) }
            assertTrue(track.maximumAudiblePending <= 1920)
            assertTrue(track.nonzeroFrames <= 4 * 964)
        } finally { player.close(); pumping.cancelAndJoin() }
    }

    @Test fun firstRoutingCallbackDuringListenerRegistrationCannotRejectSilentPreparation() = runBlocking {
        val now = clock()
        val native = Track(now)
        val track = object : ListeningNativeTrack by native {
            override fun setRoutingListener(changed: () -> Unit) {
                native.setRoutingListener(changed)
                changed() // No route exists until play; initial callback is not route loss.
            }
        }
        var losses = 0
        val player = PrivateListeningPlayer({ track }, emptySet(), ListeningBufferProfile.LOWER_DELAY,
            now = now) { losses++ }
        player.prepare()
        assertEquals(0, losses)
        assertEquals(0, native.nonzeroFrames)
        player.close()
    }

    @Test fun isolatedSequenceGapPlaysTheCurrentPacketWithoutAnotherSilentPrimingCycle() = runBlocking {
        val now = clock()
        val track = Track(now)
        val player = PrivateListeningPlayer({ track }, emptySet(), ListeningBufferProfile.LOWER_DELAY,
            now = now) {}
        player.prepare()
        val preparedFlushes = track.flushes
        for (sequence in listOf(1L, 2L)) player.offer(packet(sequence))
        var health: ListeningPlaybackHealth? = null
        val pumping = launch { player.pump { health = it } }
        try {
            withTimeout(3000) { while (track.nonzeroFrames < 950) delay(2) }
            for (sequence in listOf(4L, 5L, 6L, 7L)) {
                player.offer(packet(sequence))
                delay(20)
            }
            withTimeout(4000) {
                while (track.nonzeroFrames < 3 * 950) delay(2)
            }
            assertTrue("Current gap packet must be played, not repeatedly discarded", track.nonzeroFrames >= 2850)
            assertEquals("A gap must not reopen silent preparation", preparedFlushes, track.flushes)
            assertFalse(track.released)
        } finally { player.close(); pumping.cancelAndJoin() }
    }
}
