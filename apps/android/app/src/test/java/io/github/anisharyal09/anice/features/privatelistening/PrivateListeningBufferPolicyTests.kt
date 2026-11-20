// SPDX-License-Identifier: GPL-3.0-or-later
// Verifies adaptive local backlog, platform startup floors and opt-in profiles without opening audio devices.
package io.github.anisharyal09.anice.features.privatelistening

import org.junit.Assert.*
import org.junit.Test

class PrivateListeningBufferPolicyTests {
    @Test fun balancedRemainsTheDefaultAndLowerDelayIsExplicit() {
        assertEquals(ListeningBufferProfile.BALANCED, ListeningBufferProfile.restored(null))
        assertEquals(ListeningBufferProfile.BALANCED, ListeningBufferProfile.restored("unknown"))
        assertEquals(ListeningBufferProfile.LOWER_DELAY, ListeningBufferProfile.restored("lower_delay"))
        assertEquals(5760, PrivateListeningBufferPolicy().targetFrames)
        assertEquals(1920, PrivateListeningBufferPolicy(ListeningBufferProfile.LOWER_DELAY).targetFrames)
        val preferences = PrivateListeningPreferences()
        assertEquals(ListeningBufferProfile.BALANCED, preferences.bufferProfile())
        preferences.setBufferProfile(ListeningBufferProfile.LOWER_DELAY)
        assertEquals(ListeningBufferProfile.LOWER_DELAY, preferences.bufferProfile())
        preferences.clear()
        assertEquals(ListeningBufferProfile.BALANCED, preferences.bufferProfile())
    }

    @Test fun healthyPlaybackGraduallyReducesBalancedBacklogWithinItsBounds() {
        val policy = PrivateListeningBufferPolicy()
        policy.healthy(0)
        policy.healthy(14999)
        assertEquals(5760, policy.targetFrames)
        policy.healthy(15000)
        assertEquals(4800, policy.targetFrames)
        policy.healthy(30000)
        assertEquals(3840, policy.targetFrames)
        policy.healthy(45000)
        assertEquals(2880, policy.targetFrames)
    }

    @Test fun nativeStarvationRaisesTheTargetWithoutInflatingEveryWorkerTurn() {
        val policy = PrivateListeningBufferPolicy(ListeningBufferProfile.LOWER_DELAY)
        policy.underruns(10, 0) // A first snapshot is not a new underrun.
        assertEquals(1920, policy.targetFrames)
        policy.underruns(11, 100)
        assertEquals(3840, policy.targetFrames)
        policy.starved(200)
        policy.underruns(50, 300)
        assertEquals(3840, policy.targetFrames)
        policy.underruns(51, 1100)
        assertEquals(5760, policy.targetFrames)
        policy.starved(2100)
        assertEquals(7680, policy.targetFrames)
        policy.interrupted()
        policy.underruns(500, 4000)
        assertEquals(7680, policy.targetFrames)
    }

    @Test fun sequenceGapsAreNotMistakenForDeliveryJitterAndInterruptedTimeIsExcluded() {
        val policy = PrivateListeningBufferPolicy(ListeningBufferProfile.LOWER_DELAY)
        policy.arrived(1, 0)
        policy.arrived(51, 1000)
        assertEquals(1920, policy.targetFrames)
        policy.arrived(51, 4000) // Duplicate traffic does not move the observation baseline.
        policy.arrived(52, 1020)
        assertEquals(1920, policy.targetFrames)
        policy.arrived(352, 7020)
        assertEquals(1920, policy.targetFrames)
        policy.interrupted()
        policy.arrived(200, 100000)
        assertEquals(1920, policy.targetFrames)
        policy.arrived(201, 100400)
        assertEquals(7680, policy.targetFrames)
    }

    @Test fun lateBurstsAdaptWithoutLeavingTheProfileOrHardAudioBudget() {
        for (profile in ListeningBufferProfile.entries) {
            val policy = PrivateListeningBufferPolicy(profile)
            for (sequence in 1L..200) {
                policy.arrived(sequence, sequence * 100)
                policy.underruns(sequence, sequence * 100)
                assertTrue(policy.targetFrames in profile.minimumFrames..profile.maximumFrames)
                assertEquals(0, policy.targetFrames % 960)
                assertTrue(policy.targetFrames < 38400)
            }
        }
    }

    @Test fun nativeWriteLimitsRespectPlatformStartupWithoutFillingUnusedCapacity() {
        assertEquals(7200, PrivateListeningNativeBufferPolicy.requestedFrames(9600))
        assertEquals(2880, PrivateListeningNativeBufferPolicy.requestedFrames(3840))
        assertEquals(960, PrivateListeningNativeBufferPolicy.requestedFrames(960))
        assertEquals(1920, PrivateListeningNativeBufferPolicy.writeLimit(1920, 11724, 1920))
        assertEquals(11724, PrivateListeningNativeBufferPolicy.writeLimit(1920, 11724, null))
        assertEquals(11724, PrivateListeningNativeBufferPolicy.writeLimit(1920, 11724, 20000))
        assertEquals(1024, PrivateListeningNativeBufferPolicy.writeLimit(1920, 1024, 1024))
        assertEquals(3840, PrivateListeningNativeBufferPolicy.combinedTarget(3840, 1920))
        assertEquals(11724, PrivateListeningNativeBufferPolicy.combinedTarget(3840, 11724))
        assertTrue(PrivateListeningNativeBufferPolicy.combinedTarget(7680, 37400) < 38400)
    }

