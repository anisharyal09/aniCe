// SPDX-License-Identifier: GPL-3.0-or-later
// Probes independent wire bytes, cross-channel retries, clipboard conflicts and bounded lifecycle cleanup.
package io.github.anisharyal09.anice.features.clipboard

import io.github.anisharyal09.anice.infrastructure.connections.*
import io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity
import io.github.anisharyal09.anice.infrastructure.session.*
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import org.json.JSONObject
import java.security.MessageDigest
import java.util.UUID
import kotlin.coroutines.ContinuationInterceptor

class ClipboardTests {
    private class Native : NativeClipboard {
        var sample: ClipboardSample? = ClipboardSample("local", token = "1")
        var focused = true
        var fail = false
        var writes = 0
        var reads = 0
        var observer: (() -> Unit)? = null
        override fun read(): ClipboardSample? { reads++; return if (focused) sample else null }
        override fun token() = if (focused) sample?.token ?: "empty" else null
        override fun write(text: String, sensitive: Boolean): Boolean {
            if (fail) return false
            writes++; sample = ClipboardSample(text, sensitive, true, "write-$writes"); observer?.invoke(); return true
        }
        override fun observe(enabled: Boolean, changed: () -> Unit) { observer = if (enabled) changed else null }
    }
    private class Channel(val transport: String = "lan") : SecuredChannel {
        override val descriptor = ChannelDescriptor(UUID.randomUUID().toString(), transport, DeviceIdentity("peer", "Device", "macos", "key", "fingerprint"))
        val sent = mutableListOf<ClipboardMessage>()
        var blocked = false
        var fail = false
        var attempts = 0
        override suspend fun sendData(bytes: ByteArray) { attempts++; if (blocked) throw SessionBackpressure(); if (fail) throw SessionException(SessionFailure.CANCELLED); sent.add(ClipboardMessage.decode(bytes)!!) }
    }
    private class Clock {
        var time = 0L
        private val sleeps = linkedMapOf<CompletableDeferred<Unit>, Long>()
        suspend fun wait(duration: Long) {
            val wake = CompletableDeferred<Unit>(); sleeps[wake] = time + duration
            try { wake.await() } finally { sleeps.remove(wake) }
        }
        fun waitingAt(deadline: Long) = sleeps.values.contains(deadline)
        fun advance(duration: Long) {
            time += duration
            val due = sleeps.filterValues { it <= time }.keys.toList()
            due.forEach { sleeps.remove(it) }; due.forEach { it.complete(Unit) }
        }
    }
    private class Harness(dispatcher: CoroutineDispatcher) {
        val clock = Clock()
        var time: Long
            get() = clock.time
            set(value) { clock.advance(value - clock.time) }
        val native = Native()
        val owner = ClipboardController(native, dispatcher = dispatcher, now = { time }, wait = clock::wait)
        val epoch = UUID.randomUUID().toString()
        suspend fun ready(c: Channel) {
            owner.available(c)
            owner.handle(c.descriptor, ClipboardMessage.of(1, Cbor.Text(epoch), Cbor.Integer(65536), Cbor.Integer(3072)).encode())
            owner.handle(c.descriptor, ClipboardMessage.of(2, Cbor.Integer(1), Cbor.Bool(true)).encode())
        }
        suspend fun receive(c: Channel, text: String = "hello", revision: Long = 1, id: String = UUID.randomUUID().toString(), auto: Boolean = false): ClipboardMessage {
            val data = text.toByteArray(Charsets.UTF_8)
            val begin = ClipboardMessage.of(3, Cbor.Text(epoch), Cbor.Integer(revision), Cbor.Text(id), Cbor.Integer(if (auto) 1 else 0), Cbor.Bool(false), Cbor.Integer(data.size.toLong()), Cbor.Integer((data.size + 3071L) / 3072), Cbor.Bytes(MessageDigest.getInstance("SHA-256").digest(data)))
            owner.handle(c.descriptor, begin.encode())
            data.asList().chunked(3072).forEachIndexed { index, bytes -> owner.handle(c.descriptor, ClipboardMessage.of(4, Cbor.Text(id), Cbor.Integer(index.toLong()), Cbor.Bytes(bytes.toByteArray())).encode()) }
            owner.handle(c.descriptor, ClipboardMessage.id(5, id).encode())
            return begin
        }
    }
    private suspend fun until(test: () -> Boolean) { withTimeout(5000) { while (!test()) { yield(); delay(1) } } }
    @Test fun independentFixturesAndCanonicalBounds() {
        val root = JSONObject(javaClass.classLoader!!.getResource("clipboard/clipboard-vectors.json")!!.readText())
        val good = root.getJSONArray("valid"); val bad = root.getJSONArray("invalid")
        assertTrue(good.length() >= 18); assertTrue(bad.length() >= 34)
        fun hex(s: String) = s.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
        for (i in 0 until good.length()) { val bytes = hex(good.getJSONObject(i).getString("bytesHex")); assertArrayEquals(bytes, ClipboardMessage.decode(bytes)!!.encode()) }
        for (i in 0 until bad.length()) {
            val row = bad.getJSONObject(i)
            try { ClipboardMessage.decode(hex(row.getString("bytesHex"))); fail(row.getString("name")) }
            catch (_: ClipboardWireException) {} catch (_: SessionException) {}
        }
        assertNull(ClipboardMessage.decode(SessionCbor.encode(Cbor.Array(listOf(Cbor.Text("other"))))))
    }
    @Test fun duplicateAcrossTransportsAndStaleRevisionNeverOverwrite() = runBlocking {
        val h = Harness(coroutineContext[ContinuationInterceptor] as CoroutineDispatcher); val lan = Channel(); val ble = Channel("ble"); h.ready(lan); h.ready(ble)
        val begin = h.receive(lan); assertEquals(1, h.native.writes)
        h.owner.handle(ble.descriptor, begin.encode()); h.owner.handle(ble.descriptor, ClipboardMessage.id(5, begin.text(2)).encode()); yield()
        assertEquals(1, h.native.writes)
        h.receive(ble, "new", 2); h.receive(lan, "old", 1); assertEquals("new", h.native.sample!!.text); assertEquals(2, h.native.writes)
        h.owner.invalidate()
    }
    @Test fun automaticDisabledRejectsAndManualBackgroundReceiptStillWorks() = runBlocking {
        val h = Harness(coroutineContext[ContinuationInterceptor] as CoroutineDispatcher); val c = Channel(); h.ready(c)
        h.receive(c, auto = true); assertEquals(0, h.native.writes)
        h.native.focused = false; h.receive(c, revision = 2); assertEquals(1, h.native.writes)
        h.owner.invalidate()
    }
    @Test fun firstBeginConflictBaselineSurvivesRetry() = runBlocking {
        val h = Harness(coroutineContext[ContinuationInterceptor] as CoroutineDispatcher); val c = Channel(); val ble = Channel("ble"); h.ready(c); h.ready(ble)
        val begin = h.receive(c); val altered = begin.copy(fields = begin.fields.toMutableList().apply { set(1, Cbor.Integer(2)); set(2, Cbor.Text(UUID.randomUUID().toString())) })
        h.owner.handle(c.descriptor, altered.encode()); h.native.sample = ClipboardSample("new local", token = "new")
        h.owner.handle(ble.descriptor, altered.encode())
        h.owner.handle(ble.descriptor, ClipboardMessage.of(4, Cbor.Text(altered.text(2)), Cbor.Integer(0), Cbor.Bytes("hello".toByteArray())).encode())
        h.owner.handle(ble.descriptor, ClipboardMessage.id(5, altered.text(2)).encode())
        assertEquals("new local", h.native.sample!!.text); assertEquals(1, h.native.writes)
        h.owner.invalidate()
    }
    @Test fun cacheSaturationNeverEvictsUnexpiredResults() = runBlocking {
        val h = Harness(coroutineContext[ContinuationInterceptor] as CoroutineDispatcher); val c = Channel(); h.ready(c)
        val first = h.receive(c)
        for (r in 2L..32L) h.receive(c, revision = r)
        h.receive(c, revision = 33); assertEquals(32, h.native.writes)
        h.owner.handle(c.descriptor, first.encode()); h.owner.handle(c.descriptor, ClipboardMessage.id(5, first.text(2)).encode()); assertEquals(32, h.native.writes)
        h.time = 60000; h.owner.expire(); h.receive(c, revision = 34); assertEquals(33, h.native.writes)
        h.owner.invalidate()
    }
    @Test fun unicodeMaximumAndNativeWriteFailure() = runBlocking {
        val h = Harness(coroutineContext[ContinuationInterceptor] as CoroutineDispatcher); val c = Channel(); h.ready(c)
        val text = "x".repeat(3071) + "👋" + "a".repeat(65536 - 3075)
        h.receive(c, text); assertEquals(text, h.native.sample!!.text)
        h.native.fail = true; h.receive(c, "failed", 2); assertEquals(1, h.native.writes); yield()
        assertEquals(5L, c.sent.last { it.kind == 6L }.number(1)); h.owner.invalidate()
    }
    @Test fun incompleteAssemblyExpiresAndStaleGenerationIsDiscarded() = runBlocking {
        val h = Harness(coroutineContext[ContinuationInterceptor] as CoroutineDispatcher); val c = Channel(); h.ready(c)
        val old = h.receive(c)
        val begin = old.copy(fields = old.fields.toMutableList().apply { set(1, Cbor.Integer(2)); set(2, Cbor.Text(UUID.randomUUID().toString())) })
        h.owner.handle(c.descriptor, begin.encode()); h.time = 30000; h.owner.expire()
        h.owner.handle(c.descriptor, ClipboardMessage.id(5, begin.text(2)).encode()); assertEquals(1, h.native.writes)
        h.owner.retired(c.descriptor); assertEquals(DataHandling.DISCARDED, h.owner.handle(c.descriptor, old.encode())); h.owner.invalidate()
    }
    @Test fun lanSendAndOneAlternateRetryReuseLogicalId() = runBlocking {
        val h = Harness(coroutineContext[ContinuationInterceptor] as CoroutineDispatcher); val lan = Channel(); val ble = Channel("ble"); h.ready(lan); h.ready(ble); yield()
        h.owner.send(pasted = "outgoing")
        until { lan.sent.any { it.kind == 5L } }
        val first = lan.sent.first { it.kind == 3L }
        h.owner.retired(lan.descriptor)
        until { ble.sent.any { it.kind == 5L } }
        assertArrayEquals(first.encode(), ble.sent.first { it.kind == 3L }.encode())
        h.owner.handle(ble.descriptor, ClipboardMessage.result(first.text(2), 0).encode())
        until { !h.owner.busy }; assertEquals("Clipboard delivered", h.owner.status)
        h.owner.invalidate()
    }
    @Test fun blockedSendWaitsForCapacityAndCancellationOrDeadlinePreventsLateSubmission() = runBlocking {
        for (expire in listOf(false, true)) {
            val h = Harness(coroutineContext[ContinuationInterceptor] as CoroutineDispatcher); val c = Channel("ble"); h.ready(c); yield(); c.blocked = true
            h.owner.send(pasted = "blocked"); until { c.attempts > 2 && h.clock.waitingAt(30000) }; assertTrue(h.owner.busy)
            val attempts = c.attempts; repeat(10) { yield() }; assertEquals(attempts, c.attempts)
            if (expire) {
                h.clock.advance(29999); yield(); assertTrue(h.owner.busy)
                h.clock.advance(1); until { !h.owner.busy }
                assertEquals("Delivery unconfirmed", h.owner.status)
            } else h.owner.cancel()
            assertFalse(h.owner.busy); c.blocked = false; h.owner.capacityAvailable(c.descriptor); yield()
            assertTrue(c.sent.none { it.kind == 3L }); h.owner.invalidate()
            until { !h.clock.waitingAt(30000) }
        }
    }
    @Test fun preferencesAreCredentialScopedAndPruned() {
        val prefs = ClipboardPreferences(); val a = Channel().descriptor.peer; val b = a.copy(fingerprint = "new")
        assertFalse(prefs.enabled(a)); prefs.set(a, true); assertFalse(prefs.enabled(b))
        prefs.prune(listOf(b)); assertFalse(prefs.enabled(a)); prefs.set(b, true); prefs.clear(); assertFalse(prefs.enabled(b))
    }
    @Test fun automaticReadsOnlyWithFocusAndNeverEchoesRemoteOrSensitiveClips() = runBlocking {
        val h = Harness(coroutineContext[ContinuationInterceptor] as CoroutineDispatcher); val c = Channel(); h.ready(c); yield()
        h.owner.setAutomaticEnabled(true); assertFalse(h.owner.busy)
        h.owner.focus(true); until { c.sent.any { it.kind == 5L } }
        val id = c.sent.first { it.kind == 3L }.text(2)
        h.owner.handle(c.descriptor, ClipboardMessage.result(id, 0).encode()); until { !h.owner.busy }
        val count = c.sent.count { it.kind == 3L }
        h.native.sample = ClipboardSample("secret", sensitive = true, token = "secret")
        h.native.observer?.invoke(); yield(); assertFalse(h.owner.busy)
        h.native.sample = ClipboardSample("remote", excluded = true, token = "remote")
        h.owner.focus(false); assertNull(h.native.observer); h.owner.focus(true); yield()
        assertEquals(count, c.sent.count { it.kind == 3L }); h.owner.invalidate()
    }
    @Test fun manualPreparationSurvivesAutomaticCopiesAndOnlyLatestPendingFollows() = runBlocking {
        val h = Harness(coroutineContext[ContinuationInterceptor] as CoroutineDispatcher); val c = Channel(); h.ready(c); yield()
        h.native.sample = ClipboardSample("remote", excluded = true, token = "remote")
        h.owner.focus(true); h.owner.setAutomaticEnabled(true)
        h.owner.send(pasted = "manual")
        h.native.sample = ClipboardSample("discarded", token = "2"); h.native.observer?.invoke()
        h.native.sample = ClipboardSample("latest", token = "3"); h.native.observer?.invoke()
        until { c.sent.any { it.kind == 5L } }
        val first = c.sent.first { it.kind == 3L }; assertEquals(0L, first.number(3))
        h.owner.handle(c.descriptor, ClipboardMessage.result(first.text(2), 0).encode())
        until { c.sent.count { it.kind == 5L } == 2 }
        assertEquals(listOf("manual", "latest"), c.sent.filter { it.kind == 4L }.map { String(it.bytes(2), Charsets.UTF_8) })
        h.owner.invalidate()
    }
    @Test fun missingAcknowledgementRetriesExactlyOnceWithoutNewConnection() = runBlocking {
        val h = Harness(coroutineContext[ContinuationInterceptor] as CoroutineDispatcher); val lan = Channel(); val ble = Channel("ble"); h.ready(lan); h.ready(ble); yield()
        h.owner.send(pasted = "lost ack")
        until { h.clock.waitingAt(2000) }
        h.clock.advance(1999); yield(); assertTrue(ble.sent.none { it.kind == 3L }); assertTrue(h.owner.busy)
        h.clock.advance(1)
        until { ble.sent.any { it.kind == 5L } && h.clock.waitingAt(4000) }
        h.clock.advance(2000); until { !h.owner.busy }
        assertEquals(1, lan.sent.count { it.kind == 3L }); assertEquals(1, ble.sent.count { it.kind == 3L })
        assertEquals("Delivery unconfirmed", h.owner.status); h.owner.invalidate()
    }
    @Test fun cacheSurvivesChannelReplacementAndConflictingDuplicateMetadataIsRejected() = runBlocking {
        val h = Harness(coroutineContext[ContinuationInterceptor] as CoroutineDispatcher); val c = Channel(); h.ready(c)
        val begin = h.receive(c)
        val conflict = begin.copy(fields = begin.fields.toMutableList().apply { set(4, Cbor.Bool(true)) })
        assertEquals(DataHandling.DISCARDED, h.owner.handle(c.descriptor, conflict.encode()))
        h.owner.retired(c.descriptor); val replacement = Channel(); h.ready(replacement)
        h.owner.handle(replacement.descriptor, begin.encode()); h.owner.handle(replacement.descriptor, ClipboardMessage.id(5, begin.text(2)).encode())
        assertEquals(1, h.native.writes); h.owner.invalidate()
    }
    @Test fun invalidUtf8AndNulNeverWrite() = runBlocking {
        val h = Harness(coroutineContext[ContinuationInterceptor] as CoroutineDispatcher); val c = Channel(); h.ready(c)
        for ((index, data) in listOf(byteArrayOf(0xff.toByte()), byteArrayOf(0)).withIndex()) {
            val id = UUID.randomUUID().toString()
            val begin = ClipboardMessage.of(3, Cbor.Text(h.epoch), Cbor.Integer(index + 1L), Cbor.Text(id), Cbor.Integer(0), Cbor.Bool(false), Cbor.Integer(1), Cbor.Integer(1), Cbor.Bytes(MessageDigest.getInstance("SHA-256").digest(data)))
            h.owner.handle(c.descriptor, begin.encode()); h.owner.handle(c.descriptor, ClipboardMessage.of(4, Cbor.Text(id), Cbor.Integer(0), Cbor.Bytes(data)).encode()); h.owner.handle(c.descriptor, ClipboardMessage.id(5, id).encode())
        }
        assertEquals(0, h.native.writes); h.owner.invalidate()
    }

