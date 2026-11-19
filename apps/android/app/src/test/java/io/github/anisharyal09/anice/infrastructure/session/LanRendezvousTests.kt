// SPDX-License-Identifier: GPL-3.0-or-later
// Rejects stale rendezvous traffic and verifies bounded, coalesced BLE state publication.
package io.github.anisharyal09.anice.infrastructure.session

import io.github.anisharyal09.anice.infrastructure.connections.*
import io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity
import io.github.anisharyal09.anice.infrastructure.lan.LanAddress
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test

class LanRendezvousTests {
    @Test fun userDemandIsVersion2OnlyKeepsEligibilityAndCannotEchoOrReplay() = runBlocking {
        var now = 0L
        val scope = CoroutineScope(coroutineContext + SupervisorJob())
        try {
            val link = LanRendezvous(scope, { now }) {}
            val channel = Channel()
            link.available(channel); link.update(1); yield()
            link.handle(channel.descriptor, LanRendezvousWire.encode(LanRendezvousMessage(2, 0)))
            yield()
            var userRequests = 0
            link.transferRequested = { assertEquals(channel.descriptor, it); userRequests++ }
            link.handle(channel.descriptor, LanRendezvousWire.encode(LanRendezvousMessage(2, 5)))
            yield()
            assertEquals(0, link.remote)
            assertEquals(1, userRequests)
            assertFalse(channel.sent.any { LanRendezvousWire.decode(it) == 5 })
            channel.blocked = true
            repeat(10) { link.requestTransfer() }
            yield()
            channel.blocked = false
            link.capacityAvailable(channel.descriptor); yield()
            assertEquals(1, channel.sent.count { LanRendezvousWire.decode(it) == 5 })
            val sent = channel.sent.size
            channel.blocked = true
            link.requestTransfer(); yield()
            now = 10_000
            channel.blocked = false
            link.capacityAvailable(channel.descriptor); yield()
            assertEquals("An expired user action was retried", sent, channel.sent.size)
            channel.blocked = true
            link.requestTransfer(); yield()
            link.cancelTransferRequest()
            channel.blocked = false
            link.capacityAvailable(channel.descriptor); yield()
            assertEquals(sent, channel.sent.size)
            channel.blocked = true
            link.requestTransfer(); yield()
            link.retired(channel.descriptor)
            val replacement = Channel(instance = "replacement")
            link.available(replacement); yield()
            assertFalse(replacement.sent.any { LanRendezvousWire.decode(it) in listOf(4, 5) })
            assertEquals(DataHandling.UNRECOGNIZED, link.handle(channel.descriptor,
                LanRendezvousWire.encode(LanRendezvousMessage(2, 5))))
        } finally { scope.cancel() }
    }

    @Test fun legacyPeerGetsAnOrdinaryRequestAndSuspendedCancellationCannotRestoreUserDemand() = runBlocking {
        val scope = CoroutineScope(coroutineContext + SupervisorJob())
        try {
            val link = LanRendezvous(scope, { 0L }) {}
            val channel = Channel()
            link.available(channel); link.update(1); yield()
            link.requestTransfer(); yield()
            assertEquals(1, channel.sent.count { LanRendezvousWire.decode(it) == 4 })
            assertFalse(channel.sent.any { LanRendezvousWire.decodeMessage(it)?.state == 5 })
            link.handle(channel.descriptor, LanRendezvousWire.encode(LanRendezvousMessage(2, 1))); yield()
            val entered = CompletableDeferred<Unit>()
            val release = CompletableDeferred<Unit>()
            var attempts = 0
            val held = object : SecuredChannel {
                override val descriptor = channel.descriptor.copy(instance = "held")
                override suspend fun sendData(bytes: ByteArray) {
                    if (LanRendezvousWire.decode(bytes) == 5) {
                        attempts++
                        entered.complete(Unit); release.await(); throw SessionBackpressure()
                    }
                }
            }
            link.available(held)
            link.handle(held.descriptor, LanRendezvousWire.encode(LanRendezvousMessage(2, 1)))
            yield()
            link.requestTransfer(); yield()
            withTimeout(1000) { entered.await() }
            repeat(10) { link.requestTransfer() }
            link.cancelTransferRequest()
            release.complete(Unit); repeat(3) { yield() }
            link.capacityAvailable(held.descriptor); yield()
            assertEquals(1, attempts)
        } finally { scope.cancel() }
    }

