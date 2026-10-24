// SPDX-License-Identifier: GPL-3.0-or-later
// Rejects stale rendezvous traffic and verifies bounded, coalesced BLE state publication.
package io.github.anisharyal09.anice.infrastructure.session

import io.github.anisharyal09.anice.infrastructure.connections.*
import io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test

class LanRendezvousTests {
    private class Channel(transport: String = "ble", instance: String = "first") : SecuredChannel {
        override val descriptor = ChannelDescriptor(instance, transport, DeviceIdentity("peer", "Mac", "macos", "key", "fingerprint"))
        val sent = mutableListOf<ByteArray>()
        var blocked = false
        var onSend: () -> Unit = {}
        override suspend fun sendData(bytes: ByteArray) {
            if (blocked) throw SessionBackpressure()
            sent.add(bytes)
            onSend()
        }
    }
    @Test fun eachExternalEventAllowsOnlyOneAttempt() {
        val gate = LanAttemptGate()
        repeat(20) {
            gate.update("ble-1", true, true, true, 0)
            assertEquals(it == 0, gate.claim())
        }
        gate.update("ble-1", true, true, true, 1)
        assertTrue(gate.claim()); assertFalse(gate.claim())
        gate.update("ble-2", true, true, true, 1)
        assertTrue(gate.claim()); assertFalse(gate.claim())
        gate.update("ble-2", false, true, false, 1)
        gate.update("ble-2", true, true, true, 1)
        assertTrue(gate.claim()); assertFalse(gate.claim())
    }
    @Test fun capacityDuringSuspendedRefusalWakesRendezvousWithoutAnotherEvent() = runBlocking {
        val scope = CoroutineScope(coroutineContext + SupervisorJob())
        try {
            val link = LanRendezvous(scope) {}
            val gate = CompletableDeferred<Unit>()
            val sent = mutableListOf<Int?>()
            var attempts = 0
            val channel = object : SecuredChannel {
                override val descriptor = Channel().descriptor
                override suspend fun sendData(bytes: ByteArray) {
                    if (++attempts == 1) { gate.await(); throw SessionBackpressure() }
                    sent.add(LanRendezvousWire.decode(bytes))
                }
            }
            link.available(channel); yield()
            link.update(1)
            link.capacityAvailable(channel.descriptor)
            gate.complete(Unit)
            repeat(4) { yield() }
            assertEquals(listOf(1), sent)
            assertEquals(2, attempts)
            link.retired(channel.descriptor)
            link.capacityAvailable(channel.descriptor); yield()
            assertEquals(2, attempts)
        } finally { scope.cancel() }
    }
    @Test fun repeatedFeatureTrafficDoesNotRearmFailedConnectionAttempts() {
        val gate = LanAttemptGate()
        gate.update("ble", true, true, true, 0)
        assertTrue(gate.claimActivity())
        gate.trigger()
        assertTrue(gate.claim())
        repeat(100) {
            gate.update("ble", true, true, true, 0)
            assertFalse(gate.claimActivity())
            assertFalse(gate.claim())
        }
        gate.trigger()
        assertTrue(gate.claim())
        gate.update("replacement", true, true, true, 0)
        assertTrue(gate.claimActivity())
    }
    @Test fun explicitRequestDoesNotChangePeerEligibilityOrEcho() = runBlocking {
        val scope = CoroutineScope(coroutineContext + SupervisorJob())
        try {
            val link = LanRendezvous(scope) {}
            val channel = Channel()
            link.available(channel); link.update(1); yield()
            link.handle(channel.descriptor, LanRendezvousWire.encode(0))
            link.handle(channel.descriptor, LanRendezvousWire.encode(4)); yield()
            assertEquals(0, link.remote); assertEquals(1L, link.requests)
            assertEquals(1, channel.sent.size)
            link.request(); yield()
            assertEquals(listOf(1, 4), channel.sent.map { LanRendezvousWire.decode(it) })
            link.retired(channel.descriptor)
            link.capacityAvailable(channel.descriptor); yield()
            assertEquals(2, channel.sent.size)
        } finally { scope.cancel() }
    }
    @Test fun independentWireBytesAndMalformedStates() {
        val prefix = byteArrayOf(0x83.toByte(), 0x69, 0x61, 0x6e, 0x69, 0x43, 0x65, 0x20, 0x4c, 0x41, 0x4e, 1)
        for (state in 0..4) {
            assertArrayEquals(prefix + state.toByte(), LanRendezvousWire.encode(state))
            assertEquals(state, LanRendezvousWire.decode(prefix + state.toByte()))
        }
        for (invalid in listOf(prefix + 5.toByte(), prefix + 0x20.toByte(), prefix.dropLast(1).toByteArray() + byteArrayOf(2, 1), prefix + byteArrayOf(1, 0))) {
            try { LanRendezvousWire.decode(invalid); fail("Malformed rendezvous accepted") }
            catch (_: IllegalArgumentException) {} catch (_: SessionException) {}
        }
        assertNull(LanRendezvousWire.decode(SessionCbor.encode(Cbor.Text("other"))))
        assertNull(LanRendezvousWire.decode(ByteArray(65)))
    }
    @Test fun bleOnlyRetirementAndStaleTraffic() = runBlocking {
        val scope = CoroutineScope(coroutineContext + SupervisorJob())
        try {
            var changes = 0
            val link = LanRendezvous(scope) { changes++ }
            val lan = Channel("lan")
            link.available(lan)
            assertNull(link.channel)
            assertEquals(DataHandling.UNRECOGNIZED, link.handle(lan.descriptor, LanRendezvousWire.encode(2)))
            val first = Channel()
            link.available(first); link.update(1); yield()
            assertEquals(1, first.sent.size)
            assertEquals(DataHandling.HANDLED, link.handle(first.descriptor, LanRendezvousWire.encode(2)))
            assertEquals(2, link.remote)
            val before = first.sent.size
            link.handle(first.descriptor, LanRendezvousWire.encode(2)); yield()
            assertEquals(before, first.sent.size)
            link.retired(first.descriptor)
            assertNull(link.remote)
            val replacement = Channel(instance = "replacement")
            link.available(replacement)
            link.retired(first.descriptor)
            assertSame(replacement, link.channel)
            assertEquals(DataHandling.UNRECOGNIZED, link.handle(first.descriptor, LanRendezvousWire.encode(2)))
            assertNull(link.remote)
            assertTrue(changes >= 4)
        } finally { scope.cancel() }
    }
    @Test fun capacityCallbackDuringSendDoesNotDuplicatePublication() = runBlocking {
        val scope = CoroutineScope(coroutineContext + SupervisorJob())
        try {
            val link = LanRendezvous(scope) {}
            val channel = Channel()
            channel.onSend = { link.capacityAvailable(channel.descriptor) }
            link.update(1); link.available(channel); yield()
            assertEquals(listOf(1), channel.sent.map { LanRendezvousWire.decode(it) })
        } finally { scope.cancel() }
    }
    @Test fun backpressureKeepsOnlyLatestState() = runBlocking {
        val scope = CoroutineScope(coroutineContext + SupervisorJob())
        try {
            val link = LanRendezvous(scope) {}
            val channel = Channel().also { it.blocked = true }
            link.available(channel); link.update(1); yield()
            link.update(2); link.update(0); yield()
            assertTrue(channel.sent.isEmpty())
            channel.blocked = false
            link.capacityAvailable(channel.descriptor); yield()
            assertEquals(listOf(0), channel.sent.map { LanRendezvousWire.decode(it) })
        } finally { scope.cancel() }
    }
}