    @Test fun stoppingOldWindowDoesNotRevokeNewWindowFocus() = runBlocking {
        val h = Harness(coroutineContext[ContinuationInterceptor] as CoroutineDispatcher); val c = Channel(); h.ready(c); yield()
        h.native.sample = ClipboardSample("remote", excluded = true, token = "remote")
        h.owner.setAutomaticEnabled(true)
        val old = Any(); val newer = Any()
        h.owner.focus(true, old); h.owner.focus(true, newer); h.owner.focus(false, old)
        assertNotNull(h.native.observer)
        h.owner.focus(false, newer); assertNull(h.native.observer); h.owner.invalidate()
    }

    @Test fun invalidUtf16AndOversizedUtf8AreRejectedWithoutTruncation() = runBlocking {
        val h = Harness(coroutineContext[ContinuationInterceptor] as CoroutineDispatcher); val c = Channel(); h.ready(c); yield()
        h.owner.send(pasted = charArrayOf(0xd800.toChar()).concatToString()); until { !h.owner.busy }
        h.owner.send(pasted = "é".repeat(32769)); until { !h.owner.busy }
        h.owner.send(pasted = ""); assertFalse(h.owner.busy)
        assertTrue(c.sent.none { it.kind == 3L }); h.owner.invalidate()
    }