    @Test fun combinedTrimmingCountsNativeFramesOnlyOnceAndRetainsNewestAudio() {
        val queue = PrivateListeningAudioQueue(targetFrames = 9600)
        for (sequence in 1L..10) assertTrue(queue.offer(PrivateListeningMessage.audio(
            "01234567-89ab-4cde-8fab-0123456789ab", sequence, ByteArray(3840))))
        assertTrue(queue.primed(queue.beginPriming()))
        queue.setTargetFrames(3840)
        assertEquals(7680, queue.trimToTarget(nativeFrames = 1920))
        assertEquals(1920, queue.queuedFrames)
        assertEquals(8L, queue.droppedPackets)
        assertEquals(9L, queue.take()!!.sequence)
        assertEquals(10L, queue.take()!!.sequence)
        assertTrue(queue.consumeDiscontinuity())
    }

    @Test fun unalignedPlatformStartupFloorsKeepEnoughWholePacketsToStart() {
        val queue = PrivateListeningAudioQueue(targetFrames = 11724)
        for (sequence in 1L..15) queue.offer(PrivateListeningMessage.audio(
            "01234567-89ab-4cde-8fab-0123456789ab", sequence, ByteArray(3840)))
        queue.trimToTarget()
        assertEquals(12480, queue.queuedFrames)
        assertTrue(queue.queuedFrames >= 11724)
        assertTrue(queue.queuedFrames < 11724 + 960)
    }

    @Test fun lowDelayResamplerStartsAtItsOwnTargetAndKeepsSlewingBounded() {
        val resampler = PrivateListeningResampler()
        resampler.reset(targetFrames = 3840)
        repeat(5000) {
            resampler.correct(3840, targetFrames = 3840)
            assertEquals(1.0, resampler.ratio, 0.0)
        }
        repeat(5000) {
            val previous = resampler.ratio
            resampler.correct(7680, targetFrames = 3840)
            assertTrue(kotlin.math.abs(resampler.ratio - previous) <= 0.00000201)
            assertTrue(resampler.ratio in 0.997..1.003)
        }
        assertTrue(resampler.ratio > 1.0)
    }

    @Test fun primingReservationPreservesTheHardCeilingBeforeNativeSilenceIsWritten() {
        val queue = PrivateListeningAudioQueue()
        for (sequence in 1L..40) queue.offer(PrivateListeningMessage.audio(
            "01234567-89ab-4cde-8fab-0123456789ab", sequence, ByteArray(3840)))
        assertEquals(38400, queue.queuedFrames)
        queue.trimToMaximum(37400 + 1000)
        assertEquals(0, queue.queuedFrames)
        assertFalse(queue.offer(PrivateListeningMessage.audio(
            "01234567-89ab-4cde-8fab-0123456789ab", 41, ByteArray(3840)), nativeFrames = 38400))
        assertFalse(queue.writeGateOpen)
        queue.trimToMaximum(1920 + 1000)
        assertTrue(queue.offer(PrivateListeningMessage.audio(
            "01234567-89ab-4cde-8fab-0123456789ab", 42, ByteArray(3840)), nativeFrames = 2920))
        assertTrue(queue.queuedFrames + 2920 <= 38400)
    }

    @Test fun intentionalSilenceWhilePrimingDoesNotInflateTheTarget() {
        val policy = PrivateListeningBufferPolicy(ListeningBufferProfile.LOWER_DELAY)
        for (count in 0L..1000) policy.underruns(count, count * 20, playing = false)
        assertEquals(1920, policy.targetFrames)
        policy.underruns(1001, 20020, playing = true)
        assertEquals(3840, policy.targetFrames)
        policy.healthy(21000)
        policy.buffering()
        policy.healthy(50000)
        assertEquals(3840, policy.targetFrames)
        policy.healthy(65000)
        assertEquals(2880, policy.targetFrames)
    }

    @Test fun learnedUnderrunFloorPreventsRepeatedLatencyHuntingAndHealthyLowerModeCanReachOnePacket() {
        val stable = PrivateListeningBufferPolicy(ListeningBufferProfile.LOWER_DELAY)
        stable.healthy(0)
        stable.healthy(15000)
        assertEquals(960, stable.targetFrames)
        stable.starved(16000)
        assertEquals(2880, stable.targetFrames)
        stable.healthy(20000)
        stable.healthy(35000)
        assertEquals(1920, stable.targetFrames)
        stable.healthy(50000)
        assertEquals("Do not retry the one-packet floor after it underruns", 1920, stable.targetFrames)
    }
}
