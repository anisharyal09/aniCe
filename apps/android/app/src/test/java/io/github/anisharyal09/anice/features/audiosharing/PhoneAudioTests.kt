// SPDX-License-Identifier: GPL-3.0-or-later
// Exercises reverse-tag isolation, packet assembly and teardown policy without opening capture.
package io.github.anisharyal09.anice.features.audiosharing

import org.junit.Assert.*
import org.junit.Test

class PhoneAudioTests {
    private val id = "01234567-89ab-4cde-8fab-0123456789ab"

    @Test fun reverseTagDoesNotReachExistingListeningAndRejectsStatus() {
        val original = AudioSharingMessage.audio(id, 1, ByteArray(3840))
        val reverse = PhoneAudioMessage.from(original)
        assertNull(AudioSharingMessage.decode(reverse.encode()))
        assertNull(PhoneAudioMessage.decode(original.encode()))
        val decoded = requireNotNull(PhoneAudioMessage.decode(reverse.encode()))
        assertEquals(reverse.kind, decoded.kind)
        assertArrayEquals(reverse.encode(), decoded.encode())
        try {
            PhoneAudioMessage.from(AudioSharingMessage(5, listOf()))
            fail("Reverse v1 has no Status shape")
        } catch (_: AudioSharingWireException) {
        }
    }

    @Test fun partialNativeReadsProduceOneOwnedFixedPacketAndMonotonicSequence() {
        val packets = mutableListOf<Pair<Long, ByteArray>>()
        val packetizer = PhoneAudioPacketizer()
        val first = ByteArray(1920) { 1 }
        packetizer.accept(first, first.size) { n, pcm -> packets.add(n to pcm) }
        assertTrue(packets.isEmpty())
        packetizer.accept(ByteArray(1920) { 2 }, 1920) { n, pcm -> packets.add(n to pcm) }
        assertEquals(1L, packets.single().first)
        assertEquals(3840, packets.single().second.size)
        assertEquals(1.toByte(), packets.single().second[0])
        assertEquals(2.toByte(), packets.single().second[1920])
        first.fill(9)
        assertEquals(1.toByte(), packets.single().second[0])
        packetizer.accept(ByteArray(15360), 15360) { n, pcm -> packets.add(n to pcm) }
        assertEquals((1L..5L).toList(), packets.map { it.first })
    }

    @Test fun discardingAnIncompleteReadDoesNotReplayOrResetTheTimeline() {
        val packetizer = PhoneAudioPacketizer()
        val sequences = mutableListOf<Long>()
        packetizer.accept(ByteArray(3840), 3840) { n, _ -> sequences.add(n) }
        packetizer.accept(ByteArray(4) { 1 }, 4) { _, _ -> fail("Incomplete") }
        packetizer.discardPartial()
        val fresh = ByteArray(3840) { 2 }
        packetizer.accept(fresh, fresh.size) { n, pcm ->
            sequences.add(n)
            assertArrayEquals(fresh, pcm)
        }
        assertEquals(listOf(1L, 2L), sequences)
    }

    @Test fun stopAndReadFailuresEndNormallyInsteadOfCrashingTheWorker() {
        assertEquals(PhoneAudioReadDecision.END, PhoneAudioReadPolicy.decide(true, 3840))
        assertEquals(PhoneAudioReadDecision.END, PhoneAudioReadPolicy.decide(true, -6))
        assertEquals(PhoneAudioReadDecision.END, PhoneAudioReadPolicy.decide(true, 0))
        assertEquals(PhoneAudioReadDecision.CONTINUE, PhoneAudioReadPolicy.decide(false, 3840))
        assertEquals(PhoneAudioReadDecision.RETRY, PhoneAudioReadPolicy.decide(false, 0))
        assertEquals(PhoneAudioReadDecision.FAIL, PhoneAudioReadPolicy.decide(false, -6))
        assertEquals(PhoneAudioReadDecision.FAIL, PhoneAudioReadPolicy.decide(false, 3841))
    }
}
