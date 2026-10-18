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
    private class FakeStore : SmsStore {
        var threadsResult: SmsThreadPage? = SmsThreadPage(emptyList(), 0)
        var historyResult: SmsHistoryPage? = SmsHistoryPage(emptyList(), 0, "", false, 0)
        var throwOnThreads = false
        var throwOnHistory = false
        var pause: CompletableDeferred<Unit>? = null
        val historyCalls = mutableListOf<Triple<String, Pair<Long, String>, Int>>()
        val threadCalls = mutableListOf<Int>()
        override suspend fun threads(limit: Int): SmsThreadPage? {
            threadCalls += limit
            if (throwOnThreads) throw SmsStoreException()
            return threadsResult
        }
        override suspend fun history(threadId: String, beforeMillis: Long, beforeMessageId: String, limit: Int): SmsHistoryPage? {
            if (throwOnHistory) throw SmsStoreException()
            historyCalls += Triple(threadId, beforeMillis to beforeMessageId, limit)
            pause?.await()
            return historyResult
        }
    }
    private class FakeSender : SmsSender {
        var outcome = SmsSendOutcome(0, "sms:77", 55)
        var pause: CompletableDeferred<Unit>? = null
        val addresses = mutableListOf<String>()
        val bodies = mutableListOf<String>()
        override suspend fun send(address: String, body: String): SmsSendOutcome {
            addresses += address
            bodies += body
            pause?.await()
            return outcome
        }
    }
    private class Channel(val transport: String = "lan") : SecuredChannel {
        override val descriptor = ChannelDescriptor(UUID.randomUUID().toString(), transport, DeviceIdentity("peer", "Device", "macos", "key", "fingerprint"))
        val sent = mutableListOf<SmsWireMessage>()
        override suspend fun sendData(bytes: ByteArray) { sent.add(SmsWireMessage.decode(bytes)!!) }
    }
    private class Clock {
        var time = 0L
        private val sleeps = linkedMapOf<CompletableDeferred<Unit>, Long>()
        suspend fun wait(duration: Long) {
            val wake = CompletableDeferred<Unit>()
            sleeps[wake] = time + duration
            try { wake.await() } finally { sleeps.remove(wake) }
        }
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
        val owner = SmsController(store, sender, dispatcher = dispatcher, now = { time }, wait = clock::wait, permissions = { true })
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
        assertEquals(1, finished)
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
        h.owner.handle(ble.descriptor, SmsWireMessage.of(2, text(request())).encode())
        until { h.store.threadCalls.isNotEmpty() }
        assertEquals(listOf(20), h.store.threadCalls)
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
        h.tick(2_000)
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
        assertEquals(DataHandling.HANDLED, h.owner.handle(lan.descriptor, SmsWireMessage.of(2, text(first)).encode()))
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
        h.owner.handle(lan.descriptor, SmsWireMessage.of(2, text(request())).encode())
        until { lan.sent.count { it.kind == 4L } == 2 }
        assertEquals(1L, lan.sent.filter { it.kind == 4L }.last().number(1))
        h.store.throwOnThreads = true
        h.owner.handle(lan.descriptor, SmsWireMessage.of(2, text(request())).encode())
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

    @Test fun replyAssemblyVerifiesDigestAndReportsRadioVerdict() = runBlocking {
        val h = Harness(coroutineContext[ContinuationInterceptor] as CoroutineDispatcher)
        val lan = Channel()
        ready(h, lan)
        val request = request()
        val text = "reply body"
        val bytes = utf8(text)
        h.owner.handle(lan.descriptor, SmsWireMessage.of(11, text(request), text("42"), text("+15551234567"), number(bytes.size.toLong()), number(1), data(digest(text))).encode())
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
    }

    @Test fun replyFailuresReportFailedDisabledAndInvalidWithoutSendingWrongText() = runBlocking {
        val h = Harness(coroutineContext[ContinuationInterceptor] as CoroutineDispatcher)
        val lan = Channel()
        ready(h, lan)
        fun begin(request: String, text: String, count: Long = 1, hash: ByteArray = digest(text)) =
            SmsWireMessage.of(11, text(request), text("42"), text("+1555"), number(text.toByteArray().size.toLong()), number(count), data(hash)).encode()
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
        assertTrue(lan.sent.filter { it.kind == 14L }.all { it.number(1) == 0L || it.text(2).isEmpty() })
    }

    @Test fun conflictingReplyBeginIsRejectedAndExpiryReportsFailure() = runBlocking {
        val h = Harness(coroutineContext[ContinuationInterceptor] as CoroutineDispatcher)
        val lan = Channel()
        ready(h, lan)
        val request = request()
        val bytes = utf8("text")
        val begin = SmsWireMessage.of(11, text(request), text("42"), text("+1555"), number(bytes.size.toLong()), number(1), data(digest("text")))
        h.owner.handle(lan.descriptor, begin.encode())
        h.owner.handle(lan.descriptor, SmsWireMessage.of(11, text(request), text("42"), text("+1555"), number(99), number(1), data(digest("text"))).encode())
        until { lan.sent.any { it.kind == 14L } }
        assertEquals(6L, lan.sent.first { it.kind == 14L }.number(1))
        val timeout = request()
        h.owner.handle(lan.descriptor, SmsWireMessage.of(11, text(timeout), text("42"), text("+1555"), number(bytes.size.toLong()), number(1), data(digest("text"))).encode())
        h.time += 30_001
        h.owner.expire()
        until { lan.sent.any { it.kind == 14L && it.text(0) == timeout } }
        assertEquals(5L, lan.sent.first { it.kind == 14L && it.text(0) == timeout }.number(1))
    }

    @Test fun replacedReplyRequestCancelsItsJobAndKeepsTheNewerSlot() = runBlocking {
        val h = Harness(coroutineContext[ContinuationInterceptor] as CoroutineDispatcher)
        val lan = Channel()
        ready(h, lan)
        fun begin(request: String, text: String) =
            SmsWireMessage.of(11, text(request), text("42"), text("+1555"), number(text.toByteArray().size.toLong()), number(1), data(digest(text)))
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
        until { h.sender.bodies.size == 2 }
        h.sender.pause!!.complete(Unit)
        until { lan.sent.any { it.kind == 14L } }
        // The retired request reports nothing, and its late completion cannot erase the newer request's tracking.
        assertTrue(lan.sent.none { it.kind == 14L && it.text(0) == first })
        val result = lan.sent.single { it.kind == 14L }
        assertEquals(second, result.text(0))
        assertEquals(0L, result.number(1))
        assertEquals(listOf("first", "second"), h.sender.bodies)
    }

    @Test fun expiryCancelsAnInFlightReplyAndReportsFailureOnce() = runBlocking {
        val h = Harness(coroutineContext[ContinuationInterceptor] as CoroutineDispatcher)
        val lan = Channel()
        ready(h, lan)
        val request = request()
        h.sender.pause = CompletableDeferred()
        h.owner.handle(lan.descriptor, SmsWireMessage.of(11, text(request), text("42"), text("+1555"), number(4), number(1), data(digest("late"))).encode())
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
        assertEquals(DataHandling.DISCARDED, h.owner.handle(lan.descriptor, SmsWireMessage.of(2, text(request())).encode()))
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
        override fun conversations() = conversations?.invoke() ?: throw SmsStoreException()
        override fun unreadCounts() = unreadRows?.invoke() ?: throw SmsStoreException()
        override fun canonicalAddresses(ids: List<Long>) = canonical?.invoke(ids) ?: throw SmsStoreException()
        override fun newestThreadRow(threadId: Long) = fallback?.invoke(threadId)
        override fun directThreads(limit: Int) = direct?.invoke(limit) ?: throw SmsStoreException()
        override fun smsHistory(threadId: Long, upperMillis: Long?, limit: Int) = sms!!.invoke(threadId, upperMillis, limit)
        override fun smsDateGroup(threadId: Long, millis: Long) = smsGroup!!.invoke(threadId, millis)
        override fun mmsHistory(threadId: Long, upperMillis: Long?, limit: Int) = mms!!.invoke(threadId, upperMillis, limit)
        override fun mmsDateGroup(threadId: Long, millis: Long) = mmsGroup!!.invoke(threadId, millis)
    }

    private fun store(provider: FakeProvider, hasReadPermission: () -> Boolean) =
        AndroidSmsStore(provider, dispatcher = Dispatchers.Unconfined, hasReadPermission = hasReadPermission)

    @Test fun threadStoreFallsBackFromConversationsAndCanonicalAddresses() = runBlocking {
        val provider = FakeProvider()
        val store = store(provider, { true })
        provider.direct = { listOf(SmsConversationRow(7, 5, "direct", emptyList(), null, 0, address = "+15550000007")) }
        val direct = store.threads(50)!!
        assertEquals("+15550000007", direct.threads.single().address)
        assertEquals("7", direct.threads.single().threadId)
        provider.conversations = { listOf(SmsConversationRow(8, 4, "sender id", emptyList(), 2, 0, address = "ACME BANK")) }
        provider.unreadRows = { mapOf(8L to 2L) }
        val sender = store.threads(50)!!
        assertEquals("ACME BANK", sender.threads.single().address)
        assertEquals(2L, sender.threads.single().unreadCount)
        provider.conversations = { listOf(SmsConversationRow(9, 6, "via ids", listOf(3), 4, 1)) }
        provider.canonical = { throw SecurityException("oem") }
        provider.fallback = { null }
        val skipped = store.threads(50)!!
        assertTrue(skipped.threads.isEmpty())
        assertEquals(1, skipped.skipped)
        provider.fallback = { id -> if (id == 9L) SmsThreadFallback("+15550000009", 6, "fallback", true) else null }
        provider.unreadRows = { mapOf(9L to 3L) }
        val resolved = store.threads(50)!!
        assertEquals("+15550000009", resolved.threads.single().address)
        assertEquals(3L, resolved.threads.single().unreadCount)
        provider.conversations = { throw IllegalArgumentException("no view") }
        provider.direct = { emptyList() }
        assertTrue(store.threads(50)!!.threads.isEmpty())
        assertNull(store(provider, { false }).threads(50))
    }

    @Test fun threadUnreadCountComesFromUnreadRowsNotTheReadFlag() = runBlocking {
        val provider = FakeProvider()
        val store = store(provider, { true })
        // `read` means "all messages read": subtracting it from 100 messages would report 99 unread.
        provider.conversations = { listOf(SmsConversationRow(11, 20, "all read", emptyList(), 100, 1, address = "+15550000011")) }
        provider.unreadRows = { emptyMap() }
        assertEquals(0L, store.threads(50)!!.threads.single().unreadCount)
        provider.unreadRows = { mapOf(11L to 3L) }
        assertEquals(3L, store.threads(50)!!.threads.single().unreadCount)
        // When the unread query fails, the newest-row fallback still answers with a boolean.
        provider.unreadRows = { throw SecurityException("oem") }
        provider.fallback = { SmsThreadFallback("+15550000011", 20, "fallback", true) }
        assertEquals(1L, store.threads(50)!!.threads.single().unreadCount)
        provider.fallback = { SmsThreadFallback("+15550000011", 20, "fallback", false) }
        assertEquals(0L, store.threads(50)!!.threads.single().unreadCount)
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
        val page = store.threads(50)!!
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
        assertEquals("", page.nextBeforeMessageId)
    }

    @Test fun pduParserDecodesSevenBitUcs2AlphanumericAndMultipart() {
        val plain = buildPdu(PduSpec(address = "+15551234567", text = "Hello 123", timeMillis = 1_700_000_000_000, offsetMinutes = 330))
        val events = SmsPduParser.parse("3gpp", listOf(plain))
        assertEquals(1, events.size)
        assertEquals("+15551234567", events[0].address)
        assertEquals("Hello 123", events[0].body)
        assertEquals(1_700_000_000_000L, events[0].dateMillis)
        val unicode = buildPdu(PduSpec(address = "+15551234567", text = "héllo \u0000 end", timeMillis = 1_700_000_000_000, offsetMinutes = 0, ucs2 = true))
        assertEquals("héllo \uFFFD end", SmsPduParser.parse("3gpp", listOf(unicode)).single().body)
        val alpha = buildPdu(PduSpec(address = "BANK", text = "code 42", timeMillis = 1_700_000_000_000, offsetMinutes = -480, alphanumeric = true))
        assertEquals("BANK", SmsPduParser.parse("3gpp", listOf(alpha)).single().address)
        // A declared septet count of 7 (mod 8) must not decode the octet padding as a trailing character.
        val seven = buildPdu(PduSpec(address = "+15551234567", text = "code 42", timeMillis = 1_700_000_000_000, offsetMinutes = 0))
        assertEquals("code 42", SmsPduParser.parse("3gpp", listOf(seven)).single().body)
        val fifteen = buildPdu(PduSpec(address = "+15551234567", text = "0123456789abcde", timeMillis = 1_700_000_000_000, offsetMinutes = 0))
        assertEquals("0123456789abcde", SmsPduParser.parse("3gpp", listOf(fifteen)).single().body)
        val paddedHead = buildPdu(PduSpec(address = "+15551234567", text = "code 42", timeMillis = 1_700_000_000_000, offsetMinutes = 0, concat = Triple(7, 2, 1)))
        val paddedTail = buildPdu(PduSpec(address = "+15551234567", text = "tail", timeMillis = 1_700_000_000_000, offsetMinutes = 0, concat = Triple(7, 2, 2)))
        assertEquals("code 42tail", SmsPduParser.parse("3gpp", listOf(paddedHead, paddedTail)).single().body)
        val tail = buildPdu(PduSpec(address = "+15551234567", text = "two", timeMillis = 1_700_000_000_000, offsetMinutes = 0, concat = Triple(7, 2, 2)))
        val head = buildPdu(PduSpec(address = "+15551234567", text = "one ", timeMillis = 1_700_000_000_000, offsetMinutes = 0, concat = Triple(7, 2, 1)))
        assertEquals("one two", SmsPduParser.parse("3gpp", listOf(tail, head)).single().body)
        assertTrue(SmsPduParser.parse("3gpp2", listOf(plain)).isEmpty())
        assertTrue(SmsPduParser.parse(null, listOf(plain)).single().body == "Hello 123")
        assertTrue(SmsPduParser.parse("3gpp", listOf(byteArrayOf(1, 2, 3))).isEmpty())
        assertTrue(SmsPduParser.parse("3gpp", listOf(buildPdu(PduSpec(address = "+1555", text = "one ", timeMillis = 1, offsetMinutes = 0, concat = Triple(7, 2, 1))))).isEmpty())
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

    private class PduSpec(
        val address: String,
        val text: String,
        val timeMillis: Long,
        val offsetMinutes: Int,
        val ucs2: Boolean = false,
        val alphanumeric: Boolean = false,
        val concat: Triple<Int, Int, Int>? = null,
    )

    private fun buildPdu(spec: PduSpec): ByteArray {
        val header = spec.concat?.let { (reference, count, index) -> byteArrayOf(5, 0, 3, reference.toByte(), count.toByte(), index.toByte()) } ?: ByteArray(0)
        val body = if (spec.ucs2) header + spec.text.toByteArray(Charsets.UTF_16BE) else packSeptets(header, spec.text)
        val length = if (spec.ucs2) body.size else septetTotal(header, spec.text)
        val out = java.io.ByteArrayOutputStream()
        out.write(0)
        out.write(if (header.isEmpty()) 0x04 else 0x44)
        if (spec.alphanumeric) {
            val packed = packSeptets(ByteArray(0), spec.address)
            out.write(packed.size * 2)
            out.write(0xD0)
            out.write(packed)
        } else {
            val international = spec.address.startsWith("+")
            val digits = spec.address.removePrefix("+")
            out.write(digits.length)
            out.write(if (international) 0x91 else 0x81)
            out.write(bcd(digits))
        }
        out.write(0)
        out.write(if (spec.ucs2) 0x08 else 0x00)
        out.write(scts(spec.timeMillis, spec.offsetMinutes))
        out.write(length)
        out.write(body)
        return out.toByteArray()
    }

    private fun septetTotal(header: ByteArray, text: String): Int = (if (header.isEmpty()) 0 else (header.size * 8 + 6) / 7) + text.length

    private fun bcd(digits: String): ByteArray {
        val padded = if (digits.length % 2 == 1) digits + "F" else digits
        return ByteArray(padded.length / 2) { index ->
            val low = Character.digit(padded[index * 2], 16)
            val high = Character.digit(padded[index * 2 + 1], 16)
            ((high shl 4) or low).toByte()
        }
    }

    private fun scts(timeMillis: Long, offsetMinutes: Int): ByteArray {
        val calendar = java.util.Calendar.getInstance(java.util.TimeZone.getTimeZone("UTC"))
        calendar.timeInMillis = timeMillis + offsetMinutes * 60_000L
        fun semi(value: Int) = (value % 10 shl 4) or (value / 10)
        val quarters = kotlin.math.abs(offsetMinutes) / 15
        val tz = ((quarters % 10 shl 4) or (quarters / 10)) or (if (offsetMinutes < 0) 0x08 else 0)
        return byteArrayOf(
            semi(calendar.get(java.util.Calendar.YEAR) % 100).toByte(),
            semi(calendar.get(java.util.Calendar.MONTH) + 1).toByte(),
            semi(calendar.get(java.util.Calendar.DAY_OF_MONTH)).toByte(),
            semi(calendar.get(java.util.Calendar.HOUR_OF_DAY)).toByte(),
            semi(calendar.get(java.util.Calendar.MINUTE)).toByte(),
            semi(calendar.get(java.util.Calendar.SECOND)).toByte(),
            tz.toByte(),
        )
    }

    /** Writes header bytes then pads to a septet boundary before the packed 7-bit payload. */
    private fun packSeptets(header: ByteArray, text: String): ByteArray {
        val septets = text.map { it.code }.toIntArray()
        val headerSeptets = if (header.isEmpty()) 0 else (header.size * 8 + 6) / 7
        val total = headerSeptets + septets.size
        val out = ByteArray((total * 7 + 7) / 8)
        var bit = 0
        fun write(value: Int, bits: Int) {
            for (index in 0 until bits) {
                if (value shr index and 1 == 1) out[(bit + index) / 8] = (out[(bit + index) / 8].toInt() or (1 shl ((bit + index) % 8))).toByte()
            }
            bit += bits
        }
        header.forEach { write(it.toInt() and 255, 8) }
        while (bit < headerSeptets * 7) bit++
        septets.forEach { write(it, 7) }
        return out
    }
}
