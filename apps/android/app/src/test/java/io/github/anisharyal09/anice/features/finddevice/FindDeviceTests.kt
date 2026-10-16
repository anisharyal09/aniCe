// SPDX-License-Identifier: GPL-3.0-or-later
// Probes Find Device replay floors, permission failures, retirement races and independent wire inventories.
package io.github.anisharyal09.anice.features.finddevice

import io.github.anisharyal09.anice.infrastructure.connections.*
import io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity
import io.github.anisharyal09.anice.infrastructure.session.*
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import org.json.JSONObject
import java.util.UUID

class FindDeviceTests {
    private class Notifier : FindDeviceNotifying {
        val posts = mutableListOf<String>()
        val cleared = mutableListOf<String>()
        var result = FindResult.SUBMITTED
        var gate: CompletableDeferred<FindResult>? = null
        override suspend fun post(identifier: String, peerName: String): FindResult { posts.add(identifier); return gate?.await() ?: result }
        override fun clear(identifier: String) { cleared.add(identifier) }
    }
    private class Channel(transport: String = "lan", instance: String = UUID.randomUUID().toString(), peer: DeviceIdentity = DeviceIdentity("peer", "Mac", "macos", "key", "fingerprint")) : SecuredChannel {
        override val descriptor = ChannelDescriptor(instance, transport, peer)
        val sent = mutableListOf<FindDeviceMessage>()
        var blocked = false
        override suspend fun sendData(bytes: ByteArray) { if (blocked) throw SessionBackpressure(); sent.add(FindDeviceMessage.decode(bytes)!!) }
    }
    private class Harness {
        var time = 0L
        val notifier = Notifier()
        val owner = FindDeviceController(notifier, Dispatchers.Unconfined, { time }, { awaitCancellation() })
        suspend fun ready(channel: Channel) { owner.available(channel); assertEquals(DataHandling.HANDLED, owner.handle(channel.descriptor, FindDeviceMessage(1).encode())) }
    }
    private fun request(sequence: Long = 1) = FindDeviceMessage(2, UUID.randomUUID().toString(), sequence)
    @Test fun independentFixturesRejectMalformedBounds() {
        val root = JSONObject(javaClass.classLoader!!.getResource("find-device/find-device-vectors.json")!!.readText())
        val good = root.getJSONArray("valid"); val bad = root.getJSONArray("invalid")
        assertTrue(good.length() >= 8); assertTrue(bad.length() >= 24)
        fun hex(s: String) = s.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
        for (i in 0 until good.length()) {
            val bytes = hex(good.getJSONObject(i).getString("bytesHex")); assertArrayEquals(bytes, FindDeviceMessage.decode(bytes)!!.encode())
        }
        for (i in 0 until bad.length()) {
            val row = bad.getJSONObject(i)
            try { FindDeviceMessage.decode(hex(row.getString("bytesHex"))); fail(row.getString("name")) }
            catch (_: FindWireException) {} catch (_: SessionException) {}
        }
        assertNull(FindDeviceMessage.decode(SessionCbor.encode(Cbor.Array(listOf(Cbor.Text("other"))))))
    }
    @Test fun explicitAndOrdinaryDismissalDuplicatesEvictionAndExpiry() = runBlocking {
        val h = Harness(); val c = Channel(); h.ready(c)
        val first = request(); h.owner.handle(c.descriptor, first.encode())
        h.owner.dismiss(h.notifier.posts.first())
        h.owner.handle(c.descriptor, first.encode()); assertEquals(1, h.notifier.posts.size)
        for (i in 2L..36L) {
            h.owner.handle(c.descriptor, request(i).encode()); h.owner.dismiss(h.notifier.posts.last())
        }
        val count = h.notifier.posts.size
        h.owner.handle(c.descriptor, first.encode()); assertEquals(count, h.notifier.posts.size)
        val last = request(37); h.owner.handle(c.descriptor, last.encode()); val id = h.notifier.posts.last()
        h.time = 59999; h.owner.expire(); assertFalse(h.notifier.cleared.contains(id))
        h.owner.handle(c.descriptor, last.encode())
        h.time = 60000; h.owner.expire(); assertTrue(h.notifier.cleared.contains(id))
        h.owner.handle(c.descriptor, last.encode()); assertEquals(count + 1, h.notifier.posts.size)
        h.owner.retired(c.descriptor)
    }
    @Test fun permissionDenialDoesNotRetryAndBusyDoesNotReplaceAlert() = runBlocking {
        val h = Harness(); val c = Channel(); h.ready(c)
        h.notifier.result = FindResult.BLOCKED
        val first = request(); h.owner.handle(c.descriptor, first.encode())
        assertEquals(FindResult.BLOCKED.ordinal.toLong(), c.sent.last().result)
        h.notifier.result = FindResult.SUBMITTED
        h.owner.handle(c.descriptor, first.encode()); assertEquals(1, h.notifier.posts.size)
        h.owner.handle(c.descriptor, request(2).encode()); val active = h.notifier.posts.last()
        h.owner.handle(c.descriptor, request(3).encode()); assertEquals(FindResult.BUSY.ordinal.toLong(), c.sent.last().result)
        h.owner.dismiss("stale-action"); assertFalse(h.notifier.cleared.contains(active))
        h.owner.retired(c.descriptor); assertTrue(h.notifier.cleared.contains(active))
    }
    @Test fun pendingDuplicateDisconnectAndLateNativeCompletionCannotRevive() = runBlocking {
        val h = Harness(); val c = Channel(); h.ready(c)
        h.notifier.gate = CompletableDeferred()
        val first = request()
        val pending = launch(Dispatchers.Unconfined) { h.owner.handle(c.descriptor, first.encode()) }
        h.owner.handle(c.descriptor, first.encode()); assertEquals(1, h.notifier.posts.size)
        val sent = c.sent.size
        h.owner.retired(c.descriptor)
        h.notifier.gate!!.complete(FindResult.SUBMITTED); pending.join()
        assertTrue(h.notifier.cleared.contains(h.notifier.posts.first())); assertEquals(sent, c.sent.size)
        val successor = Channel(peer = c.descriptor.peer); h.ready(successor)
        assertEquals(DataHandling.DISCARDED, h.owner.handle(c.descriptor, first.encode()))
        assertEquals(1, h.notifier.posts.size)
        h.owner.retired(successor.descriptor)
    }
    @Test fun lanSelectionWrongPeerWrongGenerationWrongIdTimeoutAndNoFallbackReplay() = runBlocking {
        val h = Harness(); val lan = Channel(); val ble = Channel("ble", peer = lan.descriptor.peer)
        h.ready(ble); h.ready(lan)
        h.owner.find(lan.descriptor.peer)
        val request = lan.sent.last { it.kind == 2L }; assertFalse(ble.sent.any { it.kind == 2L })
        val reply = FindDeviceMessage(3, request.id, request.sequence, 0)
        h.owner.handle(ble.descriptor, reply.encode()); assertTrue(h.owner.busy)
        h.owner.handle(lan.descriptor.copy(instance = "old"), reply.encode()); assertTrue(h.owner.busy)
        h.owner.handle(lan.descriptor.copy(peer = lan.descriptor.peer.copy(fingerprint = "other")), reply.encode()); assertTrue(h.owner.busy)
        h.owner.handle(lan.descriptor, reply.copy(id = UUID.randomUUID().toString()).encode()); assertTrue(h.owner.busy)
        h.time = 10000; h.owner.expire(); assertFalse(h.owner.busy); assertEquals("find_timeout", h.owner.feedbackKey)
        h.owner.handle(lan.descriptor, reply.encode()); assertEquals("find_timeout", h.owner.feedbackKey)
        h.owner.find(lan.descriptor.peer); h.owner.retired(lan.descriptor)
        assertFalse(h.owner.busy); assertEquals("find_disconnected", h.owner.feedbackKey)
        assertFalse(ble.sent.any { it.kind == 2L }); h.owner.retired(ble.descriptor)
    }
    @Test fun incompatibleLanCannotHideCompatibleBleOrMatchAnotherPeer() = runBlocking {
        val h = Harness(); val lan = Channel(); val ble = Channel("ble", peer = lan.descriptor.peer)
        h.ready(ble); h.owner.available(lan)
        assertFalse(h.owner.canFind(lan.descriptor.peer.copy(fingerprint = "other")))
        h.owner.find(lan.descriptor.peer)
        assertTrue(ble.sent.any { it.kind == 2L })
        assertFalse(lan.sent.any { it.kind == 2L })
        h.owner.retired(ble.descriptor); h.owner.retired(lan.descriptor)
    }
    @Test fun backpressureAndUnsentRequestDeadlineNeverReplaysOnCapacity() = runBlocking {
        val h = Harness(); val c = Channel(); h.ready(c); c.blocked = true
        h.owner.find(c.descriptor.peer); assertTrue(h.owner.busy)
        h.time = 10000; h.owner.expire(); c.blocked = false; h.owner.capacityAvailable(c.descriptor)
        assertFalse(c.sent.any { it.kind == 2L }); assertFalse(h.owner.busy)
        h.owner.retired(c.descriptor)
    }
    @Test fun unadvertisedFeatureIsUnavailableAndFailureIsNotSubmission() = runBlocking {
        val h = Harness(); val c = Channel(); h.owner.available(c)
        h.owner.find(c.descriptor.peer); assertFalse(h.owner.busy)
        h.owner.handle(c.descriptor, request().encode()); assertTrue(h.notifier.posts.isEmpty())
        h.ready(c); h.notifier.result = FindResult.FAILED
        h.owner.handle(c.descriptor, request().encode())
        assertEquals(FindResult.FAILED.ordinal.toLong(), c.sent.last().result)
        h.owner.retired(c.descriptor)
    }
    @Test fun crossTransportReplayAfterDismissalAndEvictionCannotReviveAlert() = runBlocking {
        val h = Harness(); val lan = Channel(); val ble = Channel("ble", peer = lan.descriptor.peer)
        h.ready(lan); h.ready(ble)
        val first = request(); h.owner.handle(lan.descriptor, first.encode()); h.owner.dismiss(h.notifier.posts.last())
        h.owner.handle(ble.descriptor, first.encode()); assertEquals(1, h.notifier.posts.size)
        for (i in 2L..36L) { h.owner.handle(lan.descriptor, request(i).encode()); h.owner.dismiss(h.notifier.posts.last()) }
        h.owner.retired(lan.descriptor)
        val count = h.notifier.posts.size
        h.owner.handle(ble.descriptor, first.encode()); assertEquals(count, h.notifier.posts.size)
        assertEquals(FindResult.STALE.ordinal.toLong(), ble.sent.last().result)
        h.owner.retired(ble.descriptor)
    }

