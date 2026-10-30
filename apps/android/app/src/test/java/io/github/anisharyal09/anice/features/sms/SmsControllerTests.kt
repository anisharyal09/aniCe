// SPDX-License-Identifier: GPL-3.0-or-later
// Probes capability gating, page serving, live parking, reply assembly and provider sanitization.
package io.github.anisharyal09.anice.features.sms

import io.github.anisharyal09.anice.infrastructure.connections.*
import io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity
import io.github.anisharyal09.anice.infrastructure.session.Cbor
import io.github.anisharyal09.anice.infrastructure.session.SessionCbor
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import java.security.MessageDigest
import java.util.UUID
import kotlin.coroutines.ContinuationInterceptor

class SmsControllerTests {
    @Test fun localComposeSurvivesViewReturnWithoutDuplicateSendOrLosingNewDraft() = runBlocking {
        val h = Harness(coroutineContext[ContinuationInterceptor] as CoroutineDispatcher)
        val key = "local|42"
        val confirmation = CompletableDeferred<Unit>()
        h.sender.pause = confirmation
        h.owner.saveDraft(key, "First reply")
        val operation = h.owner.send("+1555", h.owner.draft(key), draftKey = key)
        until { h.sender.bodies.size == 1 }
        assertTrue(h.owner.sendingDraft(key))
        assertSame(operation, h.owner.send("+1555", h.owner.draft(key), draftKey = key))
        h.owner.saveDraft(key, "Next reply")
        confirmation.complete(Unit)
        assertEquals(0L, operation.result().result)
        assertFalse(h.owner.sendingDraft(key))
        assertEquals(listOf("First reply"), h.sender.bodies)
        assertEquals("Next reply", h.owner.draft(key))

        h.sender.outcome = SmsSendOutcome(5, "", 0)
        assertEquals(5L, h.owner.send("+1555", h.owner.draft(key), draftKey = key).result().result)
        assertFalse(h.owner.sendingDraft(key))
        assertEquals("Next reply", h.owner.draft(key))
        h.sender.outcome = SmsSendOutcome(0, "sms:78", 55)
        h.owner.saveDraft(key, "A\u0000B")
        assertEquals(0L, h.owner.send("+1555", h.owner.draft(key), draftKey = key).result().result)
        assertEquals("A\uFFFDB", h.sender.bodies.last())
        assertEquals("", h.owner.draft(key))
        h.owner.invalidate()
    }

    @Test fun resetFencesOldComposeCompletionWithoutClearingReplacementOperation() = runBlocking {
        val h = Harness(coroutineContext[ContinuationInterceptor] as CoroutineDispatcher)
        val key = "local|42"
        val oldConfirmation = CompletableDeferred<Unit>()
        h.sender.pause = oldConfirmation
        h.owner.saveDraft(key, "Old reply")
        val old = h.owner.send("+1555", h.owner.draft(key), draftKey = key)
        until { h.sender.bodies.size == 1 }
        h.owner.invalidate()
        assertFalse(h.owner.sendingDraft(key))
        val newConfirmation = CompletableDeferred<Unit>()
        h.sender.pause = newConfirmation
        h.owner.saveDraft(key, "New reply")
        val replacement = h.owner.send("+1555", h.owner.draft(key), draftKey = key)
        until { h.sender.bodies.size == 2 }
        oldConfirmation.complete(Unit)
        old.result()
        assertTrue(h.owner.sendingDraft(key))
        assertEquals("New reply", h.owner.draft(key))
        assertNull(h.owner.threads)
        assertTrue(h.owner.conversation.isEmpty())
        newConfirmation.complete(Unit)
        replacement.result()
        assertFalse(h.owner.sendingDraft(key))
        assertEquals("", h.owner.draft(key))
        h.owner.invalidate()
    }

    @Test fun draftsStayWithTheirConversationAndIdentityResetClearsMemory() {
        val controller = SmsController(
            store = object : SmsStore {
                override suspend fun threads(limit: Int, beforeMillis: Long, beforeThreadId: String) = SmsThreadPage(emptyList(), 0)
                override suspend fun history(threadId: String, beforeMillis: Long, beforeMessageId: String, limit: Int) = SmsHistoryPage(emptyList(), 0, "", false, 0)
                override suspend fun search(query: String, beforeMillis: Long, beforeMessageId: String, limit: Int) = SmsHistoryPage(emptyList(), 0, "", false, 0)
            },
            sender = object : SmsSender {
                override suspend fun send(address: String, body: String, subscriptionId: Int, timeoutMillis: Long) = SmsSendOutcome(0, "", 0)
            },
            dispatcher = Dispatchers.Unconfined,
            permissions = { true }
        )
        controller.saveDraft("local|42", "Keep this reply")
        controller.chooseDraftSubscription("local|42", 2)
        controller.chooseDraftSubscription("local|43", 3)
        controller.saveDraft("mac-id:fingerprint|42", "Peer-scoped draft")
        controller.retainDrafts(setOf("mac-id:fingerprint"))
        assertEquals("Keep this reply", controller.draft("local|42"))
        assertEquals(2, controller.draftSubscription("local|42"))
        assertEquals(3, controller.draftSubscription("local|43"))
        assertEquals("Peer-scoped draft", controller.draft("mac-id:fingerprint|42"))
        controller.retainDrafts(emptySet())
        assertEquals("Keep this reply", controller.draft("local|42"))
        assertEquals("", controller.draft("mac-id:fingerprint|42"))
        controller.invalidate()
        assertEquals("", controller.draft("local|42"))
        assertEquals(0, controller.draftSubscription("local|42"))
        assertEquals(0, controller.draftSubscription("local|43"))
    }

    private class FakeStore : SmsStore {
        var threadsResult: SmsThreadPage? = SmsThreadPage(emptyList(), 0)
        var historyResult: SmsHistoryPage? = SmsHistoryPage(emptyList(), 0, "", false, 0)
        var throwOnThreads = false
        var threadsUnsupported = false
        var throwOnHistory = false
        var searchResult: SmsHistoryPage? = SmsHistoryPage(emptyList(), 0, "", false, 0)
        var throwOnSearch = false
        var searchUnsupported = false
        var pause: CompletableDeferred<Unit>? = null
        var searchPause: CompletableDeferred<Unit>? = null
        val historyCalls = mutableListOf<Triple<String, Pair<Long, String>, Int>>()
        val searchCalls = mutableListOf<Triple<String, Pair<Long, String>, Int>>()
        val threadCalls = mutableListOf<Triple<Int, Long, String>>()
        override suspend fun threads(limit: Int, beforeMillis: Long, beforeThreadId: String): SmsThreadPage? {
            threadCalls += Triple(limit, beforeMillis, beforeThreadId)
            if (throwOnThreads) throw SmsStoreException()
            if (threadsUnsupported) throw SmsPagingUnsupported()
            return threadsResult
        }
        override suspend fun history(threadId: String, beforeMillis: Long, beforeMessageId: String, limit: Int): SmsHistoryPage? {
            if (throwOnHistory) throw SmsStoreException()
            historyCalls += Triple(threadId, beforeMillis to beforeMessageId, limit)
            pause?.await()
            return historyResult
        }
        override suspend fun search(query: String, beforeMillis: Long, beforeMessageId: String, limit: Int): SmsHistoryPage? {
            if (throwOnSearch) throw SmsStoreException()
            if (searchUnsupported) throw SmsPagingUnsupported()
            searchCalls += Triple(query, beforeMillis to beforeMessageId, limit)
            searchPause?.await()
            return searchResult
        }
    }
    private class FakeSubscriptions : SmsSubscriptionSource {
        var listing = SmsSubscriptionListing(0, emptyList())
        var modems = 1
        override fun list() = listing
        override fun modemCount() = modems
    }
    private class FakeSender : SmsSender {
        var outcome = SmsSendOutcome(0, "sms:77", 55)
        var pause: CompletableDeferred<Unit>? = null
        val addresses = mutableListOf<String>()
        val bodies = mutableListOf<String>()
        val subscriptionIds = mutableListOf<Int>()
        override suspend fun send(address: String, body: String, subscriptionId: Int, timeoutMillis: Long): SmsSendOutcome {
            addresses += address
            bodies += body
            subscriptionIds += subscriptionId
            pause?.await()
            return outcome
        }
    }
    private class Channel(val transport: String = "lan") : SecuredChannel {
        override val descriptor = ChannelDescriptor(UUID.randomUUID().toString(), transport, DeviceIdentity("peer", "Device", "macos", "key", "fingerprint"))
        val sent = mutableListOf<SmsWireMessage>()
        var blocked = false
        var attempts = 0
        override suspend fun sendData(bytes: ByteArray) {
            attempts++
            if (blocked) throw io.github.anisharyal09.anice.infrastructure.session.SessionBackpressure()
            sent.add(SmsWireMessage.decode(bytes)!!)
        }
    }
    private class Clock {
        var time = 0L
        private val sleeps = linkedMapOf<CompletableDeferred<Unit>, Long>()
        suspend fun wait(duration: Long) {
            val wake = CompletableDeferred<Unit>()
            sleeps[wake] = time + duration
            try { wake.await() } finally { sleeps.remove(wake) }
        }
        fun hasDeadline(value: Long) = sleeps.values.contains(value)
        fun advance(duration: Long) {
            time += duration
            val due = sleeps.filterValues { it <= time }.keys.toList()
            due.forEach { sleeps.remove(it) }
            due.forEach { it.complete(Unit) }
        }
    }
    private class Harness(dispatcher: CoroutineDispatcher) {
        val clock = Clock()
        var time: Long
            get() = clock.time
            set(value) { clock.advance(value - clock.time) }
        val store = FakeStore()
        val sender = FakeSender()
        val subscriptions = FakeSubscriptions()
        val owner = SmsController(store, sender, dispatcher = dispatcher, subscriptions = subscriptions, now = { time }, wallNow = { 1_700_000_000_000 + time }, wait = clock::wait, permissions = { true })
        suspend fun announce(c: Channel) {
            owner.handle(c.descriptor, SmsWireMessage.of(1, number(24576), number(8), number(50), number(50)).encode())
        }
        /** Advances the virtual clock and lets the scheduler run, so timers and waits re-arm between steps. */
        suspend fun tick(millis: Long) {
            time += millis
            repeat(4) { yield() }
        }
    }
    private fun request() = UUID.randomUUID().toString()
    private fun digest(text: String) = MessageDigest.getInstance("SHA-256").digest(text.toByteArray(Charsets.UTF_8))
    private suspend fun until(test: () -> Boolean) { withTimeout(5000) { while (!test()) { yield(); delay(1) } } }
    private fun utf8(text: String) = text.toByteArray(Charsets.UTF_8)

    private suspend fun ready(h: Harness, vararg channels: Channel) {
        channels.forEach { h.owner.available(it) }
        channels.forEach { h.announce(it) }
        yield()
    }

    /** The panel shows its status line only when there is something to say; the permission card owns the ask. */
    @Test fun panelStatusStartsQuietAndRefreshingPermissionsNeverRepeatsTheAsk() = runBlocking {
        val h = Harness(coroutineContext[ContinuationInterceptor] as CoroutineDispatcher)
        assertEquals("", h.owner.status)
        h.owner.refreshPermissions()
        assertEquals("", h.owner.status)
    }