    @Test fun disablingAutomaticWhilePreparingImmediatelyReleasesSendAndManualStillWorks() = runBlocking {
        val h = Harness(coroutineContext[ContinuationInterceptor] as CoroutineDispatcher); val c = Channel(); h.ready(c); yield()
        h.owner.focus(true); h.owner.setAutomaticEnabled(true); assertTrue(h.owner.busy)
        h.owner.setAutomaticEnabled(false); assertFalse(h.owner.busy)
        h.owner.send(pasted = "manual after disabling"); h.owner.focus(false)
        until { c.sent.any { it.kind == 5L } }
        assertEquals(listOf("manual after disabling"), c.sent.filter { it.kind == 4L }.map { String(it.bytes(2), Charsets.UTF_8) })
        h.owner.invalidate()
    }

    @Test fun validMessagesInInvalidStatesNeverWriteOrPoisonNextItem() = runBlocking {
        val scenarios = listOf("commit-before-begin", "fragment-before-begin", "incomplete-commit", "index-outside-item", "out-of-order", "conflicting-fragment", "digest-mismatch", "cancelled-item")
        assertEquals(8, scenarios.size)
        for (scenario in scenarios) {
            val h = Harness(coroutineContext[ContinuationInterceptor] as CoroutineDispatcher); val c = Channel(); h.ready(c)
            val id = UUID.randomUUID().toString(); val text = if (scenario == "out-of-order") "x".repeat(3073) else "hello"
            val bytes = text.toByteArray()
            val begin = ClipboardMessage.of(3, Cbor.Text(h.epoch), Cbor.Integer(1), Cbor.Text(id), Cbor.Integer(0), Cbor.Bool(false), Cbor.Integer(bytes.size.toLong()), Cbor.Integer((bytes.size + 3071L) / 3072), Cbor.Bytes(MessageDigest.getInstance("SHA-256").digest(bytes)))
            suspend fun feed(m: ClipboardMessage) = h.owner.handle(c.descriptor, m.encode())
            fun fragment(index: Long, text: String) = ClipboardMessage.of(4, Cbor.Text(id), Cbor.Integer(index), Cbor.Bytes(text.toByteArray()))
            if (scenario.endsWith("before-begin")) {
                assertEquals(scenario, DataHandling.DISCARDED, feed(if (scenario.startsWith("commit")) ClipboardMessage.id(5, id) else fragment(0, "hello")))
            } else {
                feed(begin)
                when (scenario) {
                    "index-outside-item" -> feed(fragment(1, "hello"))
                    "out-of-order" -> feed(fragment(1, "x"))
                    "conflicting-fragment" -> { feed(fragment(0, "hello")); feed(fragment(0, "world")) }
                    "digest-mismatch" -> feed(fragment(0, "world"))
                    "cancelled-item" -> { feed(ClipboardMessage.id(7, id)); feed(fragment(0, "hello")) }
                }
                feed(ClipboardMessage.id(5, id)); yield()
                assertEquals(scenario, if (scenario == "cancelled-item") 7L else 6L, c.sent.last { it.kind == 6L }.number(1))
            }
            assertEquals(scenario, 0, h.native.writes); assertEquals(scenario, "local", h.native.sample!!.text)
            h.receive(c, text = "fresh after rejection", revision = 2)
            assertEquals(scenario, "fresh after rejection", h.native.sample!!.text); assertEquals(scenario, 1, h.native.writes)
            h.owner.invalidate()
        }
    }
    @Test fun unknownUnattemptedStaleAndCancelledResultsCannotFinishAnotherSend() = runBlocking {
        val h = Harness(coroutineContext[ContinuationInterceptor] as CoroutineDispatcher); val lan = Channel(); val ble = Channel("ble"); h.ready(lan); h.ready(ble); yield()
        h.owner.send(pasted = "first"); until { lan.sent.any { it.kind == 5L } }
        val first = lan.sent.first { it.kind == 3L }.text(2)
        val applied = ClipboardMessage.result(first, 0).encode()
        assertEquals(DataHandling.DISCARDED, h.owner.handle(lan.descriptor, ClipboardMessage.result(UUID.randomUUID().toString(), 0).encode()))
        assertEquals(DataHandling.DISCARDED, h.owner.handle(ble.descriptor, applied))
        assertEquals(DataHandling.DISCARDED, h.owner.handle(lan.descriptor.copy(instance = "stale"), applied))
        assertTrue(h.owner.busy)
        h.owner.cancel(); assertEquals(DataHandling.DISCARDED, h.owner.handle(lan.descriptor, applied))
        h.owner.send(pasted = "second"); until { lan.sent.count { it.kind == 5L } == 2 }
        assertEquals(DataHandling.DISCARDED, h.owner.handle(lan.descriptor, applied)); assertTrue(h.owner.busy)
        val current = lan.sent.last { it.kind == 3L }.text(2)
        h.owner.handle(lan.descriptor, ClipboardMessage.result(current, 0).encode()); until { !h.owner.busy }
        assertEquals("Clipboard delivered", h.owner.status); h.owner.invalidate()
    }