    @Test fun peerLossSignalsOnlyCurrentNonduplicateStateTransitionsNotLegacyOrStaleTraffic() = runBlocking {
        val scope = CoroutineScope(coroutineContext + SupervisorJob())
        try {
            val link = LanRendezvous(scope) {}
            val channel = Channel()
            val transitions = mutableListOf<Pair<Int?, Int>>()
            link.remoteStateChanged = { descriptor, previous, current ->
                assertEquals(channel.descriptor, descriptor)
                transitions.add(previous to current)
            }
            link.available(channel)
            fun value(state: Int) = LanRendezvousWire.encode(LanRendezvousMessage(2, state))
            link.handle(channel.descriptor, value(3))
            repeat(10) { link.handle(channel.descriptor, value(3)) }
            link.handle(channel.descriptor, value(0))
            repeat(10) { link.handle(channel.descriptor, value(0)) }
            link.handle(channel.descriptor, LanRendezvousWire.encode(3))
            link.handle(channel.descriptor, value(4))
            link.handle(channel.descriptor.copy(instance = "retired"), value(3))
            assertEquals(listOf(null to 3, 3 to 0), transitions)
            assertEquals(0, link.remote)
        } finally { scope.cancel() }
    }

    @Test fun cancelConsumesLateReadinessAndRetriesButNewEventsRemainEnabled() {
        for (event in listOf("request", "channel", "eligibility", "app-open", "explicit")) {
            val gate = LanAttemptGate()
            gate.update("ble", true, true, false, 0)
            assertTrue(gate.claim())
            gate.cancel()
            repeat(10) {
                gate.update("ble", true, true, it % 2 == 0, 0)
                gate.release()
                assertFalse(gate.claim())
                assertFalse(gate.claimRecovery())
                assertFalse(gate.claimActivity())
            }
            when (event) {
                "request" -> gate.update("ble", true, true, true, 1)
                "channel" -> gate.update("new", true, true, true, 0)
                "eligibility" -> { gate.update("ble", false, true, false, 0); gate.update("ble", true, true, true, 0) }
                "app-open" -> gate.rearm()
                "explicit" -> gate.trigger()
            }
            assertTrue("Cancel disabled a later $event event", gate.claim())
            assertFalse(gate.claim())
        }
    }

    @Test fun directlyConnectedIPv4RejectsBroadcastAndNetworkAddressesButAllowsPointToPoint() {
        fun accepted(ip: String, prefix: Int) = LanAddress.unicastOnPrefix(java.net.InetAddress.getByName(ip), prefix)
        assertTrue(accepted("192.168.1.10", 24))
        assertFalse(accepted("192.168.1.0", 24))
        assertFalse(accepted("192.168.1.255", 24))
        assertTrue(accepted("192.168.1.0", 31))
        assertTrue(accepted("192.168.1.255", 32))
        for (ip in listOf("0.2.3.4", "127.0.0.1", "224.0.0.1", "255.255.255.255")) assertFalse(accepted(ip, 32))
    }

    @Test fun independentVersion2FixturesAndStrictEndpointBounds() {
        val rows = org.json.JSONObject(requireNotNull(javaClass.classLoader!!.getResourceAsStream("lan/automatic-vectors.json"))
            .bufferedReader().use { it.readText() })
        val valid = rows.getJSONArray("valid")
        val invalid = rows.getJSONArray("invalid")
        assertTrue(valid.length() >= 15); assertTrue(invalid.length() >= 30)
        fun wire(row: org.json.JSONObject) = row.getString("payloadHex").chunked(2).map { it.toInt(16).toByte() }.toByteArray()
        repeat(valid.length()) {
            val bytes = wire(valid.getJSONObject(it))
            assertArrayEquals(bytes, LanRendezvousWire.encode(requireNotNull(LanRendezvousWire.decodeMessage(bytes))))
        }
        repeat(invalid.length()) {
            val row = invalid.getJSONObject(it)
            if (row.getString("name") == "wrong-tag") { assertNull(LanRendezvousWire.decodeMessage(wire(row))); return@repeat }
            try { LanRendezvousWire.decodeMessage(wire(row)); fail("Invalid rendezvous accepted: ${row.getString("name")}") }
            catch (_: IllegalArgumentException) {} catch (_: SessionException) {}
        }
    }