    @Test fun capabilityGatesLiveUntilMacAnnouncesAndAckClearsParking() = runBlocking {
        val h = Harness(coroutineContext[ContinuationInterceptor] as CoroutineDispatcher)
        val lan = Channel()
        h.owner.available(lan)
        yield()
        assertEquals(listOf(1L), lan.sent.map { it.kind })
        var finished = 0
        h.owner.submitLive(listOf(SmsLiveEvent("+15551234567", 1_700_000_000_000, "hello")), { finished++ })
        yield()
        assertTrue(lan.sent.none { it.kind == 6L })
        assertEquals(0, finished)
        h.announce(lan)
        until { lan.sent.any { it.kind == 8L } }
        val begin = lan.sent.first { it.kind == 6L }
        assertEquals("", begin.text(1))
        assertEquals("addr:+15551234567", begin.text(3))
        assertEquals("+15551234567", begin.text(4))
        assertEquals(1_700_000_000_000L, begin.number(5))
        assertEquals(0L, begin.number(6))
        assertTrue(begin.flag(7))
        assertEquals(5L, begin.number(8))
        assertEquals(1L, begin.number(9))
        until { finished == 1 }
        val stream = begin.text(0)
        val fragment = lan.sent.first { it.kind == 7L }
        assertEquals(stream, fragment.text(0))
        assertEquals(0L, fragment.number(1))
        assertEquals(5, fragment.bytes(2).size)
        assertEquals(stream, lan.sent.first { it.kind == 8L }.text(0))
        assertEquals(DataHandling.HANDLED, h.owner.handle(lan.descriptor, SmsWireMessage.of(9, text(stream), number(0)).encode()))
        assertEquals("Message relayed", h.owner.status)
        h.owner.expire()
        assertEquals(DataHandling.DISCARDED, h.owner.handle(lan.descriptor, SmsWireMessage.of(9, text(stream), number(0)).encode()))
    }

    @Test fun announcedCapsGovernServedThreadsAndHistory() = runBlocking {
        val h = Harness(coroutineContext[ContinuationInterceptor] as CoroutineDispatcher)
        val ble = Channel("ble")
        h.owner.available(ble)
        yield()
        assertEquals(listOf(1L), ble.sent.map { it.kind })
        // A Mac on Bluetooth advertises smaller caps than the 50-row default, and the phone must serve within them.
        h.owner.handle(ble.descriptor, SmsWireMessage.of(1, number(24576), number(8), number(20), number(10)).encode())
        h.owner.handle(ble.descriptor, SmsWireMessage.of(2, text(request()), number(0), text("")).encode())
        until { h.store.threadCalls.isNotEmpty() }
        assertEquals(listOf(Triple(20, 0L, "")), h.store.threadCalls)
        h.owner.handle(ble.descriptor, SmsWireMessage.of(5, text(request()), text("7"), number(0), text(""), number(50)).encode())
        until { h.store.historyCalls.isNotEmpty() }
        assertEquals(10, h.store.historyCalls.last().third)
    }

    @Test fun parkedLiveEventRetriesOnItsTimerAndStopsOnceAcknowledged() = runBlocking {
        val h = Harness(coroutineContext[ContinuationInterceptor] as CoroutineDispatcher)
        val lan = Channel()
        ready(h, lan)
        h.owner.submitLive(listOf(SmsLiveEvent("+15551234567", 1_700_000_000_000, "hello")))
        until { lan.sent.count { it.kind == 8L } == 1 }
        // The Mac is silent, so the event stays parked and is offered again inside its lifetime.
        assertEquals(1, h.owner.waitingLive)
        assertEquals(0, h.owner.relayedLive)
        until { h.clock.hasDeadline(h.time + 2_000) }
        h.tick(2_000)
        until { h.clock.hasDeadline(h.time + 5_000) }
        h.tick(5_000)
        until { lan.sent.count { it.kind == 8L } == 2 }
        assertEquals(0, h.owner.relayedLive)
        val stream = lan.sent.last { it.kind == 8L }.text(0)
        h.owner.handle(lan.descriptor, SmsWireMessage.of(9, text(stream), number(0)).encode())
        assertEquals(1, h.owner.relayedLive)
        assertEquals(0, h.owner.waitingLive)
        // An acknowledged event is never offered again.
        h.time += 60_000
        yield()
        assertEquals(2, lan.sent.count { it.kind == 8L })
    }

    @Test fun parkedLiveEventAsksAnUncapableLinkToAnnounceItselfAgain() = runBlocking {
        val h = Harness(coroutineContext[ContinuationInterceptor] as CoroutineDispatcher)
        val lan = Channel()
        h.owner.available(lan)
        yield()
        assertEquals(listOf(1L), lan.sent.map { it.kind })
        h.owner.submitLive(listOf(SmsLiveEvent("+15551234567", 1_700_000_000_000, "hello")))
        // Without the Mac's capability the event parks, and the phone re-advertises rather than waiting for
        // the next channel generation: a lost capability hello costs a retry, not the message.
        until { lan.sent.count { it.kind == 1L } == 2 }
        assertEquals("Waiting for the Mac", h.owner.status)
        assertEquals(1, h.owner.waitingLive)
        assertTrue(lan.sent.none { it.kind == 6L })
        h.announce(lan)
        until { lan.sent.any { it.kind == 8L } }
        assertEquals(1, lan.sent.count { it.kind == 6L })
    }

    @Test fun liveMessageUpsertsItsConversationInThePanelList() = runBlocking {
        val h = Harness(coroutineContext[ContinuationInterceptor] as CoroutineDispatcher)
        val lan = Channel()
        ready(h, lan)
        h.store.threadsResult = SmsThreadPage(listOf(SmsThreadRecord("12", "+15551234567", "older", 1_600_000_000_000, 0)), 0)
        h.owner.loadThreads()
        until { h.owner.threads?.size == 1 }
        h.owner.submitLive(listOf(SmsLiveEvent("+15551234567", 1_700_000_000_000, "hello")))
        // The panel list shows the new message without a provider round trip; the next load replaces the row.
        until { h.owner.threads?.first()?.snippet == "hello" }
        assertEquals(1_700_000_000_000, h.owner.threads!!.single().dateMillis)
        assertEquals(1L, h.owner.threads!!.single().unreadCount)
        h.owner.submitLive(listOf(SmsLiveEvent("+15551234567", 1_700_000_100_000, "again")))
        until { h.owner.threads?.single()?.snippet == "again" }
        assertEquals(2L, h.owner.threads!!.single().unreadCount)
        // A sender without a provider conversation yet becomes its own alphanumeric-keyed conversation.
        h.owner.submitLive(listOf(SmsLiveEvent("BANK", 1_700_000_200_000, "code 42")))
        until { h.owner.threads?.size == 2 }
        assertEquals("addr:BANK", h.owner.threads!!.first { it.address == "BANK" }.threadId)
    }

    @Test fun liveCountersReportWaitingRelayedAndFailed() = runBlocking {
        val h = Harness(coroutineContext[ContinuationInterceptor] as CoroutineDispatcher)
        val lan = Channel()
        h.owner.available(lan)
        yield()
        h.owner.submitLive(listOf(SmsLiveEvent("+15551234567", 1_700_000_000_000, "hello")))
        yield()
        // Parked: no authenticated Mac advertises the relay yet, so the panel must not claim delivery.
        assertEquals(1, h.owner.waitingLive)
        assertEquals(0, h.owner.relayedLive)
        assertEquals("Waiting for the Mac", h.owner.status)
        h.announce(lan)
        until { lan.sent.any { it.kind == 8L } }
        val stream = lan.sent.first { it.kind == 6L }.text(0)
        h.owner.handle(lan.descriptor, SmsWireMessage.of(9, text(stream), number(0)).encode())
        assertEquals(1, h.owner.relayedLive)
        assertEquals(0, h.owner.waitingLive)
        h.owner.submitLive(listOf(SmsLiveEvent("+15551234568", 1_700_000_000_001, "second")))
        yield()
        assertEquals(1, h.owner.waitingLive)
        h.time = 601_000
        h.owner.expire()
        assertEquals(1, h.owner.failedLive)
        assertEquals(0, h.owner.waitingLive)
        assertEquals("A message could not reach the Mac", h.owner.status)
    }

    @Test fun liveRetriesOnceOnAlternateTransportWithTheSameStreamAndDeduplicates() = runBlocking {
        val h = Harness(coroutineContext[ContinuationInterceptor] as CoroutineDispatcher)
        val lan = Channel()
        val ble = Channel("ble")
        ready(h, lan, ble)
        val event = SmsLiveEvent("+15551234567", 1_700_000_000_000, "hello")
        h.owner.submitLive(listOf(event))
        until { lan.sent.any { it.kind == 8L } }
        val lanBegin = lan.sent.first { it.kind == 6L }
        assertTrue(ble.sent.none { it.kind == 6L })
        h.owner.submitLive(listOf(event))
        yield()
        assertEquals(1, lan.sent.count { it.kind == 6L })
        until { h.clock.hasDeadline(h.time + 2_000) }
        h.time += 2000
        until { ble.sent.any { it.kind == 8L } }
        val bleBegin = ble.sent.first { it.kind == 6L }
        assertEquals(lanBegin.text(0), bleBegin.text(0))
        assertEquals(lanBegin.text(2), bleBegin.text(2))
        h.owner.handle(ble.descriptor, SmsWireMessage.of(9, text(bleBegin.text(0)), number(0)).encode())
        yield()
        h.time += 10_000
        yield()
        assertEquals(1, lan.sent.count { it.kind == 6L })
        assertEquals(1, ble.sent.count { it.kind == 6L })
    }

    @Test fun parkedLiveBoundedToSixteenAndExpiresAfterTenMinutes() = runBlocking {
        val h = Harness(coroutineContext[ContinuationInterceptor] as CoroutineDispatcher)
        for (index in 0 until 17) h.owner.submitLive(listOf(SmsLiveEvent("+1555", 1_000L + index, "message $index")))
        val lan = Channel()
        ready(h, lan)
        until { lan.sent.count { it.kind == 6L } == 16 }
        val ids = lan.sent.filter { it.kind == 6L }.map { it.text(2) }
        assertFalse(ids.contains(smsLiveMessageId("+1555", 1_000L, "message 0")))
        assertTrue(ids.contains(smsLiveMessageId("+1555", 1_016L, "message 16")))
        h.time += 600_001
        h.owner.expire()
        val fresh = Channel("ble")
        ready(h, fresh)
        yield()
        assertTrue(fresh.sent.none { it.kind == 6L })
    }

    @Test fun invalidOrOversizedLiveInputNeverPoisonsTheNextEvent() = runBlocking {
        val h = Harness(coroutineContext[ContinuationInterceptor] as CoroutineDispatcher)
        val lan = Channel()
        ready(h, lan)
        h.owner.submitLive(
            listOf(
                SmsLiveEvent("", 1_000, "no address"),
                SmsLiveEvent("+1555", 1_001, ""),
                SmsLiveEvent("+1555", 1_002, "x".repeat(25_000)),
            ),
        )
        yield()
        assertEquals(3, h.owner.skippedRows)
        assertTrue(lan.sent.none { it.kind == 6L })
        h.owner.submitLive(listOf(SmsLiveEvent("+1555", 1_003, "valid")))
        until { lan.sent.any { it.kind == 6L } }
    }

