// SPDX-License-Identifier: GPL-3.0-or-later
// Exercises transport replacement, obsolete acknowledgements and bounded history.
package io.github.anisharyal09.anice.features.deskdeck

import android.content.SharedPreferences
import io.github.anisharyal09.anice.infrastructure.connections.ChannelDescriptor
import io.github.anisharyal09.anice.infrastructure.connections.DataHandling
import io.github.anisharyal09.anice.infrastructure.connections.SecuredChannel
import io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class DeskDeckControllerTests {
    @Test fun blockedSubscriptionSendStillGetsOneRecoveryAttemptAndADeadline() = runBlocking {
        val peer = DeviceIdentity("mac-id", "Mac", "macos", "key", "fingerprint")
        val timeoutSignals = Channel<Unit>(Channel.UNLIMITED)
        var subscriptionCount = 0
        val channel = FakeChannel(ChannelDescriptor("lan-live", "lan", peer)) { bytes ->
            if (DeskDeckMessage.decode(bytes)?.kind == 2L && ++subscriptionCount == 1) awaitCancellation()
        }
        val owner = DeskDeckController(Dispatchers.Unconfined, clock = { 1_000L }, wait = { millis ->
            if (millis == 5_000L) timeoutSignals.receive() else awaitCancellation()
        })

        owner.available(channel)
        owner.handle(channel.descriptor, DeskDeckMessage(kind = 1, version = 1, actions = 1).encode())
        owner.start(peer)
        assertEquals(1, subscriptionCount)

        timeoutSignals.send(Unit)
        assertEquals(2, channel.messages().count { it.kind == 2L })
        assertEquals(DeskDeckConnectionState.OPENING, owner.connectionState)
        assertTrue(owner.status.contains("Reconnecting once"))

        timeoutSignals.send(Unit)
        assertEquals(DeskDeckConnectionState.FAILED, owner.connectionState)
        assertEquals(2, channel.messages().count { it.kind == 2L })
        owner.stop()
    }

    @Test fun commandDeadlineCoversARequestThatHasNotFinishedSubmitting() = runBlocking {
        val peer = DeviceIdentity("mac-id", "Mac", "macos", "key", "fingerprint")
        val timeoutSignal = CompletableDeferred<Unit>()
        val channel = FakeChannel(ChannelDescriptor("lan-live", "lan", peer)) { bytes ->
            if (DeskDeckMessage.decode(bytes)?.kind == 4L) awaitCancellation()
        }
        val owner = DeskDeckController(Dispatchers.Unconfined, clock = { 1_000L }, wait = { millis ->
            if (millis == 6_000L) timeoutSignal.await() else awaitCancellation()
        })

        owner.available(channel)
        owner.handle(channel.descriptor, DeskDeckMessage(kind = 1, actions = 1).encode())
        owner.start(peer)
        val subscription = channel.messages().single { it.kind == 2L }.subscription
        val sample = DeskDeckMessage(kind = 3, subscription = subscription, sequence = 1, cpuPercent = 5,
            memoryUsed = 50, memoryTotal = 100, thermalState = 0, actions = 1)
        owner.handle(channel.descriptor, sample.encode())
        assertTrue(owner.command(1))

        timeoutSignal.complete(Unit)
        assertFalse(owner.busy)
        assertTrue(owner.actionFeedback(1).contains("before submission was confirmed"))
        owner.stop()
    }

    @Test fun catalogChangeFetchesTheNewRevisionAndDiscardsOldPages() = runBlocking {
        val peer = DeviceIdentity("mac-id", "Mac", "macos", "key", "fingerprint")
        val channel = FakeChannel(ChannelDescriptor("lan-live", "lan", peer))
        val owner = DeskDeckController(Dispatchers.Unconfined, clock = { 1_000L }, wait = { awaitCancellation() })
        val oldRevision = "00000000-0000-0000-0000-000000000001"
        val newRevision = "00000000-0000-0000-0000-000000000002"
        val oldApp = DeskDeckShortcut("00000000-0000-0000-0000-000000000003", "Old app")
        val newApp = DeskDeckShortcut("00000000-0000-0000-0000-000000000004", "New app")

        owner.available(channel)
        owner.start(peer)
        owner.handle(channel.descriptor, DeskDeckMessage(kind = 1, version = 2, actions = 1).encode())
        val subscription = channel.messages().single { it.kind == 2L }.subscription
        assertTrue(channel.messages().any { it.kind == 8L && it.page == 0L })

        val oldPage = DeskDeckMessage(kind = 9, version = 2, subscription = subscription,
            page = 0, pageCount = 1, catalogRevision = oldRevision, shortcuts = listOf(oldApp))
        assertEquals(DataHandling.HANDLED, owner.handle(channel.descriptor, oldPage.encode()))
        assertEquals(listOf(oldApp), owner.shortcuts)

        val changed = DeskDeckMessage(kind = 10, version = 2, subscription = subscription, catalogRevision = newRevision)
        assertEquals(DataHandling.HANDLED, owner.handle(channel.descriptor, changed.encode()))
        assertTrue(channel.messages().count { it.kind == 8L && it.page == 0L } >= 2)
        assertTrue(owner.shortcuts.isEmpty())
        assertEquals(DataHandling.DISCARDED, owner.handle(channel.descriptor, oldPage.encode()))

        val newPage = oldPage.copy(catalogRevision = newRevision, shortcuts = listOf(newApp))
        assertEquals(DataHandling.HANDLED, owner.handle(channel.descriptor, newPage.encode()))
        assertEquals(listOf(newApp), owner.shortcuts)
        owner.stop()
    }

    @Test fun cachedSnapshotRestoresStaleAndTrustRemovalClearsIt() = runBlocking {
        val peer = DeviceIdentity("mac-id", "Mac", "macos", "key", "a".repeat(64))
        val preferences = MemoryPreferences()
        val channel = FakeChannel(ChannelDescriptor("lan-live", "lan", peer))
        val owner = DeskDeckController(Dispatchers.Unconfined, clock = { 1_000L }, wait = { awaitCancellation() },
            snapshotPreferences = preferences)

        owner.available(channel)
        owner.start(peer)
        owner.handle(channel.descriptor, DeskDeckMessage(kind = 1, version = 2, actions = 1).encode())
        val subscription = channel.messages().single { it.kind == 2L }.subscription
        owner.handle(channel.descriptor, sample(subscription, 1).encode())
        owner.stop()

        val restored = DeskDeckController(Dispatchers.Unconfined, clock = { 2_000L }, wait = { awaitCancellation() },
            snapshotPreferences = preferences)
        assertNotNull(restored.snapshot)
        assertEquals(DeskDeckConnectionState.STALE, restored.connectionState)
        assertFalse(restored.readingsAreFresh)
        assertFalse("A cached action must not run before a fresh sample", restored.command(1))

        restored.retainTrustedPeers(emptySet())
        assertNull(restored.snapshot)
        assertNull(preferences.getString("last_snapshot", null))
        owner.stop()
    }

    @Test fun firstSampleCancellingAnOutstandingSubscriptionSendKeepsDeckLive() = runBlocking {
        val peer = DeviceIdentity("mac-id", "Mac", "macos", "key", "fingerprint")
        val sendBlocked = CompletableDeferred<Unit>()
        val channel = FakeChannel(ChannelDescriptor("lan-live", "lan", peer)) { bytes ->
            if (DeskDeckMessage.decode(bytes)?.kind == 2L) sendBlocked.await()
        }
        val owner = DeskDeckController(Dispatchers.Unconfined, clock = { 1_000L }, wait = { awaitCancellation() })

        owner.available(channel)
        owner.start(peer)
        owner.handle(channel.descriptor, DeskDeckMessage(kind = 1, version = 2, actions = 1).encode())
        val subscription = channel.messages().single { it.kind == 2L }.subscription

        assertEquals(DataHandling.HANDLED, owner.handle(channel.descriptor, sample(subscription, 1).encode()))
        assertEquals(DeskDeckConnectionState.LIVE, owner.connectionState)
        owner.stop()
    }

    @Test fun healthyTransportStaysPinnedAndRetiredCommandsCannotAffectReplacement() = runBlocking {
        val peer = DeviceIdentity("mac-id", "Mac", "macos", "key", "fingerprint")
        val lan = FakeChannel(ChannelDescriptor("lan-old", "lan", peer))
        val ble = FakeChannel(ChannelDescriptor("ble-live", "ble", peer))
        val owner = DeskDeckController(Dispatchers.Unconfined, clock = { 1_000L }, wait = { awaitCancellation() })

        owner.available(lan)
        owner.available(ble)
        owner.start(peer)
        assertEquals(DeskDeckConnectionState.OPENING, owner.connectionState)

        owner.handle(lan.descriptor, DeskDeckMessage(kind = 1, version = 2, actions = 1).encode())
        owner.handle(ble.descriptor, DeskDeckMessage(kind = 1, version = 2, actions = 1).encode())
        assertEquals("Local network", owner.activeTransportLabel())
        assertEquals(1, lan.messages().count { it.kind == 2L })
        assertTrue("The unrelated BLE channel must not restart the active panel", ble.messages().none { it.kind == 2L })

        val lanSubscription = lan.messages().last { it.kind == 2L }.subscription
        owner.handle(lan.descriptor, sample(lanSubscription, 1).encode())
        assertTrue(owner.readingsAreFresh)
        assertTrue(owner.command(1))
        val oldCommand = lan.messages().last { it.kind == 4L }

        owner.retired(lan.descriptor)
        assertEquals("Bluetooth", owner.activeTransportLabel())
        val bleSubscription = ble.messages().last { it.kind == 2L }.subscription
        val staleResult = DeskDeckMessage(kind = 5, version = 2, subscription = oldCommand.subscription,
            commandId = oldCommand.commandId, result = 0).encode()
        assertEquals(DataHandling.DISCARDED, owner.handle(lan.descriptor, staleResult))
        owner.handle(ble.descriptor, sample(bleSubscription, 1).encode())
        assertEquals(DeskDeckConnectionState.LIVE, owner.connectionState)

        for (sequence in 2L..71L) owner.handle(ble.descriptor, sample(bleSubscription, sequence).encode())
        assertEquals(60, owner.history.size)
        owner.stop()
        assertEquals(null, owner.history.last().cpuPercent)
        assertEquals(DeskDeckConnectionState.STALE, owner.connectionState)
    }

    @Test fun versionThreeNegotiationCarriesAccurateMemoryAndCatalogRequests() = runBlocking {
        val peer = DeviceIdentity("mac-id", "Mac", "macos", "key", "fingerprint")
        val channel = FakeChannel(ChannelDescriptor("v3-live", "lan", peer))
        val owner = DeskDeckController(dispatcher = Dispatchers.Unconfined, clock = { 1000L })
        owner.available(channel)
        owner.handle(channel.descriptor, DeskDeckMessage(kind = 1, version = 3).encode())
        owner.start(peer)
        try {
            val subscription = channel.messages().last { it.kind == 2L }
            assertEquals(3L, subscription.version)
            assertEquals(3L, channel.messages().last { it.kind == 8L }.version)
            val memory = sample(subscription.subscription, 1).copy(version = 3,
                memoryApp = 120, memoryCached = 30, memoryFree = 25, memorySwap = 40)
            assertEquals(DataHandling.HANDLED, owner.handle(channel.descriptor, memory.encode()))
            assertEquals(145L, owner.snapshot!!.memoryUsed)
            assertEquals(30L, owner.snapshot!!.memoryCached)
            assertEquals(72, owner.history.last().memoryPercent)
        } finally { owner.stop() }
    }

    private fun sample(subscription: String, sequence: Long) = DeskDeckMessage(
        kind = 3,
        version = 2,
        subscription = subscription,
        sequence = sequence,
        cpuPercent = -1,
        memoryActive = 100,
        memoryWired = 20,
        memoryCompressed = 5,
        memoryTotal = 200,
        memoryUsed = 125,
        thermalState = 1,
        actions = 1,
        powerState = 0,
        powerPercent = -1,
    )

    private class FakeChannel(
        override val descriptor: ChannelDescriptor,
        private val onSend: suspend (ByteArray) -> Unit = {},
    ) : SecuredChannel {
        private val sent = mutableListOf<ByteArray>()
        override suspend fun sendData(bytes: ByteArray) {
            sent += bytes.copyOf()
            onSend(bytes)
        }
        fun messages() = sent.mapNotNull { runCatching { DeskDeckMessage.decode(it) }.getOrNull() }
    }

    private class MemoryPreferences : SharedPreferences {
        private val values = mutableMapOf<String, Any>()

        override fun getAll(): MutableMap<String, *> = values.toMutableMap()
        override fun getString(key: String, defValue: String?): String? = values[key] as? String ?: defValue
        @Suppress("UNCHECKED_CAST")
        override fun getStringSet(key: String, defValues: MutableSet<String>?): MutableSet<String>? =
            (values[key] as? Set<String>)?.toMutableSet() ?: defValues?.toMutableSet()
        override fun getInt(key: String, defValue: Int): Int = values[key] as? Int ?: defValue
        override fun getLong(key: String, defValue: Long): Long = values[key] as? Long ?: defValue
        override fun getFloat(key: String, defValue: Float): Float = values[key] as? Float ?: defValue
        override fun getBoolean(key: String, defValue: Boolean): Boolean = values[key] as? Boolean ?: defValue
        override fun contains(key: String): Boolean = values.containsKey(key)
        override fun edit(): SharedPreferences.Editor = MemoryEditor()
        override fun registerOnSharedPreferenceChangeListener(listener: SharedPreferences.OnSharedPreferenceChangeListener?) = Unit
        override fun unregisterOnSharedPreferenceChangeListener(listener: SharedPreferences.OnSharedPreferenceChangeListener?) = Unit

        private inner class MemoryEditor : SharedPreferences.Editor {
            private val changes = mutableMapOf<String, Any?>()
            private var clearFirst = false

            override fun putString(key: String, value: String?): SharedPreferences.Editor = put(key, value)
            override fun putStringSet(key: String, values: MutableSet<String>?): SharedPreferences.Editor = put(key, values?.toSet())
            override fun putInt(key: String, value: Int): SharedPreferences.Editor = put(key, value)
            override fun putLong(key: String, value: Long): SharedPreferences.Editor = put(key, value)
            override fun putFloat(key: String, value: Float): SharedPreferences.Editor = put(key, value)
            override fun putBoolean(key: String, value: Boolean): SharedPreferences.Editor = put(key, value)
            override fun remove(key: String): SharedPreferences.Editor = put(key, null)
            override fun clear(): SharedPreferences.Editor = apply { clearFirst = true }
            override fun commit(): Boolean { apply(); return true }
            override fun apply() {
                if (clearFirst) values.clear()
                changes.forEach { (key, value) -> if (value == null) values.remove(key) else values[key] = value }
            }

            private fun put(key: String, value: Any?): SharedPreferences.Editor = apply { changes[key] = value }
        }
    }
}