    @Test fun version2NegotiatesOnceAndLateLegacyStateCannotReplaceTheEndpoint() = runBlocking {
        val scope = CoroutineScope(coroutineContext + SupervisorJob())
        try {
            val link = LanRendezvous(scope) {}
            val channel = Channel()
            val endpoint = LanDirectEndpoint("192.0.2.10", 51234, SessionProfile.LAN_TRANSFER_512)
            link.available(channel); link.update(1); yield()
            assertEquals(listOf(2, 1), channel.sent.map { LanRendezvousWire.decodeMessage(it)!!.version })
            link.handle(channel.descriptor, LanRendezvousWire.encode(LanRendezvousMessage(2, 2, endpoint))); yield()
            assertEquals(endpoint, link.remoteEndpoint)
            val count = channel.sent.size
            repeat(10) {
                link.handle(channel.descriptor, LanRendezvousWire.encode(LanRendezvousMessage(2, 2, endpoint)))
                link.handle(channel.descriptor, LanRendezvousWire.encode(0))
            }
            yield()
            assertEquals(2, link.remote); assertEquals(endpoint, link.remoteEndpoint)
            assertEquals(count, channel.sent.size)
            link.request(); yield()
            assertEquals(1, channel.sent.count { LanRendezvousWire.decodeMessage(it)!!.state == 4 })
            assertEquals(2, LanRendezvousWire.decodeMessage(channel.sent.last())!!.version)
            link.retired(channel.descriptor)
            assertNull(link.remoteEndpoint)
            val replacement = Channel(instance = "replacement")
            link.available(replacement)
            assertEquals(DataHandling.UNRECOGNIZED, link.handle(channel.descriptor,
                LanRendezvousWire.encode(LanRendezvousMessage(2, 2, endpoint))))
            assertNull(link.remoteEndpoint)
        } finally { scope.cancel() }
    }

    @Test fun requestWhileConnectedWaitsForRetirementAndIsConsumedOnlyOnce() {
        val gate = LanAttemptGate()
        gate.update("ble", true, true, true, 0)
        assertTrue(gate.claim())
        repeat(20) { assertFalse(gate.claim(connected = true)) }
        assertFalse("Retirement alone cannot authorize another attempt", gate.claim())
        gate.update("ble", true, true, true, 1)
        repeat(20) {
            gate.update("ble", true, true, true, 1)
            assertFalse("A healthy connection must not be replaced", gate.claim(connected = true))
        }
        assertTrue("The peer's request must survive delayed local socket retirement", gate.claim())
        assertFalse(gate.claim())
        gate.update("ble", true, true, true, 1)
        assertFalse("Duplicate state must not create a reconnect loop", gate.claim())
    }

