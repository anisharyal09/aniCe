// SPDX-License-Identifier: GPL-3.0-or-later
// Exercises fresh LAN epochs, ordered drain barriers and retirement races without replacing their transport owner.
package io.github.anisharyal09.anice.infrastructure.session

import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

class LanRenewalTests {
    private class Pairing(
        clientRenewal: Boolean = true,
        serverRenewal: Boolean = true,
        private val clientFactory: (suspend () -> Unit)? = null,
    ) {
        val clock = AtomicLong()
        val helper = SessionTests()
        val fixture = helper.root().getJSONArray("valid").getJSONObject(0)
        val outgoing = ConcurrentLinkedQueue<ByteArray>()
        val replies = ConcurrentLinkedQueue<ByteArray>()
        val historyI = mutableListOf<ByteArray>()
        val historyR = mutableListOf<ByteArray>()
        val dataI = mutableListOf<ByteArray>()
        val dataR = mutableListOf<ByteArray>()
        val securedI = AtomicInteger()
        val securedR = AtomicInteger()
        val factoriesI = AtomicInteger()
        val factoriesR = AtomicInteger()
        var hold: (suspend (ByteArray) -> Unit)? = null
        var replyHold: (suspend (ByteArray) -> Unit)? = null
        val client = SessionConnection(helper.freshEngine(fixture, false, clock::get), false,
            { true }, { bytes -> hold?.invoke(bytes); historyI.add(bytes); outgoing.add(bytes) },
            { dataI.add(it) }, { securedI.incrementAndGet() }, controls = true, now = clock::get,
            renew = true, profile = SessionProfile.LAN_TRANSFER_512,
            renewalHandshake = if (!clientRenewal) null else {
                { factoriesI.incrementAndGet(); clientFactory?.invoke(); helper.freshEngine(fixture, false, clock::get) }
            })
        val server = SessionConnection(helper.freshEngine(fixture, true, clock::get), true,
            { true }, { historyR.add(it); replies.add(it); replyHold?.invoke(it) }, { dataR.add(it) }, { securedR.incrementAndGet() },
            controls = true, now = clock::get, renew = serverRenewal, profile = SessionProfile.LAN_TRANSFER_512,
            renewalHandshake = if (!serverRenewal) null else {
                { factoriesR.incrementAndGet(); helper.freshEngine(fixture, true, clock::get) }
            })
        suspend fun pump() {
            repeat(128) {
                if (outgoing.isEmpty() && replies.isEmpty()) return
                outgoing.poll()?.let { server.receive(it) }
                replies.poll()?.let { client.receive(it) }
            }
            fail("Unbounded renewal exchange")
        }
        suspend fun ready() { client.start(); pump() }
        suspend fun age() {
            repeat(54) { clock.addAndGet(60000); client.tick(); server.tick(); pump() }
            clock.addAndGet(60000)
        }
        suspend fun close() { client.close(); server.close() }
    }

    @Test fun independentRenewalFixturesAndBleOnlyDispatchCompatibility() {
        val rows = org.json.JSONObject(requireNotNull(javaClass.classLoader!!.getResourceAsStream("lan/renewal-vectors.json"))
            .bufferedReader().use { it.readText() })
        val valid = rows.getJSONArray("valid"); val invalid = rows.getJSONArray("invalid")
        assertTrue(valid.length() >= 4); assertTrue(invalid.length() >= 20)
        fun bytes(row: org.json.JSONObject) = row.getString("payloadHex").chunked(2).map { it.toInt(16).toByte() }.toByteArray()
        repeat(valid.length()) {
            val wire = bytes(valid.getJSONObject(it))
            assertArrayEquals(wire, LanRenewalControl.decode(wire).encode())
            assertNull(SessionControl.application(wire))
            assertTrue(SessionControl.classifyApplication(wire, 4096, true) is ApplicationControl.LanRenewal)
        }
        repeat(invalid.length()) {
            val row = invalid.getJSONObject(it)
            try { LanRenewalControl.decode(bytes(row)); fail("Accepted ${row.getString("name")}") }
            catch (error: SessionException) {
                assertEquals(if (row.getString("reason") == "unsupportedProfile") SessionFailure.UNSUPPORTED_PROFILE
                    else SessionFailure.MALFORMED, error.reason)
            }
        }
    }