    @Test fun threadListServesRecordsOrActionableResults() = runBlocking {
        val h = Harness(coroutineContext[ContinuationInterceptor] as CoroutineDispatcher)
        val lan = Channel()
        ready(h, lan)
        h.store.threadsResult = SmsThreadPage(listOf(SmsThreadRecord("42", "+15551234567", "snippet", 7, 2)), 3)
        val first = request()
        assertEquals(DataHandling.HANDLED, h.owner.handle(lan.descriptor, SmsWireMessage.of(2, text(first), number(0), text("")).encode()))
        until { lan.sent.any { it.kind == 4L } }
        val record = lan.sent.first { it.kind == 3L }
        assertEquals(first, record.text(0))
        assertEquals("42", record.text(1))
        assertEquals("+15551234567", record.text(2))
        assertEquals("snippet", record.text(3))
        assertEquals(7L, record.number(4))
        assertEquals(2L, record.number(5))
        assertEquals(0L, lan.sent.first { it.kind == 4L }.number(1))
        assertEquals(3, h.owner.skippedRows)
        h.store.threadsResult = null
        h.owner.handle(lan.descriptor, SmsWireMessage.of(2, text(request()), number(0), text("")).encode())
        until { lan.sent.count { it.kind == 4L } == 2 }
        assertEquals(1L, lan.sent.filter { it.kind == 4L }.last().number(1))
        h.store.throwOnThreads = true
        h.owner.handle(lan.descriptor, SmsWireMessage.of(2, text(request()), number(0), text("")).encode())
        until { lan.sent.count { it.kind == 4L } == 3 }
        assertEquals(5L, lan.sent.filter { it.kind == 4L }.last().number(1))
    }

    @Test fun historyPagesCarryCursorTiesAndIgnoreStaleRequests() = runBlocking {
        val h = Harness(coroutineContext[ContinuationInterceptor] as CoroutineDispatcher)
        val lan = Channel()
        ready(h, lan)
        h.store.historyResult = SmsHistoryPage(
            listOf(
                SmsHistoryMessage("sms:100", "+15551234567", 1_700_000_000_000, 0, true, "hello"),
                SmsHistoryMessage("sms:99", "+15551234567", 1_700_000_000_000, 1, false, "tie"),
            ),
            1_699_999_999_000,
            "sms:99",
            true,
            2,
        )
        val first = request()
        h.owner.handle(lan.descriptor, SmsWireMessage.of(5, text(first), text("42"), number(0), text(""), number(50)).encode())
        until { lan.sent.count { it.kind == 10L } == 1 }
        assertEquals(Triple("42", 0L to "", 50), h.store.historyCalls[0])
        val done = lan.sent.first { it.kind == 10L }
        assertEquals(0L, done.number(1))
        assertEquals(1_699_999_999_000L, done.number(2))
        assertEquals("sms:99", done.text(3))
        assertEquals(2, h.owner.skippedRows)
        val begins = lan.sent.filter { it.kind == 6L }
        assertEquals(2, begins.size)
        begins.forEach { assertEquals(first, it.text(1)) }
        assertEquals("sms:100", begins[0].text(2))
        assertEquals("42", begins[0].text(3))
        assertEquals(0L, begins[0].number(6))
        assertTrue(begins[0].flag(7))
        assertEquals(2, begins.map { it.text(0) }.toSet().size)
        assertEquals("hello", lan.sent.filter { it.kind == 7L && it.text(0) == begins[0].text(0) }.joinToString("") { String(it.bytes(2)) })
        val second = request()
        h.store.pause = CompletableDeferred()
        h.owner.handle(lan.descriptor, SmsWireMessage.of(5, text(second), text("42"), number(1_699_999_999_000L), text("sms:99"), number(50)).encode())
        until { h.store.historyCalls.size == 2 }
        assertEquals(1_699_999_999_000L to "sms:99", h.store.historyCalls[1].second)
        h.owner.handle(lan.descriptor, SmsWireMessage.of(5, text(second), text("42"), number(0), text(""), number(50)).encode())
        yield()
        assertEquals(2, h.store.historyCalls.size)
        val third = request()
        h.owner.handle(lan.descriptor, SmsWireMessage.of(5, text(third), text("42"), number(0), text(""), number(50)).encode())
        until { h.store.historyCalls.size == 3 }
        h.store.pause!!.complete(Unit)
        until { lan.sent.count { it.kind == 10L } == 2 }
        assertTrue(lan.sent.filter { it.kind == 6L }.none { it.text(1) == second })
        assertEquals(third, lan.sent.filter { it.kind == 10L }.last().text(0))
    }

    @Test fun historyFailureAndDisabledResultCodes() = runBlocking {
        val h = Harness(coroutineContext[ContinuationInterceptor] as CoroutineDispatcher)
        val lan = Channel()
        ready(h, lan)
        h.store.historyResult = null
        h.owner.handle(lan.descriptor, SmsWireMessage.of(5, text(request()), text("42"), number(0), text(""), number(50)).encode())
        until { lan.sent.any { it.kind == 10L } }
        assertEquals(1L, lan.sent.first { it.kind == 10L }.number(1))
        h.store.throwOnHistory = true
        h.owner.handle(lan.descriptor, SmsWireMessage.of(5, text(request()), text("42"), number(0), text(""), number(50)).encode())
        until { lan.sent.count { it.kind == 10L } == 2 }
        assertEquals(5L, lan.sent.filter { it.kind == 10L }.last().number(1))
    }

    @Test fun simListingServesSubscriptionsAndActionableResults() = runBlocking {
        val h = Harness(coroutineContext[ContinuationInterceptor] as CoroutineDispatcher)
        val lan = Channel()
        ready(h, lan)
        h.subscriptions.listing = SmsSubscriptionListing(0, listOf(SmsSubscription(1, 0, "Personal", true), SmsSubscription(2, 1, "Work", false)))
        val first = request()
        h.owner.handle(lan.descriptor, SmsWireMessage.of(15, text(first)).encode())
        until { lan.sent.any { it.kind == 16L } }
        val done = lan.sent.first { it.kind == 16L }
        assertEquals(first, done.text(0))
        assertEquals(0L, done.number(1))
        val entries = (done.fields[2] as Cbor.Array).value
        assertEquals(2, entries.size)
        val entry = (entries[0] as Cbor.Array).value
        assertEquals(1L, (entry[0] as Cbor.Integer).value)
        assertEquals(0L, (entry[1] as Cbor.Integer).value)
        assertEquals("Personal", (entry[2] as Cbor.Text).value)
        assertTrue((entry[3] as Cbor.Bool).value)
        // Missing READ_PHONE_STATE and platform failure are distinguishable and both keep the default usable.
        h.subscriptions.listing = SmsSubscriptionListing(1, emptyList())
        h.owner.handle(lan.descriptor, SmsWireMessage.of(15, text(request())).encode())
        until { lan.sent.count { it.kind == 16L } == 2 }
        assertEquals(1L, lan.sent.filter { it.kind == 16L }.last().number(1))
        h.subscriptions.listing = SmsSubscriptionListing(5, emptyList())
        h.owner.handle(lan.descriptor, SmsWireMessage.of(15, text(request())).encode())
        until { lan.sent.count { it.kind == 16L } == 3 }
        assertEquals(5L, lan.sent.filter { it.kind == 16L }.last().number(1))
    }

    @Test fun searchStreamsHitsUnderTheRequestIdAndCancelsStalePages() = runBlocking {
        val h = Harness(coroutineContext[ContinuationInterceptor] as CoroutineDispatcher)
        val lan = Channel()
        ready(h, lan)
        h.store.searchResult = SmsHistoryPage(listOf(SmsHistoryMessage("sms:100", "+1555", 1_000, 0, true, "hello action", "42")), 0, "", false, 0)
        val first = request()
        h.owner.handle(lan.descriptor, SmsWireMessage.of(17, text(first), text("hello"), number(0), text(""), number(50)).encode())
        until { lan.sent.any { it.kind == 18L } }
        assertEquals(Triple("hello", 0L to "", 50), h.store.searchCalls[0])
        val hit = lan.sent.first { it.kind == 6L }
        assertEquals(first, hit.text(1))
        assertEquals("sms:100", hit.text(2))
        assertEquals("42", hit.text(3))
        assertEquals("hello action", lan.sent.filter { it.kind == 7L && it.text(0) == hit.text(0) }.joinToString("") { String(it.bytes(2)) })
        assertEquals(first, lan.sent.first { it.kind == 18L }.text(0))
        // A newer search cancels the parked page; the older requestId never lands a record or a terminal.
        val second = request()
        h.store.searchPause = CompletableDeferred()
        h.owner.handle(lan.descriptor, SmsWireMessage.of(17, text(second), text("action"), number(0), text(""), number(50)).encode())
        until { h.store.searchCalls.size == 2 }
        val third = request()
        h.store.searchResult = SmsHistoryPage(listOf(SmsHistoryMessage("sms:200", "+1555", 2_000, 1, false, "third", "43")), 0, "", false, 0)
        h.owner.handle(lan.descriptor, SmsWireMessage.of(17, text(third), text("third"), number(0), text(""), number(50)).encode())
        until { h.store.searchCalls.size == 3 }
        h.store.searchPause!!.complete(Unit)
        until { lan.sent.any { it.kind == 18L && it.text(0) == third } }
        assertTrue(lan.sent.filter { it.kind == 6L }.none { it.text(1) == second })
        assertTrue(lan.sent.filter { it.kind == 18L }.none { it.text(0) == second })
    }

    @Test fun searchResultCodesCoverDisabledUnsupportedFailureAndInvalidQuery() = runBlocking {
        val h = Harness(coroutineContext[ContinuationInterceptor] as CoroutineDispatcher)
        val lan = Channel()
        ready(h, lan)
        fun search(query: String) = SmsWireMessage.of(17, text(request()), text(query), number(0), text(""), number(50))
        // A one-byte query is invalid on the wire; a query that trims short is answered with result 6 and never reaches the store.
        val rawShortQuery = SessionCbor.encode(Cbor.Array(listOf(Cbor.Text("aniCe sms"), Cbor.Integer(2), Cbor.Integer(17), Cbor.Array(listOf(text(request()), text("a"), number(0), text(""), number(50))))))
        assertEquals(DataHandling.DISCARDED, h.owner.handle(lan.descriptor, rawShortQuery))
        h.store.searchResult = null
        h.owner.handle(lan.descriptor, search("hello").encode())
        until { lan.sent.count { it.kind == 18L } == 1 }
        assertEquals(1L, lan.sent.first { it.kind == 18L }.number(1))
        h.store.searchUnsupported = true
        h.owner.handle(lan.descriptor, search("hello").encode())
        until { lan.sent.count { it.kind == 18L } == 2 }
        assertEquals(4L, lan.sent.filter { it.kind == 18L }.last().number(1))
        h.store.searchUnsupported = false
        h.store.throwOnSearch = true
        h.owner.handle(lan.descriptor, search("hello").encode())
        until { lan.sent.count { it.kind == 18L } == 3 }
        assertEquals(5L, lan.sent.filter { it.kind == 18L }.last().number(1))
        h.store.throwOnSearch = false
        h.owner.handle(lan.descriptor, search(" x ").encode())
        until { lan.sent.count { it.kind == 18L } == 4 }
        assertEquals(6L, lan.sent.filter { it.kind == 18L }.last().number(1))
        assertEquals(1, h.store.searchCalls.size)
    }

    @Test fun searchEscapesLikeWildcardsAndKeepsProviderThreadIds() = runBlocking {
        val provider = FakeProvider()
        val store = store(provider, { true })
        val patterns = mutableListOf<String>()
        val hit = SmsRawMessage(100, 1_000, "+1555", "100% done", 0, true, true, 42)
        provider.smsMatches = { pattern, _, _ -> patterns += pattern; listOf(hit) }
        provider.smsMatchGroup = { pattern, millis -> patterns += pattern; if (millis == 1_000L) listOf(hit) else emptyList() }
        val page = store.search("100%", 0, "", 10)!!
        assertEquals("%100\\%%", patterns.single())
        assertEquals("sms:100", page.messages.single().messageId)
        assertEquals("42", page.messages.single().threadId)
        assertEquals(0, page.skipped)
        patterns.clear()
        val cursor = store.search("100%", 1_000, "sms:101", 10)!!
        assertEquals("sms:100", cursor.messages.single().messageId)
        assertEquals(listOf("%100\\%%", "%100\\%%"), patterns)
        provider.smsMatches = { pattern, _, _ -> patterns += pattern; emptyList() }
        store.search("a_b", 0, "", 10)
        assertEquals("%a\\_b%", patterns.last())
        assertNull(store(provider, { false }).search("100%", 0, "", 10))
    }

