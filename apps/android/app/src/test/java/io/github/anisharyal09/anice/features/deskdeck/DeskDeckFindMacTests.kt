// SPDX-License-Identifier: GPL-3.0-or-later
// Verifies Find Mac keeps its own channel, capability and request lifecycle beside Desk Deck.
package io.github.anisharyal09.anice.features.deskdeck

import io.github.anisharyal09.anice.features.finddevice.*
import io.github.anisharyal09.anice.infrastructure.connections.*
import io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class DeskDeckFindMacTests {
    private class Notifier : FindDeviceNotifying {
        val posts = mutableListOf<String>()
        val cleared = mutableListOf<String>()
        override suspend fun post(identifier: String, peerName: String): FindResult {
            posts.add(identifier)
            return FindResult.SUBMITTED
        }
        override fun clear(identifier: String) { cleared.add(identifier) }
    }
    private class Harness {
        val peer = DeviceIdentity("mac-a", "Mac", "macos", "key", "fingerprint-a")
        var time = 1_000L
        val notifier = Notifier()
        val find = FindDeviceController(notifier, Dispatchers.Unconfined, { time }, { awaitCancellation() })
        val deck = DeskDeckController(Dispatchers.Unconfined, clock = { time }, wait = { awaitCancellation() })
        val dispatch = FeatureDispatch(now = { time }).also { it.register(deck); it.register(find) }
        val bytes = mutableMapOf<String, MutableList<ByteArray>>()
        fun connect(transport: String = "lan", instance: String = "lan-a", target: DeviceIdentity = peer) {
            bytes.getOrPut(instance) { mutableListOf() }
            dispatch.available(ChannelDescriptor(instance, transport, target)) { bytes.getValue(instance).add(it) }
        }
        suspend fun findReady(transport: String = "lan", instance: String = "lan-a") {
            assertEquals(DataHandling.HANDLED, dispatch.handle(transport, instance, FindDeviceMessage(1).encode()))
        }
        fun findMessages(instance: String = "lan-a") = bytes.getValue(instance).mapNotNull(FindDeviceMessage::decode)
        fun deckMessages(instance: String = "lan-a") = bytes.getValue(instance).mapNotNull(DeskDeckMessage::decode)
        fun close() {
            deck.stop()
            dispatch.retired("lan")
            dispatch.retired("ble")
        }
    }

    @Test fun findMacWorksWithoutATelemetryCapabilityAndDeckRefreshNeverResendsIt() = runBlocking {
        val h = Harness()
        try {
            h.connect()
            h.findReady()
            h.deck.start(h.peer)
            assertFalse(h.deck.supports(h.peer))
            assertNull(h.deck.snapshot)
            assertFalse(h.deck.readingsAreFresh)
            assertFalse(h.deck.command(1))
            assertTrue(h.find.canFind(h.peer))

            h.find.find(h.peer)
            val request = h.findMessages().single { it.kind == 2L }
            assertTrue(h.find.isFinding(h.peer))
            assertTrue(h.deckMessages().isEmpty())
            h.deck.refresh()
            h.deck.stop()
            h.deck.start(h.peer)
            assertEquals(1, h.findMessages().count { it.kind == 2L })
            assertTrue(h.find.isFinding(h.peer))
            assertEquals(DataHandling.HANDLED, h.dispatch.handle("lan", "lan-a",
                FindDeviceMessage(3, request.id, request.sequence, 0).encode()))
            assertEquals("find_submitted", h.find.feedbackFor(h.peer))
            assertTrue(h.find.canFind(h.peer))
        } finally { h.close() }
    }

    @Test fun staleReadingsAndPendingDeckCommandsDoNotDisableOrShareFindFeedback() = runBlocking {
        val h = Harness()
        try {
            h.connect()
            h.deck.start(h.peer)
            h.dispatch.handle("lan", "lan-a", DeskDeckMessage(1, actions = 1).encode())
            val subscription = h.deckMessages().single { it.kind == 2L }.subscription
            val sample = DeskDeckMessage(kind = 3, subscription = subscription, sequence = 1,
                cpuPercent = 10, memoryUsed = 40, memoryTotal = 100, thermalState = 0, actions = 1)
            h.dispatch.handle("lan", "lan-a", sample.encode())
            assertTrue(h.deck.readingsAreFresh)
            assertFalse(h.find.canFind(h.peer))
            h.findReady()
            assertTrue(h.deck.command(1))
            assertTrue(h.deck.isBusy(1))
            assertTrue(h.find.canFind(h.peer))
            h.find.find(h.peer)
            val request = h.findMessages().single { it.kind == 2L }
            h.dispatch.handle("lan", "lan-a", FindDeviceMessage(3, request.id, request.sequence, 1).encode())
            assertEquals("find_blocked", h.find.feedbackFor(h.peer))
            assertEquals("Sending…", h.deck.actionFeedback(1))
            assertTrue(h.deck.isBusy(1))

            h.time += 3_001
            assertFalse(h.deck.readingsAreFresh)
            assertFalse(h.deck.command(1))
            assertTrue(h.find.canFind(h.peer))
            h.find.find(h.peer)
            assertEquals(2, h.findMessages().count { it.kind == 2L })
            val deckCommands = h.deckMessages().count { it.kind == 4L }
            h.deck.refresh()
            assertEquals(deckCommands, h.deckMessages().count { it.kind == 4L })
            assertEquals(2, h.findMessages().count { it.kind == 2L })
        } finally { h.close() }
    }

    @Test fun findUsesCompatibleBleWhenTelemetryUsesLanAndNeverMigratesPendingRequests() = runBlocking {
        val h = Harness()
        try {
            h.connect("ble", "ble-a")
            h.connect()
            h.findReady("ble", "ble-a")
            h.deck.start(h.peer)
            h.dispatch.handle("lan", "lan-a", DeskDeckMessage(1, actions = 1).encode())
            assertEquals("Local network", h.deck.activeTransportLabel())
            h.find.find(h.peer)
            val request = h.findMessages("ble-a").single { it.kind == 2L }
            assertFalse(h.findMessages().any { it.kind == 2L })
            h.findReady()
            assertEquals(DataHandling.DISCARDED, h.dispatch.handle("lan", "lan-a",
                FindDeviceMessage(3, request.id, request.sequence, 0).encode()))
            assertTrue(h.find.busy)
            h.dispatch.retired("ble")
            assertEquals("find_disconnected", h.find.feedbackFor(h.peer))
            assertFalse(h.findMessages().any { it.kind == 2L })

            h.connect("ble", "ble-b")
            h.findReady("ble", "ble-b")
            assertFalse(h.findMessages("ble-b").any { it.kind == 2L })
            assertEquals(DataHandling.DISCARDED, h.dispatch.handle("ble", "ble-a",
                FindDeviceMessage(3, request.id, request.sequence, 0).encode()))
            assertEquals("find_disconnected", h.find.feedbackFor(h.peer))
            h.find.find(h.peer)
            assertEquals(1, h.findMessages().count { it.kind == 2L })
            assertFalse(h.findMessages("ble-b").any { it.kind == 2L })
        } finally { h.close() }
    }

    @Test fun peerChangesAndLateRepliesCannotRetargetFindStatusOrRequests() = runBlocking {
        val h = Harness()
        val other = h.peer.copy(deviceId = "mac-b", fingerprint = "fingerprint-b", deviceName = "Other Mac")
        try {
            h.connect()
            h.findReady()
            h.connect("ble", "ble-b", other)
            h.findReady("ble", "ble-b")
            h.find.find(h.peer)
            val request = h.findMessages().single { it.kind == 2L }
            assertNull(h.find.feedbackFor(other))
            assertFalse(h.find.isFinding(other))
            assertFalse(h.find.canFind(other))
            assertTrue(h.find.isFinding(h.peer.copy(deviceName = "Renamed Mac")))
            assertEquals("find_waiting", h.find.feedbackFor(h.peer.copy(deviceName = "Renamed Mac")))
            assertNull(h.find.feedbackFor(h.peer.copy(fingerprint = "replacement-key")))
            h.find.find(other)
            assertFalse(h.findMessages("ble-b").any { it.kind == 2L })
            h.time += 10_000
            h.find.expire()
            assertEquals("find_timeout", h.find.feedbackFor(h.peer))
            h.find.find(other)
            assertTrue(h.find.isFinding(other))
            assertNull(h.find.feedbackFor(h.peer))
            h.dispatch.handle("lan", "lan-a", FindDeviceMessage(3, request.id, request.sequence, 0).encode())
            assertEquals("find_waiting", h.find.feedbackFor(other))
            assertTrue(h.find.isFinding(other))
        } finally { h.close() }
    }

    @Test fun findPhoneReceptionAndIdentifierBoundStopSurviveDeckClosure() = runBlocking {
        val h = Harness()
        try {
            h.connect()
            h.findReady()
            h.deck.start(h.peer)
            h.deck.stop()
            val request = FindDeviceMessage(2, UUID.randomUUID().toString(), 1)
            assertEquals(DataHandling.QUEUED, h.dispatch.handle("lan", "lan-a", request.encode()))
            val alert = requireNotNull(h.find.incomingAlert)
            assertEquals(h.peer.deviceName, alert.peerName)
            assertEquals(1, h.notifier.posts.size)
            h.find.dismiss(alert.identifier)
            assertNull(h.find.incomingAlert)
            assertEquals(listOf(alert.identifier), h.notifier.cleared)
            h.dispatch.handle("lan", "lan-a", request.encode())
            assertEquals(1, h.notifier.posts.size)
            assertNull(h.find.incomingAlert)
        } finally { h.close() }
    }
}