    @Test fun openingBeforeClipboardHandshakeSamplesOnceWhenReadyAndNeverAfterFocusLoss() = runBlocking {
        for (blockedAnnouncement in listOf(false, true)) {
            val h = Harness(coroutineContext[ContinuationInterceptor] as CoroutineDispatcher); val c = Channel()
            h.owner.select(c.descriptor.peer); h.owner.setAutomaticEnabled(true)
            h.owner.focus(true)
            c.blocked = blockedAnnouncement
            h.ready(c); yield()
            if (blockedAnnouncement) { assertTrue(c.sent.none { it.kind == 3L }); c.blocked = false; h.owner.capacityAvailable(c.descriptor) }
            until { c.sent.any { it.kind == 5L } }
            assertEquals(listOf("local"), c.sent.filter { it.kind == 4L }.map { String(it.bytes(2), Charsets.UTF_8) })
            val id = c.sent.first { it.kind == 3L }.text(2)
            h.owner.handle(c.descriptor, ClipboardMessage.result(id, 0).encode()); until { !h.owner.busy }
            h.owner.retired(c.descriptor)
            h.native.sample = ClipboardSample("later copy", token = "later")
            val replacement = Channel(); h.ready(replacement); repeat(10) { yield() }
            assertTrue(replacement.sent.none { it.kind == 3L }); assertFalse(h.owner.busy)
            h.owner.invalidate()
        }
        val h = Harness(coroutineContext[ContinuationInterceptor] as CoroutineDispatcher); val c = Channel()
        h.owner.select(c.descriptor.peer); h.owner.setAutomaticEnabled(true); h.owner.focus(true); h.owner.focus(false)
        h.ready(c); repeat(10) { yield() }
        assertFalse(h.owner.busy); assertTrue(c.sent.none { it.kind == 3L }); assertNull(h.native.observer); assertEquals(0, h.native.reads)
        h.owner.invalidate()
    }

}