    @Test fun replyAssemblyVerifiesDigestAndReportsRadioVerdict() = runBlocking {
        val h = Harness(coroutineContext[ContinuationInterceptor] as CoroutineDispatcher)
        val lan = Channel()
        ready(h, lan)
        val request = request()
        val text = "reply body"
        val bytes = utf8(text)
        h.owner.handle(lan.descriptor, SmsWireMessage.of(11, text(request), text("42"), text("+15551234567"), number(bytes.size.toLong()), number(1), data(digest(text)), number(7)).encode())
        h.owner.handle(lan.descriptor, SmsWireMessage.of(12, text(request), number(0), data(bytes)).encode())
        h.owner.handle(lan.descriptor, SmsWireMessage.of(13, text(request)).encode())
        until { lan.sent.any { it.kind == 14L } }
        val result = lan.sent.first { it.kind == 14L }
        assertEquals(request, result.text(0))
        assertEquals(0L, result.number(1))
        assertEquals("sms:77", result.text(2))
        assertEquals(55L, result.number(3))
        assertEquals(listOf("+15551234567"), h.sender.addresses)
        assertEquals(listOf(text), h.sender.bodies)
        assertEquals(listOf(7), h.sender.subscriptionIds)
    }

    @Test fun replyFailuresReportFailedDisabledAndInvalidWithoutSendingWrongText() = runBlocking {
        val h = Harness(coroutineContext[ContinuationInterceptor] as CoroutineDispatcher)
        val lan = Channel()
        ready(h, lan)
        fun begin(request: String, text: String, count: Long = 1, hash: ByteArray = digest(text)) =
            SmsWireMessage.of(11, text(request), text("42"), text("+1555"), number(text.toByteArray().size.toLong()), number(count), data(hash), number(0)).encode()
        val bad = request()
        h.owner.handle(lan.descriptor, begin(bad, "one", hash = digest("other")))
        h.owner.handle(lan.descriptor, SmsWireMessage.of(12, text(bad), number(0), data(utf8("one"))).encode())
        h.owner.handle(lan.descriptor, SmsWireMessage.of(13, text(bad)).encode())
        until { lan.sent.any { it.kind == 14L && it.text(0) == bad } }
        assertEquals(6L, lan.sent.first { it.kind == 14L && it.text(0) == bad }.number(1))
        assertTrue(h.sender.bodies.isEmpty())
        val partialText = "t".repeat(3073)
        val partial = request()
        h.owner.handle(lan.descriptor, begin(partial, partialText, count = 2))
        h.owner.handle(lan.descriptor, SmsWireMessage.of(12, text(partial), number(0), data(utf8(partialText).copyOfRange(0, 3072))).encode())
        h.owner.handle(lan.descriptor, SmsWireMessage.of(13, text(partial)).encode())
        until { lan.sent.any { it.kind == 14L && it.text(0) == partial } }
        assertEquals(6L, lan.sent.first { it.kind == 14L && it.text(0) == partial }.number(1))
        val bounds = request()
        h.owner.handle(lan.descriptor, begin(bounds, "three"))
        h.owner.handle(lan.descriptor, SmsWireMessage.of(12, text(bounds), number(0), data(ByteArray(4))).encode())
        until { lan.sent.any { it.kind == 14L && it.text(0) == bounds } }
        assertEquals(6L, lan.sent.first { it.kind == 14L && it.text(0) == bounds }.number(1))
        h.sender.outcome = SmsSendOutcome(1, "", 0)
        val disabled = request()
        h.owner.handle(lan.descriptor, begin(disabled, "four"))
        h.owner.handle(lan.descriptor, SmsWireMessage.of(12, text(disabled), number(0), data(utf8("four"))).encode())
        h.owner.handle(lan.descriptor, SmsWireMessage.of(13, text(disabled)).encode())
        until { lan.sent.any { it.kind == 14L && it.text(0) == disabled } }
        assertEquals(1L, lan.sent.first { it.kind == 14L && it.text(0) == disabled }.number(1))
        h.sender.outcome = SmsSendOutcome(5, "", 0)
        val failed = request()
        h.owner.handle(lan.descriptor, begin(failed, "five"))
        h.owner.handle(lan.descriptor, SmsWireMessage.of(12, text(failed), number(0), data(utf8("five"))).encode())
        h.owner.handle(lan.descriptor, SmsWireMessage.of(13, text(failed)).encode())
        until { lan.sent.any { it.kind == 14L && it.text(0) == failed } }
        assertEquals(5L, lan.sent.first { it.kind == 14L && it.text(0) == failed }.number(1))
        h.sender.outcome = SmsSendOutcome(4, "", 0)
        val inactive = request()
        h.owner.handle(lan.descriptor, begin(inactive, "six"))
        h.owner.handle(lan.descriptor, SmsWireMessage.of(12, text(inactive), number(0), data(utf8("six"))).encode())
        h.owner.handle(lan.descriptor, SmsWireMessage.of(13, text(inactive)).encode())
        until { lan.sent.any { it.kind == 14L && it.text(0) == inactive } }
        assertEquals(4L, lan.sent.first { it.kind == 14L && it.text(0) == inactive }.number(1))
        assertTrue(lan.sent.filter { it.kind == 14L }.all { it.number(1) == 0L || it.text(2).isEmpty() })
    }

    @Test fun conflictingReplyBeginIsRejectedAndExpiryReportsFailure() = runBlocking {
        val h = Harness(coroutineContext[ContinuationInterceptor] as CoroutineDispatcher)
        val lan = Channel()
        ready(h, lan)
        val request = request()
        val bytes = utf8("text")
        val begin = SmsWireMessage.of(11, text(request), text("42"), text("+1555"), number(bytes.size.toLong()), number(1), data(digest("text")), number(0))
        h.owner.handle(lan.descriptor, begin.encode())
        h.owner.handle(lan.descriptor, SmsWireMessage.of(11, text(request), text("42"), text("+1555"), number(99), number(1), data(digest("text")), number(0)).encode())
        until { lan.sent.any { it.kind == 14L } }
        assertEquals(6L, lan.sent.first { it.kind == 14L }.number(1))
        val timeout = request()
        h.owner.handle(lan.descriptor, SmsWireMessage.of(11, text(timeout), text("42"), text("+1555"), number(bytes.size.toLong()), number(1), data(digest("text")), number(0)).encode())
        h.time += 30_001
        h.owner.expire()
        until { lan.sent.any { it.kind == 14L && it.text(0) == timeout } }
        assertEquals(5L, lan.sent.first { it.kind == 14L && it.text(0) == timeout }.number(1))
    }

    @Test fun anotherReplyIsBusyAndDuplicateCommitNeverResends() = runBlocking {
        val h = Harness(coroutineContext[ContinuationInterceptor] as CoroutineDispatcher)
        val lan = Channel()
        ready(h, lan)
        fun begin(request: String, text: String) =
            SmsWireMessage.of(11, text(request), text("42"), text("+1555"), number(text.toByteArray().size.toLong()), number(1), data(digest(text)), number(0))
        // The first radio call parks; a replacement request arrives before it returns.
        val first = request()
        h.sender.pause = CompletableDeferred()
        h.owner.handle(lan.descriptor, begin(first, "first").encode())
        h.owner.handle(lan.descriptor, SmsWireMessage.of(12, text(first), number(0), data(utf8("first"))).encode())
        h.owner.handle(lan.descriptor, SmsWireMessage.of(13, text(first)).encode())
        until { h.sender.bodies == listOf("first") }
        val second = request()
        h.owner.handle(lan.descriptor, begin(second, "second").encode())
        h.owner.handle(lan.descriptor, SmsWireMessage.of(12, text(second), number(0), data(utf8("second"))).encode())
        h.owner.handle(lan.descriptor, SmsWireMessage.of(13, text(second)).encode())
        until { lan.sent.any { it.kind == 14L && it.text(0) == second } }
        assertEquals(2L, lan.sent.first { it.kind == 14L && it.text(0) == second }.number(1))
        assertEquals(listOf("first"), h.sender.bodies)
        h.sender.pause!!.complete(Unit)
        until { lan.sent.any { it.kind == 14L && it.text(0) == first } }
        h.owner.handle(lan.descriptor, SmsWireMessage.of(13, text(first)).encode())
        until { lan.sent.count { it.kind == 14L && it.text(0) == first } == 2 }
        assertEquals(listOf("first"), h.sender.bodies)
        assertTrue(lan.sent.filter { it.kind == 14L && it.text(0) == first }.all { it.number(1) == 0L })
    }

    @Test fun expiryCancelsAnInFlightReplyAndReportsFailureOnce() = runBlocking {
        val h = Harness(coroutineContext[ContinuationInterceptor] as CoroutineDispatcher)
        val lan = Channel()
        ready(h, lan)
        val request = request()
        h.sender.pause = CompletableDeferred()
        h.owner.handle(lan.descriptor, SmsWireMessage.of(11, text(request), text("42"), text("+1555"), number(4), number(1), data(digest("late")), number(0)).encode())
        h.owner.handle(lan.descriptor, SmsWireMessage.of(12, text(request), number(0), data(utf8("late"))).encode())
        h.owner.handle(lan.descriptor, SmsWireMessage.of(13, text(request)).encode())
        until { h.sender.bodies == listOf("late") }
        h.time += 30_001
        h.owner.expire()
        h.sender.pause!!.complete(Unit)
        until { lan.sent.any { it.kind == 14L && it.text(0) == request } }
        yield()
        val results = lan.sent.filter { it.kind == 14L && it.text(0) == request }
        assertEquals(1, results.size)
        assertEquals(5L, results.single().number(1))
    }

    @Test fun invalidAndForeignInputNeverMutatesState() = runBlocking {
        val h = Harness(coroutineContext[ContinuationInterceptor] as CoroutineDispatcher)
        val lan = Channel()
        h.owner.available(lan)
        assertEquals(DataHandling.DISCARDED, h.owner.handle(lan.descriptor, byteArrayOf(0x9f.toByte())))
        assertEquals(DataHandling.UNRECOGNIZED, h.owner.handle(lan.descriptor, SessionCbor.encode(Cbor.Array(listOf(Cbor.Text("aniCe other"), Cbor.Integer(1))))))
        assertEquals(DataHandling.UNRECOGNIZED, h.owner.handle(lan.descriptor, SmsWireMessage.of(3, text(request()), text("42"), text("+1"), text(""), number(0), number(0)).encode()))
        assertEquals(DataHandling.DISCARDED, h.owner.handle(lan.descriptor, SmsWireMessage.of(2, text(request()), number(0), text("")).encode()))
        assertEquals(DataHandling.DISCARDED, h.owner.handle(lan.descriptor, SmsWireMessage.of(9, text(UUID.randomUUID().toString()), number(0)).encode()))
        h.announce(lan)
        assertEquals(DataHandling.DISCARDED, h.owner.handle(lan.descriptor, SmsWireMessage.of(12, text(request()), number(0), data(utf8("x"))).encode()))
        assertEquals(DataHandling.DISCARDED, h.owner.handle(lan.descriptor, SmsWireMessage.of(13, text(request())).encode()))
        assertNull(h.owner.selectedThreadId)
        assertTrue(h.store.historyCalls.isEmpty())
        assertEquals(0, h.sender.bodies.size)
        assertTrue(h.owner.conversation.isEmpty())
    }

