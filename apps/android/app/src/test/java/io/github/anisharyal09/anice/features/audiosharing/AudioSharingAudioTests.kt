// SPDX-License-Identifier: GPL-3.0-or-later
// Exercises priming gates, newest-audio bounds, drift interpolation and route policy without native playback.
package io.github.anisharyal09.anice.features.audiosharing

import android.media.AudioDeviceInfo
import org.junit.Assert.*
import org.junit.Test

class AudioSharingAudioTests {
    private val stream = "01234567-89ab-4cde-8fab-0123456789ab"
    private fun packet(sequence: Long) = AudioSharingMessage.audio(stream, sequence, ByteArray(3840))

    @Test fun incomingAudioDuringPrimingIsBoundedAndDoesNotOpenTheWriteGate() {
        val queue = AudioSharingAudioQueue(maximumFrames = 3840, targetFrames = 1920)
        val first = queue.beginPriming()
        assertTrue(queue.offer(packet(1)))
        assertTrue(queue.offer(packet(2)))
        assertNull(queue.take())
        assertFalse(queue.writeGateOpen)
        val second = queue.beginPriming()
        assertFalse(queue.primed(first))
        assertTrue(queue.primed(second))
        assertTrue(queue.permitsWrite(second))
        assertEquals(1L, queue.take()!!.sequence)
        queue.pause(discard = true)
        assertFalse(queue.permitsWrite(second))
        assertFalse(queue.primed(second))
        assertNull(queue.take())
        queue.close()
        assertFalse(queue.offer(packet(3)))
        assertFalse(queue.primed(queue.beginPriming()))
    }

    @Test fun overflowIncludesNativeBacklogAndKeepsNewestReceivedAudio() {
        val queue = AudioSharingAudioQueue(maximumFrames = 3840, targetFrames = 1920)
        for (sequence in 1L..8L) assertTrue(queue.offer(packet(sequence), nativeFrames = 960))
        assertEquals(2880, queue.queuedFrames)
        assertEquals(8L, queue.highestSequence)
        assertFalse(queue.offer(packet(8)))
        assertTrue(queue.consumeDiscontinuity())
        queue.trimToTarget()
        assertTrue(queue.primed(queue.beginPriming()))
        assertEquals(1920, queue.queuedFrames)
        assertEquals(7L, queue.take()!!.sequence)
        assertEquals(8L, queue.take()!!.sequence)
        assertNull(queue.take())
    }

    @Test fun nativeCeilingRejectsWithoutAccumulatingOrRevivingOlderPackets() {
        val queue = AudioSharingAudioQueue(maximumFrames = 3840, targetFrames = 960)
        assertFalse(queue.offer(packet(1), nativeFrames = 3840))
        assertEquals(0, queue.queuedFrames)
        assertFalse(queue.offer(packet(1)))
        assertTrue(queue.offer(packet(2)))
        assertTrue(queue.primed(queue.beginPriming()))
        assertEquals(2L, queue.take()!!.sequence)
        queue.close()
        assertFalse(queue.writeGateOpen)
    }

    @Test fun resamplingPreservesStereoPhaseAndConstantSignalAcrossPacketBoundaries() {
        val resampler = AudioSharingResampler()
        val pcm = stereo(12345, -12345)
        val output = ByteArray(4096)
        var total = 0
        repeat(100) {
            val bytes = resampler.process(pcm, output)
            assertTrue(bytes in 3800..4000)
            assertEquals(0, bytes % 4)
            for (offset in 0 until bytes step 4) {
                assertEquals(12345, sample(output, offset))
                assertEquals(-12345, sample(output, offset + 2))
            }
            total += bytes / 4
        }
        assertTrue(total in 95996..96000)
        resampler.reset()
        assertEquals(1.0, resampler.ratio, 0.0)
        assertTrue(resampler.process(ByteArray(3840), output) > 0)
        assertTrue(output.take(3800).all { it == 0.toByte() })
    }