    @Test fun consecutiveFreshEpochsKeepTheOwnerAndApplicationReadinessCallback() = runBlocking {
        val pair = Pairing()
        try {
            pair.ready()
            repeat(3) { cycle ->
                pair.client.sendData(byteArrayOf(cycle.toByte(), 7))
                pair.server.sendData(byteArrayOf(cycle.toByte(), 9))
                pair.pump()
                pair.age()
                pair.server.tick(); pair.client.tick()
                assertTrue(pair.client.isRenewing); assertTrue(pair.server.isRenewing)
                assertFalse(pair.client.applicationAvailable)
                try { pair.client.sendData(byteArrayOf(42)); fail("DATA escaped renewal") }
                catch (_: SessionBackpressure) {}
                pair.clock.addAndGet(50)
                pair.pump()
                assertFalse(pair.client.isRenewing); assertFalse(pair.server.isRenewing)
                assertTrue(pair.client.applicationAvailable)
                assertEquals(1, pair.securedI.get()); assertEquals(1, pair.securedR.get())
                assertEquals(cycle + 1, pair.factoriesI.get()); assertEquals(cycle + 1, pair.factoriesR.get())
                assertEquals((cycle + 1) * 50L, pair.client.maintenanceSnapshot.elapsedMillis)
            }
            assertEquals(3, pair.dataI.size); assertEquals(3, pair.dataR.size)
            repeat(3) {
                assertArrayEquals(byteArrayOf(it.toByte(), 9), pair.dataI[it])
                assertArrayEquals(byteArrayOf(it.toByte(), 7), pair.dataR[it])
            }
            val starts = pair.historyI.filter { it[0] == 1.toByte() }
            assertEquals(4, starts.size)
            for (i in starts.indices) for (j in 0 until i) assertFalse(starts[i].contentEquals(starts[j]))
            for (history in listOf(pair.historyI, pair.historyR)) {
                val ready = history.filter { it[0] == 6.toByte() && it[2].toInt() in 1..2 }
                assertEquals(4, ready.size)
                ready.forEach { assertTrue(it.sliceArray(3..10).all { byte -> byte == 0.toByte() }) }
                for (i in ready.indices) for (j in 0 until i) assertFalse(ready[i].contentEquals(ready[j]))
            }
        } finally { pair.close() }
    }

    @Test fun absentPeerCapabilityNeverStartsInBandHandshake() = runBlocking {
        val pair = Pairing(serverRenewal = false)
        try {
            pair.ready(); pair.age(); pair.client.tick(); pair.server.tick(); pair.pump()
            assertFalse(pair.client.isRenewing)
            assertEquals(0, pair.factoriesI.get()); assertEquals(0, pair.factoriesR.get())
            pair.client.sendData(byteArrayOf(7)); pair.pump()
            assertFalse(pair.client.isClosed)
            pair.clock.set(3600000)
            try { pair.client.tick(); fail("Legacy peer extended hard lifetime") }
            catch (error: SessionException) { assertEquals(SessionFailure.EXPIRED, error.reason) }
            assertEquals(SessionExpiry.LIFETIME, pair.client.expiration)
        } finally { pair.close() }
    }

    @Test fun recordMarginRequestsCoalesceIntoOneFreshEpoch() = runBlocking {
        val pair = Pairing()
        try {
            pair.ready()
            repeat(2) { pair.server.sendData(SessionControl(ControlKind.RENEWAL_REQUEST, 2).encode()) }
            pair.pump()
            assertEquals(1, pair.factoriesI.get()); assertEquals(1, pair.factoriesR.get())
            assertFalse(pair.client.isRenewing)
            assertEquals(1, pair.securedI.get())
        } finally { pair.close() }
    }

    @Test fun oldCiphertextIsRejectedEvenAtTheSuccessorExpectedSequence() = runBlocking {
        val pair = Pairing()
        try {
            pair.ready()
            pair.server.sendData(byteArrayOf(7))
            val old = requireNotNull(pair.replies.peek()).copyOf()
            assertEquals(3.toByte(), old[10])
            pair.pump(); pair.age(); pair.client.tick(); pair.pump()
            try { pair.client.receive(old); fail("Old ciphertext authenticated under successor keys") }
            catch (error: SessionException) { assertEquals(SessionFailure.AUTHENTICATION, error.reason) }
            assertTrue(pair.client.isClosed)
            assertEquals(1, pair.dataI.size)
        } finally { pair.close() }
    }

    @Test fun quiescenceAndHardLifetimeRemainAbsolute() = runBlocking {
        for (hard in listOf(false, true)) {
            val pair = Pairing()
            try {
                pair.ready(); pair.age(); pair.client.tick()
                assertTrue(pair.client.isRenewing)
                pair.clock.set(if (hard) 3600000 else 3310000)
                try { pair.client.checkDeadlines(); fail("Renewal extended its deadline") }
                catch (error: SessionException) {
                    assertEquals(if (hard) SessionFailure.EXPIRED else SessionFailure.CONTROL_TIMEOUT, error.reason)
                }
                assertTrue(pair.client.isClosed)
            } finally { pair.close() }
        }
    }