    @Test fun liveCopiesAndSentEchoesMergeBehindProviderRows() = runBlocking {
        val h = Harness(coroutineContext[ContinuationInterceptor] as CoroutineDispatcher)
        val lan = Channel()
        ready(h, lan)
        h.owner.submitLive(listOf(SmsLiveEvent("+1 (555) 123-4567", 1_700_000_000_000, "shared body")))
        until { lan.sent.any { it.kind == 6L } }
        assertEquals(1, h.owner.conversation.size)
        h.sender.outcome = SmsSendOutcome(0, "sms:77", 1_700_000_003_000)
        h.owner.send("+15551234567", "echo body")
        until { h.owner.conversation.size == 2 }
        assertTrue(h.owner.conversation.any { it.messageId.startsWith("live:") })
        assertTrue(h.owner.conversation.any { it.messageId == "sms:77" })
        h.store.historyResult = SmsHistoryPage(
            listOf(
                SmsHistoryMessage("sms:200", "+15551234567", 1_700_000_000_500, 0, false, "shared body"),
                SmsHistoryMessage("sms:201", "+15551234567", 1_700_000_003_500, 1, false, "echo body"),
            ),
            0,
            "",
            false,
            0,
        )
        h.owner.select("42")
        until { h.owner.conversation.any { it.messageId == "sms:200" } }
        assertEquals(2, h.owner.conversation.size)
        assertTrue(h.owner.conversation.none { it.messageId.startsWith("live:") || it.messageId == "sms:77" })
        assertEquals(listOf("sms:201", "sms:200"), h.owner.conversation.map { it.messageId })
    }

    @Test fun laterReceivedReplyStaysAboveSendDespiteCarrierClockSkewAndRefresh() = runBlocking {
        val h = Harness(coroutineContext[ContinuationInterceptor] as CoroutineDispatcher)
        val lan = Channel()
        ready(h, lan)
        h.store.threadsResult = SmsThreadPage(listOf(SmsThreadRecord("42", "+15551234567", "old", 1_699_000_000_000, 0)), 0)
        h.owner.loadThreads()
        until { h.owner.threads?.size == 1 }
        h.owner.select("42")
        until { !h.owner.loading }
        h.sender.pause = CompletableDeferred()
        h.sender.outcome = SmsSendOutcome(0, "sms:77", 1_700_000_003_428)
        h.owner.send("+15551234567", "hi")
        until { h.sender.bodies.size == 1 }
        h.time += 1000
        // The reply arrives later, but its carrier timestamp is ten seconds behind the phone.
        h.owner.submitLive(listOf(SmsLiveEvent("+15551234567", 1_699_999_990_000, "hlo")))
        h.sender.pause!!.complete(Unit)
        until { h.owner.conversation.size == 2 }
        assertEquals(listOf("hlo", "hi"), h.owner.conversation.map { it.text })
        h.store.historyResult = SmsHistoryPage(listOf(
            SmsHistoryMessage("sms:78", "+15551234567", 1_699_999_990_000, 0, true, "hlo"),
            SmsHistoryMessage("sms:77", "+15551234567", 1_700_000_003_428, 1, false, "hi"),
            SmsHistoryMessage("sms:76", "+15551234567", 1_699_999_980_000, 0, false, "older"),
        ), 0, "", false, 0)
        h.owner.loadConversation()
        until { h.owner.conversation.size == 3 }
        assertEquals(listOf("hlo", "hi", "older"), h.owner.conversation.map { it.text })
        assertEquals(listOf("sms:78", "sms:77", "sms:76"), h.owner.conversation.map { it.messageId })
        h.owner.invalidate()
    }

    @Test fun sameSecondRepliesSortAboveTheSendEchoByArrivalOrder() = runBlocking {
        val h = Harness(coroutineContext[ContinuationInterceptor] as CoroutineDispatcher)
        val lan = Channel()
        ready(h, lan)
        // The phone answers without a readable provider row, so the echo is stamped at its queue second.
        h.sender.outcome = SmsSendOutcome(0, "", 1_700_000_000_750)
        h.owner.send("+15551234567", "hi")
        until { h.owner.conversation.size == 1 }
        val echo = h.owner.conversation.single()
        assertEquals(1_700_000_000_000, echo.dateMillis)
        assertTrue(echo.pending)
        // The answer carries the same whole second: arrival order decides, never the synthetic echo ID.
        h.owner.submitLive(listOf(SmsLiveEvent("+15551234567", 1_700_000_000_000, "hi2")))
        until { h.owner.conversation.size == 2 }
        assertEquals(listOf("hi2", "hi"), h.owner.conversation.map { it.text })
        assertEquals(listOf(false, true), h.owner.conversation.map { it.pending })
    }

    @Test fun aProviderEchoWithMillisecondsStillSortsBelowASameSecondReply() = runBlocking {
        val h = Harness(coroutineContext[ContinuationInterceptor] as CoroutineDispatcher)
        val lan = Channel()
        ready(h, lan)
        // The phone found its provider row: the echo carries a millisecond provider date in the same second.
        h.sender.outcome = SmsSendOutcome(0, "sms:77", 1_700_000_000_428)
        h.owner.send("+15551234567", "hi")
        until { h.owner.conversation.size == 1 }
        // The answer carries a whole-second PDU stamp from that same second.
        h.owner.submitLive(listOf(SmsLiveEvent("+15551234567", 1_700_000_000_000, "hi2")))
        until { h.owner.conversation.size == 2 }
        assertEquals(listOf("hi2", "hi"), h.owner.conversation.map { it.text })
        assertEquals(listOf(0L, 1L), h.owner.conversation.map { it.direction })
    }

    @Test fun aMessageThatLandedBeforeTheSendKeepsItsPlaceOnASecondTie() = runBlocking {
        val h = Harness(coroutineContext[ContinuationInterceptor] as CoroutineDispatcher)
        val lan = Channel()
        ready(h, lan)
        h.owner.submitLive(listOf(SmsLiveEvent("+15551234567", 1_700_000_000_000, "earlier")))
        until { h.owner.conversation.size == 1 }
        h.sender.outcome = SmsSendOutcome(0, "", 1_700_000_000_750)
        h.owner.send("+15551234567", "later")
        until { h.owner.conversation.size == 2 }
        // Arrival, not direction: a send that followed the message sits above it on the same second.
        assertEquals(listOf("later", "earlier"), h.owner.conversation.map { it.text })
    }

    @Test fun switchingConversationsMidLoadKeepsRowsAndCursorOfTheSelectedThread() = runBlocking {
        val h = Harness(coroutineContext[ContinuationInterceptor] as CoroutineDispatcher)
        val lan = Channel()
        ready(h, lan)
        h.store.pause = CompletableDeferred()
        h.owner.select("42")
        until { h.store.historyCalls.size == 1 }
        h.owner.select("43")
        until { h.store.historyCalls.size == 2 }
        h.store.historyResult = SmsHistoryPage(listOf(SmsHistoryMessage("sms:300", "+15550000043", 1_700_000_000_000, 0, false, "second thread")), 0, "", false, 0)
        h.store.pause!!.complete(Unit)
        until { h.owner.conversation.any { it.messageId == "sms:300" } }
        // The abandoned first load never appends its rows, replaces the cursor or clears the loading state.
        assertEquals(listOf("42", "43"), h.store.historyCalls.map { it.first })
        assertEquals(listOf("sms:300"), h.owner.conversation.map { it.messageId })
        assertFalse(h.owner.conversationMore)
        assertFalse(h.owner.loading)
    }

    @Test fun pendingSendEchoLeavesTheConversationWhenItsLifetimeEnds() = runBlocking {
        val h = Harness(coroutineContext[ContinuationInterceptor] as CoroutineDispatcher)
        val lan = Channel()
        ready(h, lan)
        // A success without a readable provider id renders as a pending echo until its lifetime ends.
        h.sender.outcome = SmsSendOutcome(0, "", 1_700_000_000_000)
        h.owner.send("+15551234567", "typed here")
        until { h.owner.conversation.size == 1 }
        assertTrue(h.owner.conversation.single().pending)
        h.time += 600_001
        h.owner.expire()
        assertTrue(h.owner.conversation.isEmpty())
    }

    @Test fun aSendWithoutAProviderIdResolvesThroughOneDelayedRecheck() = runBlocking {
        val h = Harness(coroutineContext[ContinuationInterceptor] as CoroutineDispatcher)
        val lan = Channel()
        ready(h, lan)
        h.store.threadsResult = SmsThreadPage(listOf(SmsThreadRecord("42", "+15551234567", "hi", 1_699_000_000_000, 0)), 0)
        h.owner.loadThreads()
        until { h.owner.threads?.size == 1 }
        h.store.historyResult = SmsHistoryPage(emptyList(), 0, "", false, 0)
        h.owner.select("42")
        until { h.owner.selectedThreadId == "42" }
        // The sentIntent resolves before the provider row exists, so the echo is pending.
        h.sender.outcome = SmsSendOutcome(0, "", 1_700_000_000_000)
        h.owner.send("+15551234567", "typed here")
        until { h.owner.conversation.any { it.pending } }
        // The row lands a moment later; the delayed re-read replaces the echo instead of leaving it pending.
        h.store.historyResult = SmsHistoryPage(listOf(SmsHistoryMessage("sms:900", "+15551234567", 1_700_000_000_000, 1, false, "typed here")), 0, "", false, 0)
        h.tick(2_001)
        until { h.owner.conversation.any { it.messageId == "sms:900" } }
        assertTrue(h.owner.conversation.none { it.pending })
    }

    @Test fun sentAndLiveExtrasRenderOnlyInsideTheirOwnOpenThread() = runBlocking {
        val h = Harness(coroutineContext[ContinuationInterceptor] as CoroutineDispatcher)
        val lan = Channel()
        ready(h, lan)
        h.store.threadsResult = SmsThreadPage(
            listOf(
                SmsThreadRecord("42", "+15551234567", "hi", 1_700_000_000_000, 0),
                SmsThreadRecord("43", "ACME BANK", "alert", 1_700_000_000_500, 0),
            ),
            0,
        )
        h.owner.loadThreads()
        until { h.owner.threads?.size == 2 }
        h.store.historyResult = SmsHistoryPage(listOf(SmsHistoryMessage("sms:200", "+15551234567", 1_700_000_000_000, 0, false, "hi")), 0, "", false, 0)
        h.owner.select("42")
        until { h.owner.conversation.any { it.messageId == "sms:200" } }
        // A live message from another sender is relayed but never renders in the open thread.
        h.owner.submitLive(listOf(SmsLiveEvent("ACME BANK", 1_700_000_002_000, "Your OTP is 42")))
        until { lan.sent.any { it.kind == 6L } }
        yield()
        assertEquals(listOf("sms:200"), h.owner.conversation.map { it.messageId })
        // Its own thread renders it once selected, and only there.
        h.store.historyResult = SmsHistoryPage(emptyList(), 0, "", false, 0)
        h.owner.select("43")
        until { h.owner.conversation.any { it.messageId.startsWith("live:") } }
        assertEquals(1, h.owner.conversation.size)
        assertTrue(h.owner.conversation.single().unread)
    }