    @Test fun clockCorrectionIsSlewedBoundedAndRespondsToFilteredBacklog() {
        val resampler = AudioSharingResampler()
        val output = ByteArray(4096)
        val pcm = stereo(1000, -1000)
        repeat(5000) {
            val before = resampler.ratio
            resampler.correct(30000)
            assertTrue(kotlin.math.abs(resampler.ratio - before) <= 0.00000201)
            assertTrue(resampler.ratio in 0.997..1.003)
            assertTrue(resampler.process(pcm, output) in 3800..4000)
        }
        assertTrue(resampler.ratio > 1.001)
        repeat(10000) {
            resampler.correct(0)
            assertTrue(resampler.process(pcm, output) in 3800..4000)
        }
        assertTrue(resampler.ratio < 0.999)
    }

    @Test fun cubicBoundaryHistoryDoesNotMixChannelsOrOverflowPCM() {
        val resampler = AudioSharingResampler()
        val pcm = ByteArray(3840)
        for (frame in 0 until 960) {
            val value = if (frame % 2 == 0) 32767 else -32768
            val offset = frame * 4
            pcm[offset] = value.toByte()
            pcm[offset + 1] = (value shr 8).toByte()
        }
        val scratch = ByteArray(4096)
        repeat(2000) {
            resampler.correct(30000)
            val bytes = resampler.process(pcm, scratch)
            for (offset in 0 until bytes step 4) {
                assertEquals(0, sample(scratch, offset + 2))
                assertTrue(sample(scratch, offset) in -32768..32767)
            }
        }
    }

    @Test fun routeApprovalRequiresEveryActualOutputAndDoesNotTrustLabels() {
        val headphones = ListeningRoute(AudioDeviceInfo.TYPE_WIRED_HEADPHONES, "", "Headphones")
        val speaker = ListeningRoute(AudioDeviceInfo.TYPE_BUILTIN_SPEAKER, "", "AirPods")
        val a2dp = ListeningRoute(AudioDeviceInfo.TYPE_BLUETOOTH_A2DP, "AA:BB:CC:DD:EE:FF", "AirPods")
        assertFalse(AudioSharingRoutes.approved(emptyList(), emptySet()))
        assertTrue(AudioSharingRoutes.approved(listOf(headphones), emptySet()))
        assertFalse(AudioSharingRoutes.approved(listOf(headphones, speaker), emptySet()))
        assertFalse(AudioSharingRoutes.approved(listOf(a2dp), emptySet()))
        assertTrue(AudioSharingRoutes.approved(listOf(a2dp), setOf(a2dp.confirmationKey!!)))
        assertFalse(AudioSharingRoutes.approved(listOf(a2dp.copy(address = "")),
            setOf(a2dp.confirmationKey!!)))
        assertFalse(AudioSharingRoutes.approved(listOf(speaker), setOf("2:", "AirPods")))
    }

    @Test fun playbackClockMapsResampledFramesGapsAndNativeCounterWrap() {
        val clock = AudioSharingPlaybackClock()
        clock.submitted(outputEnd = 1920, outputFrames = 960, sourceOffset = 0)
        assertEquals(0L, clock.sourcePosition)
        clock.head(1440)
        assertEquals(480L, clock.sourcePosition)
        clock.head(1920)
        assertEquals(960L, clock.sourcePosition)
        clock.submitted(outputEnd = 2880, outputFrames = 960, sourceOffset = 9600)
        clock.head(2400)
        assertEquals(10080L, clock.sourcePosition)
        clock.head(2880)
        assertEquals(10560L, clock.sourcePosition)
        clock.reset()
        clock.head(-1)
        assertEquals(4294967295L, clock.playedFrames)
        clock.head(0)
        assertEquals(4294967296L, clock.playedFrames)
        clock.reset()
        assertEquals(0L, clock.head(0))
        assertEquals(0L, clock.sourcePosition)
    }

    private fun stereo(left: Int, right: Int) = ByteArray(3840).also { bytes ->
        for (offset in bytes.indices step 4) {
            bytes[offset] = left.toByte()
            bytes[offset + 1] = (left shr 8).toByte()
            bytes[offset + 2] = right.toByte()
            bytes[offset + 3] = (right shr 8).toByte()
        }
    }
    private fun sample(bytes: ByteArray, offset: Int) =
        ((bytes[offset].toInt() and 255) or (bytes[offset + 1].toInt() shl 8)).toShort().toInt()
}