    @Test fun wrongRoleAndUnsolicitedDrainAreFatal() = runBlocking {
        for (kind in listOf(2, 3)) {
            val pair = Pairing()
            try {
                pair.ready()
                pair.server.sendData(LanRenewalControl(kind, ByteArray(16) { 1 }).encode())
                try { pair.pump(); fail("Unsolicited/role-invalid renewal accepted") }
                catch (error: SessionException) { assertEquals(SessionFailure.STATE, error.reason) }
                assertTrue(pair.client.isClosed)
                assertTrue(pair.dataI.isEmpty())
            } finally { pair.close() }
        }
    }

    @Test fun sealedOldWriteFinishesBeforeBeginAndNoApplicationDataIsLost() = runBlocking {
        val pair = Pairing()
        val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        try {
            pair.ready(); pair.age()
            val payload = ByteArray(65536) { 7 }
            pair.hold = { bytes -> if (bytes.size > 60000) { entered.complete(Unit); release.await() } }
            val old = async { pair.client.sendData(payload) }
            withTimeout(1000) { entered.await() }
            pair.client.tick()
            assertTrue(pair.client.isRenewing)
            assertTrue(pair.outgoing.isEmpty())
            pair.hold = null; release.complete(Unit)
            withTimeout(1000) { old.await() }
            pair.client.tick(); pair.pump()
            assertFalse(pair.client.isRenewing)
            assertArrayEquals(payload, pair.dataR.single())
            assertEquals(1, pair.factoriesI.get()); assertEquals(1, pair.factoriesR.get())
            assertFalse(pair.client.isClosed); assertFalse(pair.server.isClosed)
        } finally { release.complete(Unit); pair.close() }
    }

    @Test fun stopAndHandshakeDeadlineFenceASuspendedSuccessorFactory() = runBlocking {
        for (expired in listOf(false, true)) {
            val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
            val pair = Pairing(clientFactory = { entered.complete(Unit); release.await() })
            try {
                pair.ready(); pair.age(); pair.client.tick()
                pair.server.receive(requireNotNull(pair.outgoing.poll()))
                val receive = async {
                    try { pair.client.receive(requireNotNull(pair.replies.poll())); null }
                    catch (error: SessionException) { error.reason }
                }
                withTimeout(1000) { entered.await() }
                assertEquals(3330000L, pair.client.nextDeadline(includeMaintenance = false))
                if (expired) {
                    pair.clock.set(3330000)
                    try { pair.client.checkDeadlines(); fail("Suspended factory extended handshake") }
                    catch (error: SessionException) { assertEquals(SessionFailure.EXPIRED, error.reason) }
                } else pair.client.retire()
                assertTrue(pair.client.isClosed)
                release.complete(Unit)
                assertEquals(SessionFailure.CANCELLED, withTimeout(1000) { receive.await() })
                assertEquals(1, pair.historyI.count { it[0] == 1.toByte() })
            } finally { release.complete(Unit); pair.close() }
        }
    }

    @Test fun peerReceiptCannotSwapKeysBeforeDrainSubmissionFinishes() = runBlocking {
        val pair = Pairing()
        val oldEntered = CompletableDeferred<Unit>(); val oldRelease = CompletableDeferred<Unit>()
        val ackEntered = CompletableDeferred<Unit>(); val ackRelease = CompletableDeferred<Unit>()
        try {
            pair.ready(); pair.age()
            pair.replyHold = { if (it.size > 60000) { oldEntered.complete(Unit); oldRelease.await() } }
            val oldWrite = async { pair.server.sendData(ByteArray(65536) { 7 }) }
            withTimeout(1000) { oldEntered.await() }
            pair.client.tick()
            pair.server.receive(requireNotNull(pair.outgoing.poll()))
            oldRelease.complete(Unit)
            withTimeout(1000) { oldWrite.await() }
            pair.client.receive(requireNotNull(pair.replies.poll()))
            val ackSize = LanRenewalControl(3, ByteArray(16)).encode().size + 31
            pair.replyHold = { if (it.size == ackSize) { ackEntered.complete(Unit); ackRelease.await() } }
            val drain = async { pair.server.tick() }
            withTimeout(1000) { ackEntered.await() }
            pair.client.receive(requireNotNull(pair.replies.poll()))
            val message1 = requireNotNull(pair.outgoing.poll())
            assertEquals(1.toByte(), message1[0])
            val receiving = async { pair.server.receive(message1) }
            yield()
            assertEquals(0, pair.factoriesR.get())
            assertFalse(pair.server.isClosed)
            ackRelease.complete(Unit)
            withTimeout(1000) { drain.await(); receiving.await() }
            pair.replyHold = null
            pair.pump()
            assertEquals(1, pair.factoriesR.get())
            assertFalse(pair.client.isClosed); assertFalse(pair.server.isClosed)
            assertEquals(1, pair.dataI.size)
        } finally { oldRelease.complete(Unit); ackRelease.complete(Unit); pair.close() }
    }
}