    @Test fun sentMessagesMoveTheirConversationUpWithTheNewSnippetWithoutUnread() = runBlocking {
        val h = Harness(coroutineContext[ContinuationInterceptor] as CoroutineDispatcher)
        val lan = Channel()
        ready(h, lan)
        h.store.threadsResult = SmsThreadPage(
            listOf(
                SmsThreadRecord("42", "+15551234567", "hi", 1_700_000_000_000, 2),
                SmsThreadRecord("43", "ACME BANK", "alert", 1_700_000_001_000, 0),
            ),
            0,
        )
        h.owner.loadThreads()
        until { h.owner.threads?.size == 2 }
        // A panel send moves its conversation to the top with the new snippet and leaves unread counts alone.
        h.sender.outcome = SmsSendOutcome(0, "sms:300", 1_700_000_002_000)
        h.owner.send("+15551234567", "typed here")
        until { h.owner.threads?.firstOrNull()?.snippet == "typed here" }
        assertEquals("42", h.owner.threads?.first()?.threadId)
        assertEquals("typed here", h.owner.threads?.first()?.snippet)
        assertEquals(2L, h.owner.threads?.first()?.unreadCount)
        // A reply that arrives from the Mac does the same with its own text and date.
        val request = request()
        val text = "from the mac"
        val bytes = utf8(text)
        h.sender.outcome = SmsSendOutcome(0, "sms:301", 1_700_000_003_000)
        h.owner.handle(lan.descriptor, SmsWireMessage.of(11, text(request), text("43"), text("ACME BANK"), number(bytes.size.toLong()), number(1), data(digest(text)), number(0)).encode())
        h.owner.handle(lan.descriptor, SmsWireMessage.of(12, text(request), number(0), data(bytes)).encode())
        h.owner.handle(lan.descriptor, SmsWireMessage.of(13, text(request)).encode())
        until { h.owner.threads?.firstOrNull()?.snippet == "from the mac" }
        assertEquals("43", h.owner.threads?.first()?.threadId)
        assertEquals(0L, h.owner.threads?.first()?.unreadCount)
    }

    private class FakeProvider : SmsProvider {
        var conversations: (() -> List<SmsConversationRow>)? = null
        var canonical: ((List<Long>) -> Map<Long, String>)? = null
        var fallback: ((Long) -> SmsThreadFallback?)? = null
        var direct: ((Int) -> List<SmsConversationRow>)? = null
        var unreadRows: (() -> Map<Long, Long>)? = null
        var sms: ((Long, Long?, Int) -> List<SmsRawMessage>)? = { _, _, _ -> emptyList() }
        var smsGroup: ((Long, Long) -> List<SmsRawMessage>)? = { _, _ -> emptyList() }
        var mms: ((Long, Long?, Int) -> List<SmsRawMessage>)? = { _, _, _ -> emptyList() }
        var mmsGroup: ((Long, Long) -> List<SmsRawMessage>)? = { _, _ -> emptyList() }
        var smsMatches: ((String, Long?, Int) -> List<SmsRawMessage>)? = { _, _, _ -> emptyList() }
        var smsMatchGroup: ((String, Long) -> List<SmsRawMessage>)? = { _, _ -> emptyList() }
        var mmsMatches: ((String, Long?, Int) -> List<SmsRawMessage>)? = { _, _, _ -> emptyList() }
        var mmsMatchGroup: ((String, Long) -> List<SmsRawMessage>)? = { _, _ -> emptyList() }
        override fun conversations(limit: Int, beforeMillis: Long, beforeThreadId: String) =
            SmsConversationPage((conversations?.invoke() ?: throw SmsStoreException())
                .filter { beforeMillis == 0L && beforeThreadId.isEmpty() || (it.dateMillis ?: 0) <= beforeMillis }
                .sortedWith(compareByDescending<SmsConversationRow> { it.dateMillis ?: 0L }.thenByDescending { it.threadId }).take(limit))
        override fun conversationDateGroup(millis: Long) = (conversations?.invoke() ?: throw SmsStoreException())
            .filter { smsClampDate(it.dateMillis ?: 0) == millis }.take(2049)
        override fun unreadCounts() = unreadRows?.invoke() ?: throw SmsStoreException()
        override fun canonicalAddresses(ids: List<Long>) = canonical?.invoke(ids) ?: throw SmsStoreException()
        override fun newestThreadRow(threadId: Long) = fallback?.invoke(threadId)
        override fun directThreads(limit: Int) = SmsConversationPage(direct?.invoke(limit) ?: throw SmsStoreException())
        override fun smsHistory(threadId: Long, upperMillis: Long?, limit: Int) = sms!!.invoke(threadId, upperMillis, limit)
        override fun smsDateGroup(threadId: Long, millis: Long) = smsGroup!!.invoke(threadId, millis)
        override fun mmsHistory(threadId: Long, upperMillis: Long?, limit: Int) = mms!!.invoke(threadId, upperMillis, limit)
        override fun mmsDateGroup(threadId: Long, millis: Long) = mmsGroup!!.invoke(threadId, millis)
        override fun smsSearch(pattern: String, upperMillis: Long?, limit: Int) = smsMatches!!.invoke(pattern, upperMillis, limit)
        override fun smsSearchGroup(pattern: String, millis: Long) = smsMatchGroup!!.invoke(pattern, millis)
        override fun mmsSearch(pattern: String, upperMillis: Long?, limit: Int) = mmsMatches!!.invoke(pattern, upperMillis, limit)
        override fun mmsSearchGroup(pattern: String, millis: Long) = mmsMatchGroup!!.invoke(pattern, millis)
    }

    private fun store(provider: FakeProvider, hasReadPermission: () -> Boolean) =
        AndroidSmsStore(provider, dispatcher = Dispatchers.Unconfined, hasReadPermission = hasReadPermission)

    @Test fun threadStoreFallsBackFromConversationsAndCanonicalAddresses() = runBlocking {
        val provider = FakeProvider()
        val store = store(provider, { true })
        provider.direct = { listOf(SmsConversationRow(7, 5, "direct", emptyList(), null, 0, address = "+15550000007")) }
        val direct = store.threads(50, 0, "")!!
        assertEquals("+15550000007", direct.threads.single().address)
        assertEquals("7", direct.threads.single().threadId)
        provider.conversations = { listOf(SmsConversationRow(8, 4, "sender id", emptyList(), 2, 0, address = "ACME BANK")) }
        provider.unreadRows = { mapOf(8L to 2L) }
        val sender = store.threads(50, 0, "")!!
        assertEquals("ACME BANK", sender.threads.single().address)
        assertEquals(2L, sender.threads.single().unreadCount)
        provider.conversations = { listOf(SmsConversationRow(9, 6, "via ids", listOf(3), 4, 1)) }
        provider.canonical = { throw SecurityException("oem") }
        provider.fallback = { null }
        val skipped = store.threads(50, 0, "")!!
        assertTrue(skipped.threads.isEmpty())
        assertEquals(1, skipped.skipped)
        provider.fallback = { id -> if (id == 9L) SmsThreadFallback("+15550000009", 6, "fallback", true) else null }
        provider.unreadRows = { mapOf(9L to 3L) }
        val resolved = store.threads(50, 0, "")!!
        assertEquals("+15550000009", resolved.threads.single().address)
        assertEquals(3L, resolved.threads.single().unreadCount)
        provider.conversations = { throw IllegalArgumentException("no view") }
        provider.direct = { emptyList() }
        assertTrue(store.threads(50, 0, "")!!.threads.isEmpty())
        assertNull(store(provider, { false }).threads(50, 0, ""))
    }

    @Test fun threadUnreadCountComesFromUnreadRowsNotTheReadFlag() = runBlocking {
        val provider = FakeProvider()
        val store = store(provider, { true })
        // `read` means "all messages read": subtracting it from 100 messages would report 99 unread.
        provider.conversations = { listOf(SmsConversationRow(11, 20, "all read", emptyList(), 100, 1, address = "+15550000011")) }
        provider.unreadRows = { emptyMap() }
        assertEquals(0L, store.threads(50, 0, "")!!.threads.single().unreadCount)
        provider.unreadRows = { mapOf(11L to 3L) }
        assertEquals(3L, store.threads(50, 0, "")!!.threads.single().unreadCount)
        // When the unread query fails, the newest-row fallback still answers with a boolean.
        provider.unreadRows = { throw SecurityException("oem") }
        provider.fallback = { SmsThreadFallback("+15550000011", 20, "fallback", true) }
        assertEquals(1L, store.threads(50, 0, "")!!.threads.single().unreadCount)
        provider.fallback = { SmsThreadFallback("+15550000011", 20, "fallback", false) }
        assertEquals(0L, store.threads(50, 0, "")!!.threads.single().unreadCount)
    }

    @Test fun threadStoreTruncatesOnCodepointsAndSkipsUndecodableRows() = runBlocking {
        val provider = FakeProvider()
        val store = store(provider, { true })
        provider.conversations = {
            listOf(
                SmsConversationRow(1, 10, "s\u0000nippet", emptyList(), 5, 2, address = "é".repeat(40)),
                SmsConversationRow(2, null, "no date", emptyList(), 1, 0, address = "+15550000002"),
                SmsConversationRow(3, 11, "empty address", emptyList(), 1, 0, address = ""),
                SmsConversationRow(4, -5, "neg", emptyList(), 2, 2, address = "+15550000004"),
            )
        }
        provider.unreadRows = { mapOf(1L to 3L) }
        provider.fallback = { id -> if (id == 2L) SmsThreadFallback("+15550000002", 12, null, false) else null }
        val page = store.threads(50, 0, "")!!
        assertEquals(3, page.threads.size)
        assertEquals(1, page.skipped)
        val first = page.threads.first { it.threadId == "1" }
        assertEquals(64, first.address.toByteArray().size)
        assertEquals("s\uFFFDnippet", first.snippet)
        assertEquals(3L, first.unreadCount)
        val second = page.threads.first { it.threadId == "2" }
        assertEquals(12L, second.dateMillis)
        val fourth = page.threads.first { it.threadId == "4" }
        assertEquals(0L, fourth.dateMillis)
    }

    @Test fun historyStoreSanitizesDirtAndAppliesLexicalCursorTies() = runBlocking {
        val provider = FakeProvider()
        val store = store(provider, { true })
        provider.sms = { _, upper, _ ->
            listOf(
                SmsRawMessage(100, 1_000, "+1555", "hello", 0, true, true),
                SmsRawMessage(99, 1_000, "+1555", "tie", 1, false, true),
                SmsRawMessage(98, 999, "+1555", "x".repeat(24_577), 0, false, true),
                SmsRawMessage(97, 998, null, "no address", 0, false, true),
                SmsRawMessage(96, 997, "+1555", "draft", 0, false, false),
                SmsRawMessage(95, -50, "+1555", "ne\u0000gative", 0, false, true),
            ).filter { upper == null || it.dateMillis <= upper }
        }
        val first = store.history("42", 0, "", 50)!!
        assertEquals(listOf("sms:99", "sms:100", "sms:95"), first.messages.map { it.messageId })
        assertEquals("hello", first.messages[1].text)
        assertEquals("ne\uFFFDgative", first.messages.last().text)
        assertEquals(0L, first.messages.last().dateMillis)
        assertEquals(3, first.skipped)
        assertFalse(first.more)
        // A terminal page carries a terminal cursor so the Mac never offers empty "load older" requests.
        assertEquals(0L, first.nextBeforeMillis)
        assertEquals("", first.nextBeforeMessageId)
        // Byte-wise lexical ties: "sms:100" sorts before "sms:99", so the cursor below skips both.
        val passed = store.history("42", 1_000, "sms:100", 50)!!
        assertEquals(listOf("sms:95"), passed.messages.map { it.messageId })
        val replayed = store.history("42", 1_000, "sms:99", 50)!!
        assertEquals(listOf("sms:100", "sms:95"), replayed.messages.map { it.messageId })
        assertTrue(store.history("addr:+1555", 0, "", 50)!!.messages.isEmpty())
        assertNull(store(provider, { false }).history("42", 0, "", 50))
        provider.sms = { _, _, _ -> throw SecurityException("oem") }
        provider.mms = { _, _, _ -> throw SecurityException("oem") }
        try { store.history("42", 0, "", 50); fail("both sources") } catch (_: SmsStoreException) {}
    }