    @Test fun saturatedResponseQueueAdmitsOnlyEightNotificationsAndRejectsEvictedReplay() = runBlocking {
        val h = Harness(); val c = Channel(); h.ready(c); c.blocked = true
        for (i in 1L..12L) {
            h.owner.handle(c.descriptor, request(i).encode())
            h.notifier.posts.lastOrNull()?.let { h.owner.dismiss(it) }
        }
        assertEquals(8, h.notifier.posts.size)
        c.blocked = false; h.owner.capacityAvailable(c.descriptor)
        assertEquals(8, c.sent.count { it.kind == 3L })
        h.owner.retired(c.descriptor)
    }

    @Test fun stopDuringPreparingRemovesPopupAndLateAudioCannotRestoreIt() = runBlocking {
        val h = Harness(); val c = Channel(); h.ready(c)
        h.notifier.gate = CompletableDeferred()
        val first = request()
        val pending = launch(Dispatchers.Unconfined) { h.owner.handle(c.descriptor, first.encode()) }
        val incoming = requireNotNull(h.owner.incomingAlert)
        assertEquals(c.descriptor.peer.deviceName, incoming.peerName)
        h.owner.dismiss(incoming.identifier)
        assertNull(h.owner.incomingAlert)
        h.notifier.gate!!.complete(FindResult.SUBMITTED); pending.join()
        h.owner.handle(c.descriptor, first.encode())
        assertNull(h.owner.incomingAlert); assertEquals(1, h.notifier.posts.size)
        h.notifier.gate = null
        h.owner.handle(c.descriptor, request(2).encode())
        val replacement = requireNotNull(h.owner.incomingAlert)
        h.owner.dismiss(incoming.identifier)
        assertEquals(replacement, h.owner.incomingAlert)
        h.owner.retired(c.descriptor); assertNull(h.owner.incomingAlert)
    }
    @Test fun failedAudioSubmissionClearsPopupAndReportsFailureWithoutReplay() = runBlocking {
        val h = Harness(); val c = Channel(); h.ready(c)
        h.notifier.result = FindResult.FAILED
        val request = request()
        h.owner.handle(c.descriptor, request.encode())
        assertNull(h.owner.incomingAlert)
        assertEquals(FindResult.FAILED.ordinal.toLong(), c.sent.last().result)
        h.owner.handle(c.descriptor, request.encode())
        assertEquals(1, h.notifier.posts.size)
        h.owner.retired(c.descriptor)
    }

}
