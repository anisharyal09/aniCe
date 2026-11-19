// SPDX-License-Identifier: GPL-3.0-or-later
// Verifies shared pause bytes, credential-scoped presentation and best-effort current-channel delivery.
package io.github.anisharyal09.anice.features.connectionpause

import io.github.anisharyal09.anice.infrastructure.connections.*
import io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity
import io.github.anisharyal09.anice.infrastructure.session.*
import kotlinx.coroutines.*
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class ConnectionPauseTests {
    private class Channel(
        instance: String = "first",
        transport: String = "ble",
        peer: DeviceIdentity = DeviceIdentity("peer", "Mac", "macos", "key", "fingerprint"),
    ) : SecuredChannel {
        override val descriptor = ChannelDescriptor(instance, transport, peer)
        val sent = mutableListOf<ByteArray>()
        var blocked = false
        override suspend fun sendData(bytes: ByteArray) {
            if (blocked) throw SessionBackpressure()
            sent.add(bytes)
        }
    }

    @Test fun independentFixturesRoundTripAndRejectEveryInvalidNotice() {
        val rows = JSONObject(requireNotNull(javaClass.classLoader!!.getResourceAsStream("connection-pause/vectors.json"))
            .bufferedReader().use { it.readText() })
        val valid = rows.getJSONArray("valid")
        val invalid = rows.getJSONArray("invalid")
        val unknown = rows.getJSONArray("unrecognized")
        assertEquals(5, valid.length()); assertEquals(23, invalid.length()); assertEquals(1, unknown.length())
        fun bytes(row: JSONObject) = row.getString("payloadHex").chunked(2).map { it.toInt(16).toByte() }.toByteArray()
        repeat(valid.length()) {
            val row = valid.getJSONObject(it)
            val message = requireNotNull(ConnectionPauseMessage.decode(bytes(row)))
            assertEquals(row.getLong("kind"), message.kind)
            assertEquals(row.getLong("untilMillis"), message.until)
            assertArrayEquals(bytes(row), message.encode())
        }
        repeat(invalid.length()) {
            val row = invalid.getJSONObject(it)
            val decoded = try { ConnectionPauseMessage.decode(bytes(row)) }
                catch (_: ConnectionPauseWireException) { null }
            assertNull("Invalid notice accepted: ${row.getString("name")}", decoded)
        }
        assertNull(ConnectionPauseMessage.decode(bytes(unknown.getJSONObject(0))))
    }

    @Test fun encoderRejectsUnsupportedKindsAndUnboundedDeadlines() {
        for (message in listOf(ConnectionPauseMessage(0), ConnectionPauseMessage(3),
                ConnectionPauseMessage(1, -1), ConnectionPauseMessage(1, ConnectionPauseMessage.MAX_UNTIL_MILLIS + 1),
                ConnectionPauseMessage(2, 1))) {
            assertThrows(ConnectionPauseWireException::class.java) { message.encode() }
        }
    }

    @Test fun noticeSurvivesRetirementButFreshReadinessAndStaleCallbacksCannotRestoreIt() = runBlocking {
        val scope = CoroutineScope(coroutineContext + SupervisorJob())
        try {
            val model = ConnectionPauseController({ "time" }, { 1_800_000_000_000L }, scope)
            val first = Channel()
            model.available(first)
            assertEquals(DataHandling.HANDLED, model.handle(first.descriptor, ConnectionPauseMessage(1).encode()))
            assertEquals("Paused on Mac", model.status(first.descriptor.peer))
            assertTrue("Receiving a pause must not echo it", first.sent.isEmpty())
            model.retired(first.descriptor)
            assertEquals("Paused on Mac", model.status(first.descriptor.peer))
            val replacement = Channel(instance = "new")
            model.available(replacement)
            model.retired(first.descriptor)
            assertEquals(DataHandling.DISCARDED, model.handle(first.descriptor, ConnectionPauseMessage(1).encode()))
            assertNull(model.status(first.descriptor.peer))
            assertEquals(DataHandling.HANDLED, model.handle(replacement.descriptor, ConnectionPauseMessage(1).encode()))
        } finally { scope.cancel() }
    }

    @Test fun deadlineIsCredentialScopedAndClockCatchupNeverExtendsIt() = runBlocking {
        val scope = CoroutineScope(coroutineContext + SupervisorJob())
        try {
            var now = 1_800_000_000_000L
            val deadline = now + 60_000
            val model = ConnectionPauseController({ "deadline=$it" }, { now }, scope)
            val channel = Channel()
            model.available(channel)
            val notice = ConnectionPauseMessage(1, deadline).encode()
            repeat(5) { model.handle(channel.descriptor, notice) }
            assertEquals("Paused on Mac until deadline=$deadline", model.status(channel.descriptor.peer))
            assertNull(model.status(channel.descriptor.peer.copy(publicKey = "another key")))
            assertNull(model.status(channel.descriptor.peer.copy(deviceId = "another peer")))
            now -= 3_600_000
            model.reconcileTime()
            assertNotNull(model.status(channel.descriptor.peer))
            now = deadline
            model.reconcileTime()
            assertNull(model.status(channel.descriptor.peer))
            model.handle(channel.descriptor, notice)
            assertNull("An already expired notice must stay cleared", model.status(channel.descriptor.peer))
        } finally { scope.cancel() }
    }

    @Test fun resumeAndLocalClearDoNotEchoOrModifyOtherPeerNotices() = runBlocking {
        val scope = CoroutineScope(coroutineContext + SupervisorJob())
        try {
            val model = ConnectionPauseController({ "time" }, { 100L }, scope)
            val first = Channel()
            model.available(first)
            model.handle(first.descriptor, ConnectionPauseMessage(1).encode())
            model.retired(first.descriptor)
            val second = Channel(instance = "second", peer = first.descriptor.peer.copy(deviceId = "second", fingerprint = "second"))
            model.available(second)
            model.handle(second.descriptor, ConnectionPauseMessage(1).encode())
            model.handle(second.descriptor, ConnectionPauseMessage(2).encode())
            assertNull(model.status(second.descriptor.peer))
            assertNotNull(model.status(first.descriptor.peer))
            model.clear()
            assertNull(model.status(first.descriptor.peer))
            assertTrue(first.sent.isEmpty()); assertTrue(second.sent.isEmpty())
        } finally { scope.cancel() }
    }

    @Test fun announcementsPreferLanAndFallBackWithoutDuplicateOrRetiredReplay() = runBlocking {
        val scope = CoroutineScope(coroutineContext + SupervisorJob())
        try {
            val model = ConnectionPauseController({ "time" }, { 100L }, scope)
            val ble = Channel()
            val lan = Channel(instance = "lan", transport = "lan")
            model.available(ble); model.available(lan)
            model.announcePause(0)
            assertEquals(1, lan.sent.size); assertTrue(ble.sent.isEmpty())
            lan.blocked = true
            model.announceResume()
            assertEquals(ConnectionPauseMessage(2), ConnectionPauseMessage.decode(ble.sent.single()))
            model.retired(lan.descriptor); model.retired(ble.descriptor)
            model.capacityAvailable(ble.descriptor)
            model.announcePause(0)
            assertEquals(1, ble.sent.size); assertEquals(1, lan.sent.size)
        } finally { scope.cancel() }
    }

    @Test fun malformedAndUnrecognizedDataCannotCreateAPause() = runBlocking {
        val scope = CoroutineScope(coroutineContext + SupervisorJob())
        try {
            val model = ConnectionPauseController({ "time" }, { 100L }, scope)
            val channel = Channel()
            model.available(channel)
            val malformed = SessionCbor.encode(Cbor.Array(listOf(Cbor.Text(ConnectionPauseMessage.TAG),
                Cbor.Integer(1), Cbor.Integer(9), Cbor.Array(listOf(Cbor.Integer(0))))))
            assertEquals(DataHandling.DISCARDED, model.handle(channel.descriptor, malformed))
            assertEquals(DataHandling.UNRECOGNIZED, model.handle(channel.descriptor, SessionCbor.encode(Cbor.Text("other"))))
            assertEquals(DataHandling.UNRECOGNIZED, model.handle(channel.descriptor, ByteArray(129)))
            assertNull(model.status(channel.descriptor.peer))
        } finally { scope.cancel() }
    }

    @Test fun inMemoryNoticeRetentionIsBounded() = runBlocking {
        val scope = CoroutineScope(coroutineContext + SupervisorJob())
        try {
            val model = ConnectionPauseController({ "time" }, { 100L }, scope)
            val peers = (1..17).map { DeviceIdentity("peer-$it", "Mac $it", "macos", "key-$it", "fingerprint-$it") }
            for (peer in peers) {
                val channel = Channel(instance = peer.deviceId, peer = peer)
                model.available(channel)
                model.handle(channel.descriptor, ConnectionPauseMessage(1).encode())
                model.retired(channel.descriptor)
            }
            assertEquals(16, peers.count { model.status(it) != null })
            model.clear()
            assertTrue(peers.none { model.status(it) != null })
        } finally { scope.cancel() }
    }
}