    @Test fun historySkipsUndisplayableBatchesAndStillFindsOlderMessages() = runBlocking {
        val provider = FakeProvider()
        val store = store(provider, { true })
        // The newest raw batch is entirely unsupported; the older valid row must still load on the same page.
        val dirt = (1..52).map { SmsRawMessage(it.toLong(), 1_000L - it, "+1555", "unsupported", 0, false, false) }
        val older = listOf(SmsRawMessage(200, 500, "+1555", "older", 0, false, true))
        provider.sms = { _, upper, limit -> (dirt + older).filter { upper == null || it.dateMillis <= upper }.sortedByDescending { it.dateMillis }.take(limit) }
        val page = store.history("42", 0, "", 20)!!
        assertEquals(listOf("sms:200"), page.messages.map { it.messageId })
        assertEquals(52, page.skipped)
        // A page whose source ran dry is terminal even when it was reached through skipped batches.
        assertFalse(page.more)
        assertEquals(0L, page.nextBeforeMillis)
        assertEquals("", page.nextBeforeMessageId)
    }

    @Test fun historyScanStopsAtScanBudgetAndCarriesAContinuation() = runBlocking {
        val provider = FakeProvider()
        val store = store(provider, { true })
        // Every batch is undisplayable for more rounds than the scan budget allows: the page stays empty but
        // must still hand the Mac a strictly older cursor instead of a false "all messages loaded".
        provider.sms = { _, upper, limit -> (1..limit).map { offset -> SmsRawMessage(offset.toLong(), ((upper ?: 100_000) - offset * 2).coerceAtLeast(2), "+1555", "unsupported", 0, false, false) } }
        val page = store.history("42", 0, "", 20)!!
        assertTrue(page.messages.isEmpty())
        assertTrue(page.skipped > 0)
        assertTrue(page.more)
        assertTrue(page.nextBeforeMillis > 0)
        assertTrue(page.nextBeforeMessageId.startsWith("sms:"))
    }

    @Test fun threadPagesAndSubscriptionsRideTheV3Wire() = runBlocking {
        val h = Harness(coroutineContext[ContinuationInterceptor] as CoroutineDispatcher)
        val lan = Channel()
        ready(h, lan)
        // A page answers with the cursor the Mac must send back for older conversations.
        h.store.threadsResult = SmsThreadPage(listOf(SmsThreadRecord("42", "+15551234567", "hi", 900, 0)), 0, false, 800, "40", true)
        val firstRequest = request()
        h.owner.handle(lan.descriptor, SmsWireMessage.of(2, text(firstRequest), number(0), text("")).encode())
        until { lan.sent.any { it.kind == 4L } }
        assertEquals(Triple(50, 0L, ""), h.store.threadCalls.last())
        val done = lan.sent.last { it.kind == 4L }
        assertEquals(0L, done.number(1))
        assertEquals(800L, done.number(2))
        assertEquals("40", done.text(3))
        h.owner.handle(lan.descriptor, SmsWireMessage.of(2, text(request()), number(800), text("40")).encode())
        until { h.store.threadCalls.size == 2 }
        assertEquals(Triple(50, 800L, "40"), h.store.threadCalls.last())
        // Provider history and live events carry the subscription that produced the message.
        h.store.historyResult = SmsHistoryPage(listOf(SmsHistoryMessage("sms:1", "+15551234567", 900, 0, false, "hello", "42", 2)), 0, "", false, 0)
        h.owner.handle(lan.descriptor, SmsWireMessage.of(5, text(request()), text("42"), number(0), text(""), number(10)).encode())
        until { lan.sent.any { it.kind == 6L } }
        assertEquals(2L, lan.sent.first { it.kind == 6L }.number(11))
        h.owner.submitLive(listOf(SmsLiveEvent("+15551234567", 1_700_000_000_000, "live", 1)))
        until { lan.sent.count { it.kind == 6L } == 2 }
        assertEquals(1L, lan.sent.last { it.kind == 6L }.number(11))
        h.owner.invalidate()
    }

    @Test fun threadStorePagesByCursorAndReportsMore() = runBlocking {
        val provider = FakeProvider()
        val store = store(provider, { true })
        provider.conversations = {
            listOf(
                SmsConversationRow(1, 900, "a", emptyList(), 1, 0, address = "+15550000001"),
                SmsConversationRow(2, 500, "b", emptyList(), 1, 0, address = "+15550000002"),
                SmsConversationRow(3, 100, "c", emptyList(), 1, 0, address = "+15550000003"),
            )
        }
        val first = store.threads(2, 0, "")!!
        assertEquals(listOf("1", "2"), first.threads.map { it.threadId })
        assertTrue(first.more)
        assertEquals(500L, first.nextBeforeMillis)
        assertEquals("2", first.nextBeforeThreadId)
        val second = store.threads(2, first.nextBeforeMillis, first.nextBeforeThreadId)!!
        assertEquals(listOf("3"), second.threads.map { it.threadId })
        assertFalse(second.more)
        assertEquals(0L, second.nextBeforeMillis)
        assertEquals("", second.nextBeforeThreadId)
    }

    @Test fun threadPagesCompleteTimestampGroupsBeforeApplyingLexicalCursors() = runBlocking {
        val provider = FakeProvider()
        provider.conversations = { (1L..100L).map { id ->
            SmsConversationRow(id, 1000, "same stamp", emptyList(), 1, 1, address = "+1555$id")
        } + SmsConversationRow(101, 900, "older", emptyList(), 1, 1, address = "+1555101") }
        val store = store(provider, { true })
        val found = mutableListOf<String>()
        var cursor = 0L to ""
        var terminal = false
        repeat(10) {
            if (!terminal) {
                val page = store.threads(15, cursor.first, cursor.second)!!
                assertTrue(page.threads.size <= 15)
                found += page.threads.map { it.threadId }
                cursor = page.nextBeforeMillis to page.nextBeforeThreadId
                terminal = !page.more
            }
        }
        assertTrue(terminal)
        assertEquals((1L..100L).map { it.toString() }.sortedDescending() + "101", found)
        assertEquals(found.size, found.distinct().size)
        assertEquals(0L to "", cursor)
    }

    @Test fun threadScanSkipsAnUnreadableWindowWithoutHidingOlderConversations() = runBlocking {
        val provider = FakeProvider()
        provider.conversations = { (1L..60L).map { id ->
            SmsConversationRow(id, 1000 - id, "unreadable", emptyList(), 1, 1)
        } + SmsConversationRow(61, 900, "valid", emptyList(), 1, 1, address = "+155561") }
        val page = store(provider, { true }).threads(15, 0, "")!!
        assertEquals(listOf("61"), page.threads.map { it.threadId })
        assertEquals(60, page.skipped)
        assertFalse(page.more)
    }

    @Test fun threadScanBudgetReturnsAContinuationAfterOnlyUnreadableRows() = runBlocking {
        val provider = FakeProvider()
        provider.conversations = { (1L..400L).map { id ->
            SmsConversationRow(id, 1000 - id, "unreadable", emptyList(), 1, 1)
        } + SmsConversationRow(401, 500, "valid", emptyList(), 1, 1, address = "+1555401") }
        val store = store(provider, { true })
        val first = store.threads(15, 0, "")!!
        assertTrue(first.threads.isEmpty())
        assertTrue(first.more)
        assertEquals(376, first.skipped)
        val second = store.threads(15, first.nextBeforeMillis, first.nextBeforeThreadId)!!
        assertEquals(listOf("401"), second.threads.map { it.threadId })
        assertFalse(second.more)
    }

    @Test fun oversizedThreadTimestampGroupIsUnsupportedInsteadOfTruncated() = runBlocking {
        val provider = FakeProvider()
        provider.conversations = { (1L..2049L).map { id ->
            SmsConversationRow(id, 1000, "same stamp", emptyList(), 1, 1, address = "+1555$id")
        } }
        try { store(provider, { true }).threads(15, 0, ""); fail("oversized thread group") }
        catch (_: SmsPagingUnsupported) { }
    }

    @Test fun threadCursorAtZeroDoesNotRestartTheList() = runBlocking {
        val provider = FakeProvider()
        provider.conversations = { (1L..100L).map { id ->
            SmsConversationRow(id, 0, "legacy", emptyList(), 1, 1, address = "+1555$id")
        } }
        val store = store(provider, { true })
        val first = store.threads(15, 0, "")!!
        val second = store.threads(15, first.nextBeforeMillis, first.nextBeforeThreadId)!!
        assertEquals((1L..100L).map { it.toString() }.sortedDescending().take(30),
            (first.threads + second.threads).map { it.threadId })
        assertTrue(second.more)
    }

    @Test fun threadFailureOnAnOlderPageNeverReturnsAnEmptyTerminalPage() = runBlocking {
        val provider = FakeProvider()
        try { store(provider, { true }).threads(15, 1000, "10"); fail("provider failure") }
        catch (_: SmsStoreException) { }
    }

    @Test fun unsupportedThreadPageReportsResultFourAndKeepsTheLocalSnapshot() = runBlocking {
        val h = Harness(coroutineContext[ContinuationInterceptor] as CoroutineDispatcher)
        h.store.threadsResult = SmsThreadPage(listOf(SmsThreadRecord("42", "+1555", "kept", 1000, 0)), 0)
        h.owner.loadThreads()
        until { !h.owner.loading && h.owner.threads?.size == 1 }
        h.store.threadsUnsupported = true
        h.owner.loadThreads()
        until { !h.owner.loading && h.owner.status.contains("Too many conversations") }
        assertEquals("42", h.owner.threads!!.single().threadId)
        val channel = Channel()
        ready(h, channel)
        val id = request()
        h.owner.handle(channel.descriptor, SmsWireMessage.of(2, text(id), number(0), text("")).encode())
        until { channel.sent.any { it.kind == 4L && it.text(0) == id } }
        assertEquals(4L, channel.sent.first { it.kind == 4L && it.text(0) == id }.number(1))
        assertFalse(channel.sent.any { it.kind == 3L && it.text(0) == id })
        h.owner.invalidate()
    }

    @Test fun partialThreadPageKeepsItsSnapshotAndCursorForRetry() = runBlocking {
        val h = Harness(coroutineContext[ContinuationInterceptor] as CoroutineDispatcher)
        h.store.threadsResult = SmsThreadPage(listOf(SmsThreadRecord("42", "+1555", "kept", 1000, 0)), 0, false, 1000, "42", true)
        h.owner.loadThreads()
        until { !h.owner.loading && h.owner.threadsMore }
        h.store.threadsResult = SmsThreadPage(listOf(SmsThreadRecord("99", "+1999", "partial", 900, 0)), 0, partial = true)
        h.owner.loadMoreThreads()
        until { !h.owner.loading && h.owner.status.contains("Try again") }
        assertEquals(listOf("42"), h.owner.threads!!.map { it.threadId })
        assertTrue(h.owner.threadsMore)
        h.store.threadsResult = SmsThreadPage(listOf(SmsThreadRecord("43", "+1444", "complete", 800, 0)), 0)
        h.owner.loadMoreThreads()
        until { !h.owner.loading && h.owner.threads?.size == 2 }
        assertEquals(h.store.threadCalls[1], h.store.threadCalls[2])
        assertEquals(listOf("42", "43"), h.owner.threads!!.map { it.threadId })
        assertFalse(h.owner.threadsMore)
        h.owner.invalidate()
    }

