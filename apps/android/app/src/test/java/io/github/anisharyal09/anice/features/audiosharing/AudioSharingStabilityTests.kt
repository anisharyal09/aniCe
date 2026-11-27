// SPDX-License-Identifier: GPL-3.0-or-later
// Simulates source/output clocks and bounded delivery bursts without claiming physical Bluetooth latency.
package io.github.anisharyal09.anice.features.audiosharing

import org.junit.Assert.*
import org.junit.Test

class AudioSharingStabilityTests {
    @Test fun tenMinuteClockDriftAndDeliveryBurstsRetainABoundedCurrentAudioWindow() {
        val id = "01234567-89ab-4cde-8fab-0123456789ab"
        val pcm = ByteArray(3840)
        val scratch = ByteArray(4096)
        for (profile in ListeningBufferProfile.entries) for (drift in listOf(0.999, 1.001)) {
            val policy = AudioSharingBufferPolicy(profile)
            val queue = AudioSharingAudioQueue(targetFrames = profile.initialFrames)
            queue.primed(queue.beginPriming())
            val resampler = AudioSharingResampler()
            resampler.reset(profile.initialFrames)
            var sequence = 0L
            var output = 0.0
            var rebuffering = true
            var underruns = 0
            var lastPlayed = 0L
            for (slot in 0 until 30000) {
                val time = slot * 20L
                val before = output
                output = (output - 960 * drift).coerceAtLeast(0.0)
                if (!rebuffering && before < 960 * drift) {
                    rebuffering = true
                    underruns++
                    policy.starved(time)
                }
                // A 60-ms burst once per second models delivery jitter, not missing wire records.
                val arrived = when (slot % 50) { 0, 1 -> 0; 2 -> 3; else -> 1 }
                repeat(arrived) {
                    sequence++
                    policy.arrived(sequence, time)
                    assertTrue(queue.offer(AudioSharingMessage.audio(id, sequence, pcm), output.toInt() + 1000))
                }
                queue.setTargetFrames(policy.targetFrames)
                if (queue.queuedFrames + output > policy.targetFrames * 1.5 + 1920) {
                    queue.trimToTarget(output.toInt())
                }
                if (rebuffering && queue.queuedFrames + output >= policy.targetFrames) {
                    resampler.reset(policy.targetFrames)
                    queue.consumeDiscontinuity()
                    rebuffering = false
                }
                val limit = AudioSharingNativeBufferPolicy.requestedFrames(policy.targetFrames, profile)
                while (!rebuffering && output < limit && queue.queuedFrames > 0) {
                    val packet = requireNotNull(queue.take())
                    assertTrue(packet.sequence > lastPlayed)
                    lastPlayed = packet.sequence
                    if (queue.consumeDiscontinuity()) resampler.reset(policy.targetFrames)
                    resampler.correct(queue.queuedFrames + output.toInt() + 960, policy.targetFrames)
                    output += resampler.process(packet.pcm, scratch) / 4
                    policy.healthy(time)
                    assertTrue(resampler.ratio in 0.997..1.003)
                }
                assertTrue(queue.queuedFrames + output + resampler.bufferedFrames <= 38400)
                assertTrue(policy.targetFrames in profile.minimumFrames..profile.maximumFrames)
            }
            assertTrue("Playback must advance through the ten-minute simulation", lastPlayed > 29000)
            assertTrue("Learned jitter floor must not repeatedly hunt every burst: $profile $underruns", underruns < 100)
        }
    }
}