    @Test fun lossOfBoundIPv4IsNotMaskedBySurvivingIPv6() {
        val ipv4 = java.net.InetAddress.getByName("192.0.2.10")
        val replacement = java.net.InetAddress.getByName("192.0.2.11")
        val ipv6 = java.net.InetAddress.getByName("fe80::1")
        val initial = setOf(ipv4, ipv6)
        assertFalse(LanAddress.retainsLocalAddress(ipv4, initial, setOf(ipv6)))
        assertFalse(LanAddress.retainsLocalAddress(ipv4, initial, setOf(replacement, ipv6)))
        assertTrue(LanAddress.retainsLocalAddress(ipv4, initial, setOf(ipv4)))
        assertTrue(LanAddress.retainsLocalAddress(ipv6, initial, setOf(ipv6)))
        assertFalse(LanAddress.retainsLocalAddress(ipv6, initial, setOf(ipv4)))
        assertTrue(LanAddress.retainsLocalAddress(null, initial, setOf(ipv6)))
        assertFalse(LanAddress.retainsLocalAddress(null, initial, emptySet()))
    }

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
    @Test fun automaticRecoveryIsBoundedPerEventAndRearmsOnAppOpen() {
        val gate = LanAttemptGate()
        gate.update("ble", true, true, true, 0)
        assertTrue(gate.claim())
        gate.release()
        assertTrue(gate.claimRecovery())
        gate.release()
        assertTrue(gate.claimRecovery())
        gate.release()
        assertFalse("The initial attempt plus two retries exhaust the budget", gate.claimRecovery())
        assertFalse(gate.claim())
        repeat(20) { gate.update("ble", true, true, true, 0); assertFalse(gate.claim()) }
        gate.rearm()
        assertTrue(gate.claim())
    }
    @Test fun explicitDemandKeepsOneOpportunityAfterRecoveryIsExhausted() {
        val gate = LanAttemptGate()
        gate.update("ble", true, true, true, 0)
        assertTrue(gate.claim())
        repeat(2) { gate.release(); assertTrue(gate.claimRecovery()) }
        gate.release()
        assertFalse(gate.claimRecovery())
        gate.trigger()
        assertTrue(gate.claim())
        assertFalse(gate.claim())
    }
    @Test fun newChannelOrEligibilityIntervalRearmsRecoveryButDuplicateCallbacksDoNot() {
        val gate = LanAttemptGate()
        gate.update("ble", true, true, true, 0)
        assertTrue(gate.claim())
        repeat(2) { gate.release(); assertTrue(gate.claimRecovery()) }
        gate.release()
        assertFalse(gate.claimRecovery())
        repeat(20) { gate.update("ble", true, true, true, 0); assertFalse(gate.claimRecovery()) }
        gate.update("ble", false, true, false, 0)
        gate.update("ble", true, true, true, 0)
        assertTrue(gate.claim())
        repeat(2) { gate.release(); assertTrue(gate.claimRecovery()) }
        gate.release()
        assertFalse(gate.claimRecovery())
        gate.update("replacement", true, true, true, 0)
        assertTrue(gate.claim())
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
            assertEquals(listOf(1, 1), sent)
            assertEquals(3, attempts)
            link.retired(channel.descriptor)
            link.capacityAvailable(channel.descriptor); yield()
            assertEquals(3, attempts)
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
    @Test fun activityDemandResetsOnlyForANewChannelOrEligibilityInterval() {
        val gate = LanAttemptGate()
        gate.update("ble", true, true, false, 0)
        assertTrue(gate.claimActivity())
        gate.trigger()
        assertTrue(gate.claim())
        for (requests in 0L..3L) {
            for (ready in listOf(false, true, false)) {
                gate.update("ble", true, true, ready, requests)
                assertFalse("Listener and explicit-request events cannot renew ordinary activity", gate.claimActivity())
                gate.trigger()
                assertTrue(gate.claim())
                assertFalse(gate.claim())
                assertFalse(gate.claimActivity())
            }
        }
        gate.update("ble", false, true, false, 3)
        assertFalse(gate.claimActivity())
        gate.update("ble", true, true, false, 3)
        assertTrue(gate.claimActivity()); assertFalse(gate.claimActivity())
        gate.update("ble", true, false, false, 3)
        assertFalse(gate.claimActivity())
        gate.update("ble", true, true, false, 3)
        assertTrue(gate.claimActivity()); assertFalse(gate.claimActivity())
        gate.update("replacement", true, true, false, 3)
        assertTrue(gate.claimActivity()); assertFalse(gate.claimActivity())
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
            assertEquals(2, channel.sent.size)
            link.request(); yield()
            assertEquals(listOf(1, 1, 4), channel.sent.map { LanRendezvousWire.decode(it) })
            link.retired(channel.descriptor)
            link.capacityAvailable(channel.descriptor); yield()
            assertEquals(3, channel.sent.size)
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
            assertEquals(2, first.sent.size)
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
            assertEquals(listOf(1, 1), channel.sent.map { LanRendezvousWire.decode(it) })
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
            assertEquals(listOf(0, 0), channel.sent.map { LanRendezvousWire.decode(it) })
        } finally { scope.cancel() }
    }
}