    @Test fun historyCarriesTheProviderSubscription() = runBlocking {
        val provider = FakeProvider()
        val store = store(provider, { true })
        provider.sms = { _, _, _ -> listOf(SmsRawMessage(7, 1_000, "+1555", "hi", 0, false, true, subscriptionId = 2)) }
        val page = store.history("42", 0, "", 50)!!
        assertEquals(2, page.messages.single().subscriptionId)
    }

    @Test fun thePanelLoadsAFifteenRowFirstPageThenMoreOnDemand() = runBlocking {
        val h = Harness(coroutineContext[ContinuationInterceptor] as CoroutineDispatcher)
        h.store.threadsResult = SmsThreadPage(listOf(SmsThreadRecord("1", "+15550000001", "first", 900, 0)), 0, false, 800, "0", true)
        h.owner.loadThreads()
        until { h.owner.threads != null && !h.owner.loading }
        assertEquals(Triple(15, 0L, ""), h.store.threadCalls.first())
        assertTrue(h.owner.threadsMore)
        h.store.threadsResult = SmsThreadPage(listOf(SmsThreadRecord("2", "+15550000002", "second", 700, 0)), 0, false, 0, "", false)
        h.owner.loadMoreThreads()
        until { h.owner.threads?.size == 2 && !h.owner.loading }
        assertEquals(Triple(15, 800L, "0"), h.store.threadCalls.last())
        assertEquals(listOf("1", "2"), h.owner.threads?.map { it.threadId })
        assertFalse(h.owner.threadsMore)
        h.owner.invalidate()
    }

    @Test fun localProviderFailuresNeverClaimPermissionWasDenied() = runBlocking {
        val h = Harness(coroutineContext[ContinuationInterceptor] as CoroutineDispatcher)
        h.owner.refreshPermissions()
        h.store.throwOnThreads = true
        h.owner.loadThreads()
        until { h.owner.status == "Conversations are unavailable" }
        assertTrue(h.owner.permissionsState.read)
        h.store.throwOnHistory = true
        h.owner.select("42")
        until { h.owner.status == "Messages are unavailable" }
        assertTrue(h.owner.permissionsState.read)
        h.owner.invalidate()
    }

    @Test fun expiredPageCannotDrainAfterBackpressureClears() = runBlocking {
        val h = Harness(coroutineContext[ContinuationInterceptor] as CoroutineDispatcher)
        val lan = Channel()
        ready(h, lan)
        lan.blocked = true
        val attempts = lan.attempts
        h.store.threadsResult = SmsThreadPage(listOf(SmsThreadRecord("42", "+1555", "test", 10, 0)), 0)
        val request = request()
        h.owner.handle(lan.descriptor, SmsWireMessage.of(2, text(request), number(0), text("")).encode())
        until { lan.attempts > attempts }
        h.time += 30_001
        h.owner.expire()
        yield()
        lan.blocked = false
        h.owner.capacityAvailable(lan.descriptor)
        yield()
        assertTrue(lan.sent.none { it.kind == 3L && it.text(0) == request })
        assertTrue(lan.sent.none { it.kind == 4L && it.text(0) == request })
        h.owner.invalidate()
    }

    @Test fun bluetoothReplyKeepsItsSixtySecondWindow() = runBlocking {
        val h = Harness(coroutineContext[ContinuationInterceptor] as CoroutineDispatcher)
        val ble = Channel("ble")
        ready(h, ble)
        val request = request()
        h.owner.handle(ble.descriptor, SmsWireMessage.of(11, text(request), text("42"), text("+1555"), number(4), number(1), data(digest("test")), number(0)).encode())
        h.time += 30_001
        h.owner.expire()
        yield()
        assertTrue(ble.sent.none { it.kind == 14L && it.text(0) == request })
        h.owner.handle(ble.descriptor, SmsWireMessage.of(12, text(request), number(0), data(utf8("test"))).encode())
        h.owner.handle(ble.descriptor, SmsWireMessage.of(13, text(request)).encode())
        until { ble.sent.any { it.kind == 14L && it.text(0) == request } }
        assertEquals(0L, ble.sent.first { it.kind == 14L && it.text(0) == request }.number(1))
        h.owner.invalidate()
    }

    @Test fun negativeLiveAcknowledgementNeverReportsDelivery() = runBlocking {
        val h = Harness(coroutineContext[ContinuationInterceptor] as CoroutineDispatcher)
        val lan = Channel()
        ready(h, lan)
        h.owner.submitLive(listOf(SmsLiveEvent("+1555", 1000, "hello")))
        until { lan.sent.any { it.kind == 8L } }
        val stream = lan.sent.first { it.kind == 6L }.text(0)
        h.owner.handle(lan.descriptor, SmsWireMessage.of(9, text(stream), number(6)).encode())
        assertEquals(0, h.owner.relayedLive)
        assertEquals(1, h.owner.failedLive)
        assertEquals(0, h.owner.waitingLive)
        h.owner.invalidate()
    }

    @Test fun historyKeepsSmsSourcePositionWhenMmsIsMuchOlder() = runBlocking {
        val provider = FakeProvider()
        val sms = (1L..100L).map { id -> SmsRawMessage(id, 1000 - id, "+1555", if (id <= 42) "x".repeat(24_577) else "valid", 0, false, true) }
        val mms = listOf(SmsRawMessage(1, 1, "+1555", "old MMS", 0, false, true))
        provider.sms = { _, upper, limit -> sms.filter { upper == null || it.dateMillis <= upper }.take(limit) }
        provider.smsGroup = { _, date -> sms.filter { it.dateMillis == date } }
        provider.mms = { _, upper, limit -> mms.filter { upper == null || it.dateMillis <= upper }.take(limit) }
        provider.mmsGroup = { _, date -> mms.filter { it.dateMillis == date } }
        val page = store(provider, { true }).history("42", 0, "", 10)!!
        assertEquals((43L..52L).map { "sms:$it" }, page.messages.map { it.messageId })
        assertTrue(page.more)
    }

    @Test fun clampedZeroTimestampCursorDoesNotRestartThePage() = runBlocking {
        val provider = FakeProvider()
        val rows = (1L..40L).map { SmsRawMessage(it, -it, "+1555", "legacy", 0, false, true) }
        provider.sms = { _, upper, limit -> rows.filter { upper == null || it.dateMillis <= upper }.take(limit) }
        provider.smsGroup = { _, date -> rows.filter { smsClampDate(it.dateMillis) == date } }
        val store = store(provider, { true })
        val first = store.history("42", 0, "", 2)!!
        val second = store.history("42", first.nextBeforeMillis, first.nextBeforeMessageId, 2)!!
        assertEquals(listOf("sms:9", "sms:8"), first.messages.map { it.messageId })
        assertEquals(listOf("sms:7", "sms:6"), second.messages.map { it.messageId })
        assertTrue(second.more)
    }

    @Test fun oversizedTimestampGroupFailsWithoutAFalseTerminalCursor() = runBlocking {
        val provider = FakeProvider()
        val rows = (1L..2049L).map { SmsRawMessage(it, 1000, "+1555", "hello", 0, false, true) }
        provider.sms = { _, _, limit -> rows.take(limit) }
        provider.smsGroup = { _, _ -> rows }
        try { store(provider, { true }).history("42", 0, "", 10); fail("oversized group") }
        catch (_: SmsPagingUnsupported) { }
    }

    @Test fun providerFailureIsNotAnEmptyInbox() = runBlocking {
        try { store(FakeProvider(), { true }).threads(50, 0, ""); fail("both sources failed") }
        catch (_: SmsStoreException) { }
    }

    @Test fun nativePartsPreserveOrderAndRejectMixedOrMalformedBatches() {
        val part = SmsReceivedPart("BANK", 1_700_000_000_000, "code 42")
        assertEquals("code 42", smsReceivedEvent(listOf(part))!!.body)
        assertEquals("code 42tail", smsReceivedEvent(listOf(part, part.copy(body = "tail")))!!.body)
        assertEquals("héllo \uFFFD end", smsReceivedEvent(listOf(part.copy(body = "héllo \u0000 end")))!!.body)
        assertNull(smsReceivedEvent(emptyList()))
        assertNull(smsReceivedEvent(listOf(part, part.copy(address = "OTHER"))))
        assertNull(smsReceivedEvent(listOf(part, part.copy(subscriptionId = 2))))
        assertNull(smsReceivedEvent(listOf(part.copy(dateMillis = 0))))
        assertNull(smsReceivedEvent(listOf(part.copy(body = null))))
        assertNull(smsReceivedEvent(listOf(part.copy(body = "x".repeat(24_577)))))
        assertNull(smsReceivedEvent(listOf(part.copy(body = "\uD800"))))
    }

    @Test fun liveIdsAreDeterministicAndAddressTokensNormalize() {
        val a = smsLiveMessageId("+15551234567", 1_700_000_000_000, "hello")
        assertEquals(a, smsLiveMessageId("+15551234567", 1_700_000_000_000, "hello"))
        assertNotEquals(a, smsLiveMessageId("+15551234567", 1_700_000_000_001, "hello"))
        assertTrue(a.matches(Regex("live:[0-9a-f]{32}")))
        assertEquals("+15551234567", smsNormalizedAddress(" +1 (555) 123-4567"))
        assertEquals("BANK", smsNormalizedAddress("BANK"))
        assertEquals("ACME BANK", smsNormalizedAddress(" acme bank "))
        assertEquals("ACME BANK", smsNormalizedAddress("ACME BANK"))
        assertNotEquals(smsNormalizedAddress("ACME BANK"), smsNormalizedAddress("AUTH XYZ"))
        assertEquals("addr:BANK", SmsLiveEvent("BANK", 1, "x").threadId)
        assertEquals("addr:ACME BANK", SmsLiveEvent(" acme bank ", 1, "x").threadId)
        assertNotEquals(SmsLiveEvent("ACME BANK", 1, "same").messageId, SmsLiveEvent("AUTH XYZ", 1, "same").messageId)
        assertEquals("addr:+15551234567", SmsLiveEvent("+1 (555) 123-4567", 1, "x").threadId)
        assertEquals("sms:99", listOf("sms:99", "sms:100").maxWithOrNull { x, y -> smsCompareMessageIds(x, y) })
        assertEquals(160, smsTruncate("é".repeat(200), 160).toByteArray().size)
        assertEquals(158, smsTruncate("é".repeat(200), 159).toByteArray().size)
    }

    @Test fun submittedReplyCannotBeSentAgainAfterOriginatingTransportRetires() = runBlocking {
        val h = Harness(coroutineContext[ContinuationInterceptor] as CoroutineDispatcher)
        val lan = Channel("lan"); val ble = Channel("ble")
        ready(h, lan, ble)
        h.sender.pause = CompletableDeferred()
        val id = request(); val body = "hello"; val bytes = utf8(body)
        suspend fun submit(channel: Channel) {
            h.owner.handle(channel.descriptor, SmsWireMessage.of(11, text(id), text("42"), text("+15550000000"),
                number(bytes.size.toLong()), number(1), data(digest(body)), number(0)).encode())
            h.owner.handle(channel.descriptor, SmsWireMessage.of(12, text(id), number(0), data(bytes)).encode())
            h.owner.handle(channel.descriptor, SmsWireMessage.of(13, text(id)).encode())
        }
        submit(lan); until { h.sender.bodies.size == 1 }
        h.owner.retired(lan.descriptor)
        submit(ble)
        until { ble.sent.any { it.kind == 14L && it.text(0) == id && it.number(1) == 5L } }
        assertEquals("Uncertain submission must never reach telephony twice", 1, h.sender.bodies.size)
        h.owner.invalidate()
    }
}
