// SPDX-License-Identifier: GPL-3.0-or-later
// Tests control oracle fixtures, compatibility, ping ordering and encrypted renewal failures.
package io.github.anisharyal09.anice.infrastructure.session

import io.github.anisharyal09.anice.infrastructure.lan.LanQueueBudget
import io.github.anisharyal09.anice.infrastructure.connections.ConnectionState
import io.github.anisharyal09.anice.infrastructure.connections.retainForegroundSession
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test

class SessionControlTests {
  @Test fun pendingPongSurvivesLegalBulkSubmissionWithoutExtraQueueSlots() = runBlocking {
    val helper = SessionTests()
    val fixture = helper.root().getJSONArray("valid").getJSONObject(0)
    for (profile in listOf(SessionProfile.STANDARD, SessionProfile.LAN_TRANSFER)) {
      var clock = 0L
      var hold = false
      val entered = CompletableDeferred<Unit>()
      val release = CompletableDeferred<Unit>()
      val outgoing = java.util.ArrayDeque<ByteArray>()
      val replies = java.util.ArrayDeque<ByteArray>()
      val budget = LanQueueBudget(profile)
      val client = SessionConnection(helper.engine(fixture, false), false, { true }, { outgoing.add(it) },
        {}, {}, controls = true, now = { clock }, profile = profile)
      val server = SessionConnection(helper.engine(fixture, true), true,
        { synchronized(budget) { budget.canReserve(it) } }, { bytes ->
          synchronized(budget) { budget.reserve(bytes.size) }
          try {
            if (hold) { entered.complete(Unit); release.await() }
            replies.add(bytes)
          } finally { synchronized(budget) { budget.release(bytes.size) } }
        }, {}, {}, controls = true, now = { clock }, profile = profile)
      suspend fun pump() {
        repeat(32) {
          if (outgoing.isEmpty() && replies.isEmpty()) return
          if (outgoing.isNotEmpty()) server.receive(outgoing.removeFirst())
          if (replies.isNotEmpty()) client.receive(replies.removeFirst())
        }
        fail("Unbounded control exchange")
      }
      try {
        client.start(); pump()
        assertEquals(true, client.controlSupport); assertEquals(true, server.controlSupport)
        clock = 59000; hold = true
        val bulk = async { server.sendData(ByteArray(profile.maximumPlaintext)) }
        withTimeout(1000) { entered.await() }
        assertEquals(1, synchronized(budget) { budget.messages })
        clock = 60000; client.tick(); server.receive(outgoing.removeFirst())
        assertEquals(80000L, client.nextDeadline())
        server.tick()
        assertTrue("PONG cannot overtake the active sealed send", replies.isEmpty())
        assertEquals("Spare legal slots cannot bypass the send serializer", 1, synchronized(budget) { budget.messages })
        // Complete within the transport's existing absolute ten-second write bound.
        clock = 68000; hold = false; release.complete(Unit)
        withTimeout(1000) { bulk.await() }
        server.tick(); pump()
        assertEquals(0, synchronized(budget) { budget.messages })
        assertEquals(128000L, client.nextDeadline())
        clock = 80000; client.checkDeadlines()
        assertFalse(client.isClosed); assertFalse(server.isClosed)
      } finally { release.complete(Unit); client.close(); server.close() }
    }
  }

  @Test fun cancellingUnsealedFeatureSendKeepsSessionAndNonceOrderIntact() = runBlocking {
    val helper = SessionTests()
    val fixture = helper.root().getJSONArray("valid").getJSONObject(0)
    val outgoing = java.util.ArrayDeque<ByteArray>()
    val replies = java.util.ArrayDeque<ByteArray>()
    val delivered = mutableListOf<ByteArray>()
    val entered = CompletableDeferred<Unit>()
    val release = CompletableDeferred<Unit>()
    var hold = false
    val client = SessionConnection(helper.engine(fixture, false), false, { true }, {
      if (hold) { entered.complete(Unit); release.await() }
      outgoing.add(it)
    }, {}, {})
    val server = SessionConnection(helper.engine(fixture, true), true, { true }, { replies.add(it) },
      { delivered.add(it) }, {})
    try {
      client.start()
      repeat(3) { server.receive(outgoing.removeFirst()); client.receive(replies.removeFirst()) }
      hold = true
      val active = async(start = CoroutineStart.UNDISPATCHED) { client.sendData(byteArrayOf(1)) }
      withTimeout(1000) { entered.await() }
      val cancelled = async(start = CoroutineStart.UNDISPATCHED) { client.sendData(byteArrayOf(2)) }
      cancelled.cancelAndJoin()
      assertFalse(client.isClosed)
      hold = false; release.complete(Unit); withTimeout(1000) { active.await() }
      client.sendData(byteArrayOf(3))
      assertEquals("Cancellation must emit no record or consume its nonce", 2, outgoing.size)
      while (outgoing.isNotEmpty()) server.receive(outgoing.removeFirst())
      assertEquals(2, delivered.size)
      assertArrayEquals(byteArrayOf(1), delivered[0]); assertArrayEquals(byteArrayOf(3), delivered[1])
      assertFalse(client.isClosed); assertFalse(server.isClosed)
    } finally { release.complete(Unit); client.close(); server.close() }
  }

  @Test fun concurrentFeatureSendsWaitBeforeSealingAndPreserveNonceOrder() = runBlocking {
    val helper = SessionTests()
    val fixture = helper.root().getJSONArray("valid").getJSONObject(0)
    val outgoing = java.util.ArrayDeque<ByteArray>()
    val replies = java.util.ArrayDeque<ByteArray>()
    val delivered = mutableListOf<ByteArray>()
    val entered = CompletableDeferred<Unit>()
    val release = CompletableDeferred<Unit>()
    var hold = false
    val client = SessionConnection(helper.engine(fixture, false), false, { true }, {
      if (hold) { entered.complete(Unit); release.await() }
      outgoing.add(it)
    }, {}, {})
    val server = SessionConnection(helper.engine(fixture, true), true, { true }, { replies.add(it) },
      { delivered.add(it) }, {})
    try {
      client.start()
      repeat(3) { server.receive(outgoing.removeFirst()); client.receive(replies.removeFirst()) }
      hold = true
      val bulk = async(start = CoroutineStart.UNDISPATCHED) { client.sendData(byteArrayOf(1)) }
      withTimeout(1000) { entered.await() }
      val control = async(start = CoroutineStart.UNDISPATCHED) { client.sendData(byteArrayOf(2)) }
      assertFalse("Concurrent feature must wait, rather than lose admission", control.isCompleted)
      hold = false; release.complete(Unit)
      withTimeout(1000) { bulk.await(); control.await() }
      assertEquals(2, outgoing.size)
      while (outgoing.isNotEmpty()) server.receive(outgoing.removeFirst())
      assertEquals(2, delivered.size)
      assertArrayEquals(byteArrayOf(1), delivered[0]); assertArrayEquals(byteArrayOf(2), delivered[1])
      assertFalse(client.isClosed); assertFalse(server.isClosed)
    } finally { release.complete(Unit); client.close(); server.close() }
  }

  @Test fun dataAdmissionPrioritizesControlsWithoutStarvingBulk() = runBlocking {
    val admission = SessionDataAdmission()
    val release = CompletableDeferred<Unit>()
    val order = mutableListOf<Int>()
    val first = async(start = CoroutineStart.UNDISPATCHED) {
      admission.run(true) { order.add(0); release.await() }
    }
    val pending = (1..8).map { index ->
      async(start = CoroutineStart.UNDISPATCHED) {
        admission.run(index == 1 || index == 8) { order.add(index) }
      }
    }
    assertEquals(8, admission.pendingCount)
    try { admission.run(false) { fail("Over-capacity work ran") }; fail("Unbounded admission") }
    catch (_: SessionBackpressure) {}
    release.complete(Unit)
    withTimeout(1000) { first.await(); pending.awaitAll() }
    assertEquals(listOf(0, 2, 3, 4, 5, 1, 6, 7, 8), order)
    assertEquals(0, admission.pendingCount)
  }

  @Test fun dataAdmissionCancellationAndRetirementReleaseEveryWaiter() = runBlocking {
    supervisorScope {
      val admission = SessionDataAdmission()
      val release = CompletableDeferred<Unit>()
      val active = async(start = CoroutineStart.UNDISPATCHED) { admission.run(true) { release.await() } }
      val cancelled = async(start = CoroutineStart.UNDISPATCHED) {
        admission.run(false) { fail("Cancelled work ran") }
      }
      cancelled.cancelAndJoin()
      assertEquals(0, admission.pendingCount)
      val waiting = (1..8).map {
        async(start = CoroutineStart.UNDISPATCHED) { admission.run(false) { fail("Retired work ran") } }
      }
      admission.close()
      waiting.forEach {
        try { it.await(); fail("Retired waiter succeeded") }
        catch (e: SessionException) { assertEquals(SessionFailure.CANCELLED, e.reason) }
      }
      assertEquals(0, admission.pendingCount)
      release.complete(Unit); active.await()
      try { admission.run(false) { fail("Closed admission reopened") }; fail("Closed admission succeeded") }
      catch (e: SessionException) { assertEquals(SessionFailure.CANCELLED, e.reason) }
    }
  }

  @Test fun cancellationRacingAdmissionCannotStrandTheNextProducer() = runBlocking {
    repeat(64) {
      val admission = SessionDataAdmission()
      val release = CompletableDeferred<Unit>()
      val active = async(start = CoroutineStart.UNDISPATCHED) { admission.run(true) { release.await() } }
      val waiting = async(start = CoroutineStart.UNDISPATCHED) { admission.run(false) {} }
      release.complete(Unit); waiting.cancel()
      withTimeout(1000) { active.await(); waiting.cancelAndJoin(); admission.run(false) {} }
      assertEquals(0, admission.pendingCount)
    }
  }

  @Test fun applicationSendCannotRaceAControlCapacityPreflight() = runBlocking {
    val helper = SessionTests()
    val fixture = helper.root().getJSONArray("valid").getJSONObject(0)
    val outgoing = java.util.ArrayDeque<ByteArray>()
    val replies = java.util.ArrayDeque<ByteArray>()
    val delivered = mutableListOf<ByteArray>()
    val entered = CompletableDeferred<Unit>()
    val release = CompletableDeferred<Unit>()
    var hold = false
    var preflights = 0
    val client = SessionConnection(helper.engine(fixture, false), false, {
      if (hold) {
        preflights++
        if (!entered.isCompleted) { entered.complete(Unit); release.await() }
      }
      true
    }, { outgoing.add(it) }, {}, {}, true)
    val server = SessionConnection(helper.engine(fixture, true), true, { true }, { replies.add(it) },
      { delivered.add(it) }, {}, true)
    try {
      client.start()
      server.receive(outgoing.removeFirst())
      client.receive(replies.removeFirst())
      server.receive(outgoing.removeFirst())
      client.receive(replies.removeFirst())
      server.receive(outgoing.removeFirst())
      hold = true
      val ready = async(start = CoroutineStart.UNDISPATCHED) { client.receive(replies.removeFirst()) }
      withTimeout(1000) { entered.await() }
      val sending = async(start = CoroutineStart.UNDISPATCHED) { client.sendData(byteArrayOf(7)) }
      // The receive-side HELLO owns the control state even while native queue preflight suspends.
      assertEquals(1, preflights)
      assertFalse(sending.isCompleted)
      hold = false; release.complete(Unit)
      withTimeout(5000) { ready.await(); sending.await() }
      assertEquals("One HELLO and one application record", 2, outgoing.size)
      var frames = 0
      while (outgoing.isNotEmpty() || replies.isNotEmpty()) {
        assertTrue(++frames <= 8)
        if (outgoing.isNotEmpty()) server.receive(outgoing.removeFirst())
        if (replies.isNotEmpty()) client.receive(replies.removeFirst())
      }
      assertEquals(true, client.controlSupport)
      assertEquals(true, server.controlSupport)
      assertArrayEquals(byteArrayOf(7), delivered.single())
      assertFalse(client.isClosed); assertFalse(server.isClosed)
    } finally { release.complete(Unit); client.close(); server.close() }
  }

  @Test fun stalledNativeKeepaliveValidationCannotBlockHardDeadlineWatcher() = runBlocking {
    val helper = SessionTests()
    val fixture = helper.root().getJSONArray("valid").getJSONObject(0)
    val clock = java.util.concurrent.atomic.AtomicLong()
    val hold = java.util.concurrent.atomic.AtomicBoolean()
    val entered = CompletableDeferred<Unit>()
    val release = java.util.concurrent.CountDownLatch(1)
    val outI = java.util.ArrayDeque<ByteArray>()
    val outR = java.util.ArrayDeque<ByteArray>()
    val client = SessionConnection(helper.engine(fixture, false, current = {
      if (hold.get()) {
        entered.complete(Unit)
        assertTrue("Native validation gate was not released", release.await(5, java.util.concurrent.TimeUnit.SECONDS))
      }
      helper.engineIdentity(fixture, false)
    }), false, { true }, { outI.add(it) }, {}, {}, true, clock::get)
    val server = SessionConnection(helper.engine(fixture, true), true, { true }, { outR.add(it) }, {}, {}, true, clock::get)
    try {
      client.start()
      var messages = 0
      while (outI.isNotEmpty() || outR.isNotEmpty()) {
        assertTrue(++messages <= 32)
        if (outI.isNotEmpty()) server.receive(outI.removeFirst())
        if (outR.isNotEmpty()) client.receive(outR.removeFirst())
      }
      clock.set(60000); hold.set(true)
      assertEquals(60000L, client.nextDeadline())
      assertEquals(120000L, client.nextDeadline(includeMaintenance = false))
      val control = async(Dispatchers.Default) {
        try { client.tick(); null } catch (error: SessionException) { error.reason }
      }
      withTimeout(1000) { entered.await() }
      withTimeout(1000) { assertEquals(80000L, client.nextDeadline(includeMaintenance = false)) }
      clock.set(80000)
      withTimeout(1000) { rejectSuspending(SessionFailure.CONTROL_TIMEOUT) { client.checkDeadlines() } }
      assertTrue(client.isClosed)
      release.countDown()
      assertEquals(SessionFailure.CANCELLED, withTimeout(1000) { control.await() })
      assertTrue(outI.isEmpty())
    } finally { release.countDown(); client.close(); server.close() }
  }

  @Test fun cryptoCompletionDoesNotRequestMoreWorkAndBusyEventsAreRetained() = runBlocking {
    val events = SessionMaintenance()
    val now = { System.nanoTime() / 1_000_000 }
    events.request(); events.resnapshot()
    assertTrue(withTimeout(1000) { events.await(now() + 60000, now) })
    events.resnapshot()
    assertFalse(withTimeout(1000) { events.await(now() + 60000, now) })
    events.deferWork(); events.resnapshot()
    assertTrue(withTimeout(1000) { events.await(now() + 60000, now) })
    val waiting = async { events.await(now() + 60000, now) }
    kotlinx.coroutines.yield()
    assertFalse(waiting.isCompleted)
    waiting.cancelAndJoin()
    assertTrue(withTimeout(1000) { events.await(now() - 1, now) })
  }

  @Test fun suspendedSignerCannotBlockDeadlineSnapshotOrRetirement() = runBlocking {
    val helper = SessionTests()
    val fixture = helper.root().getJSONArray("valid").getJSONObject(0)
    var clock = 0L
    val entered = CompletableDeferred<Unit>()
    val release = CompletableDeferred<Unit>()
    var submitted = 0
    val initiator = helper.engine(fixture, false, now = { clock })
    val responder = helper.engine(fixture, true, signer = {
      entered.complete(Unit); release.await()
      SessionProof(helper.engineIdentity(fixture, true), byteArrayOf())
    }, now = { clock })
    val connection = SessionConnection(responder, true, { true }, { submitted++ }, {}, {}, now = { clock })
    val receive = async {
      try { connection.receive(SessionEnvelope.encode(1, initiator.initiate())); null }
      catch (error: SessionException) { error.reason }
    }
    try {
      withTimeout(1000) { entered.await() }
      clock = 29999
      withTimeout(1000) {
        assertEquals(30000L, connection.nextDeadline())
        connection.tick()
      }
      assertEquals(0L, connection.maintenanceRuns)
      clock = 30000
      withTimeout(1000) { rejectSuspending(SessionFailure.EXPIRED) { connection.tick() } }
      assertTrue(connection.isClosed)
      assertNull(connection.nextDeadline())
      release.complete(Unit)
      assertEquals(SessionFailure.CANCELLED, withTimeout(1000) { receive.await() })
      assertEquals(0, submitted)
    } finally {
      release.complete(Unit); receive.cancelAndJoin(); connection.close(); initiator.close()
    }
  }

  @Test fun busySubmissionCannotExtendOutstandingPongDeadline() = runBlocking {
    val helper = SessionTests()
    val fixture = helper.root().getJSONArray("valid").getJSONObject(0)
    var clock = 0L
    var hold = false
    val entered = CompletableDeferred<Unit>()
    val release = CompletableDeferred<Unit>()
    val outI = java.util.ArrayDeque<ByteArray>()
    val outR = java.util.ArrayDeque<ByteArray>()
    val client = SessionConnection(helper.engine(fixture, false), false, { true }, {
      if (hold) { entered.complete(Unit); release.await() } else outI.add(it)
    }, {}, {}, true, { clock })
    val server = SessionConnection(helper.engine(fixture, true), true, { true }, { outR.add(it) }, {}, {}, true, { clock })
    try {
      client.start()
      var messages = 0
      while (outI.isNotEmpty() || outR.isNotEmpty()) {
        assertTrue(++messages <= 32)
        if (outI.isNotEmpty()) server.receive(outI.removeFirst())
        if (outR.isNotEmpty()) client.receive(outR.removeFirst())
      }
      clock = 60000; client.tick()
      assertEquals(1, outI.size)
      hold = true
      val send = async {
        try { client.sendData(byteArrayOf(1)); null }
        catch (error: SessionException) { error.reason }
      }
      withTimeout(1000) { entered.await() }
      withTimeout(1000) { assertEquals(80000L, client.nextDeadline()) }
      clock = 79999; withTimeout(1000) { client.tick() }
      clock = 80000
      withTimeout(1000) { rejectSuspending(SessionFailure.CONTROL_TIMEOUT) { client.checkDeadlines() } }
      assertTrue(client.isClosed)
      release.complete(Unit)
      assertEquals(SessionFailure.CANCELLED, withTimeout(1000) { send.await() })
      assertEquals(1, outI.size)
    } finally { release.complete(Unit); client.close(); server.close() }
  }

  private fun reject(reason: SessionFailure, action: () -> Unit) {
    try { action(); fail("Expected $reason") }
    catch (error: SessionException) { assertEquals(reason, error.reason) }
  }
  private fun pair(initialId: Long = 0): Pair<SessionLiveness, SessionLiveness> {
    val client = SessionLiveness(false, initialId)
    val server = SessionLiveness(true)
    client.start(0); server.start(0)
    val hello = requireNotNull(client.pending)
    client.issuing(hello, 0); client.submitted(hello, 0); server.receive(hello, 0)
    val ack = requireNotNull(server.pending)
    server.issuing(ack, 0); server.submitted(ack, 0); client.receive(ack, 0)
    return client to server
  }
  @Test fun deadlineSnapshotsDoNotSpinOnBlockedControlsOrExtendPong() {
    val legacy = SessionLiveness(false)
    assertNull(legacy.nextDeadline())
    legacy.start(0)
    assertEquals(10000L, legacy.nextDeadline())
    legacy.poll(10000)
    assertNull(legacy.nextDeadline())
    val (client, server) = pair()
    assertEquals(60000L, client.nextDeadline())
    assertNull(server.nextDeadline())
    client.poll(60000)
    assertNull(client.nextDeadline()) // Queue refusal waits for capacity; no overdue PING wake loop.
    val ping = requireNotNull(client.pending)
    client.issuing(ping, 60001); client.submitted(ping, 60001)
    assertEquals(80001L, client.nextDeadline())
    client.activity(79999)
    assertEquals(80001L, client.nextDeadline())
    reject(SessionFailure.CONTROL_TIMEOUT) { client.poll(80001) }
  }

  @Test fun idleSnapshotsAndMaintenanceNeverValidateButTrafficDoes() = runBlocking {
    val helper = SessionTests()
    val fixture = helper.root().getJSONArray("valid").getJSONObject(0)
    var clock = 0L
    var revoked = false
    var loads = 0
    var changes = 0
    val outI = java.util.ArrayDeque<ByteArray>()
    val outR = java.util.ArrayDeque<ByteArray>()
    val client = SessionConnection(helper.engine(fixture, false, current = {
      loads++
      if (revoked) throw SessionException(SessionFailure.UNTRUSTED_PEER)
      helper.engineIdentity(fixture, false)
    }), false, { true }, { outI.add(it) }, {}, {}, true, { clock }, changed = { changes++ })
    val server = SessionConnection(helper.engine(fixture, true), true, { true }, { outR.add(it) }, {}, {}, true, { clock })
    suspend fun pump() {
      var count = 0
      while (outI.isNotEmpty() || outR.isNotEmpty()) {
        assertTrue(++count <= 32)
        if (outI.isNotEmpty()) server.receive(outI.removeFirst())
        if (outR.isNotEmpty()) client.receive(outR.removeFirst())
      }
    }
    try {
      client.start(); pump()
      val before = loads
      val beforeChanges = changes
      repeat(59) {
        clock = (it + 1) * 1000L
        assertEquals(60000L, client.nextDeadline())
        client.tick()
      }
      assertEquals(before, loads)
      assertEquals(beforeChanges, changes) // A maintenance wake cannot signal itself forever.
      revoked = true; clock = 60000
      rejectSuspending(SessionFailure.UNTRUSTED_PEER) { client.tick() }
      assertTrue(loads > before)
      assertTrue(outI.isEmpty())
      assertTrue(client.isClosed)
      assertNull(client.nextDeadline())
    } finally { client.close(); server.close() }
  }

  private suspend fun rejectSuspending(reason: SessionFailure, action: suspend () -> Unit) {
    try { action(); fail("Expected $reason") }
    catch (error: SessionException) { assertEquals(reason, error.reason) }
  }

  @Test fun conflatedWakesSurviveSnapshotRacesAndCancellation() = runBlocking {
    val events = kotlinx.coroutines.channels.Channel<Unit>(kotlinx.coroutines.channels.Channel.CONFLATED)
    val now = { System.nanoTime() / 1_000_000 }
    events.trySend(Unit); events.trySend(Unit)
    withTimeout(1000) { awaitSessionDeadline(events, now() + 60000, now) }
    val waiting = launch(start = kotlinx.coroutines.CoroutineStart.UNDISPATCHED) {
      awaitSessionDeadline(events, null, now)
      fail("Cancelled wait resumed")
    }
    waiting.cancelAndJoin()
    withTimeout(1000) { awaitSessionDeadline(events, now() - 1, now) }
    assertFalse(waiting.isActive)
  }

  @Test fun independentControlFixturesAndDispatcherBounds() {
    val fixtures = SessionTests().root("control-vectors.json")
    val valid = fixtures.getJSONArray("valid")
    val invalid = fixtures.getJSONArray("invalid")
    assertTrue(valid.length() >= 3); assertTrue(invalid.length() >= 15)
    fun bytes(hex: String) = hex.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
    repeat(valid.length()) {
      val row = valid.getJSONObject(it)
      val expected = SessionControl(ControlKind.entries.single { kind -> kind.wire == row.getInt("type") }, row.getLong("value"))
      val encoded = bytes(row.getString("payloadHex"))
      assertArrayEquals(encoded, expected.encode())
      assertEquals(expected, SessionControl.decode(encoded))
      assertEquals(expected, SessionControl.application(encoded))
    }
    repeat(invalid.length()) {
      val row = invalid.getJSONObject(it)
      reject(if (row.getString("reason") == "unsupportedProfile") SessionFailure.UNSUPPORTED_PROFILE else SessionFailure.MALFORMED) {
        SessionControl.decode(bytes(row.getString("payloadHex")))
      }
    }
    assertNull(SessionControl.application("aniCe connection check".toByteArray()))
    assertNull(SessionControl.application(SessionCbor.encode(Cbor.Array(listOf(Cbor.Text("other"))))))
    reject(SessionFailure.MALFORMED) { SessionControl.application(byteArrayOf(0x84.toByte())) }
    reject(SessionFailure.MALFORMED) { SessionControl(ControlKind.PING, -1).encode() }
  }
  @Test fun controlClassificationDoesNotMaterializeBulkBytesAndKeepsValidation() {
    val payload = ByteArray(262016) { 0x5a }
    val value = Cbor.Array(listOf(Cbor.Text("other"), Cbor.Bytes(payload)))
    val encoded = SessionCbor.encode(value, 262144)
    val classified = SessionCbor.decode(encoded, 262144, materializeBytes = false) as Cbor.Array
    assertEquals(0, (classified.value[1] as Cbor.Bytes).value.size)
    assertArrayEquals(payload, ((SessionCbor.decode(encoded, 262144) as Cbor.Array).value[1] as Cbor.Bytes).value)
    assertNull(SessionControl.application(encoded, 262144))
    reject(SessionFailure.MALFORMED) { SessionControl.application(encoded.copyOf(encoded.size - 1), 262144) }
    reject(SessionFailure.MALFORMED) { SessionControl.application(encoded + byteArrayOf(0), 262144) }
    val invalidControl = SessionCbor.encode(Cbor.Array(listOf(Cbor.Text("aniCe control"), Cbor.Integer(1),
      Cbor.Integer(3), Cbor.Map(listOf(Cbor.Text("requestId") to Cbor.Bytes(byteArrayOf(1)))))))
    reject(SessionFailure.MALFORMED) { SessionControl.application(invalidControl) }
    // Suppressing values must not suppress deterministic byte-string map-key ordering.
    val badMap = byteArrayOf(0x81.toByte(), 0xa2.toByte(), 0x41, 2, 0, 0x41, 1, 0)
    reject(SessionFailure.MALFORMED) { SessionCbor.decode(badMap, materializeBytes = false) }
  }

  @Test fun livenessOrderingDeadlinesAndUnsignedBoundaries() {
    val (c, s) = pair()
    assertEquals(true, c.support); assertEquals(true, s.support)
    c.poll(59999); assertNull(c.pending)
    c.poll(60000)
    val ping = requireNotNull(c.pending)
    assertEquals(SessionControl(ControlKind.PING, 0), ping)
    c.poll(60001); assertEquals(ping, c.pending)
    c.issuing(ping, 60001); c.submitted(ping, 60001)
    c.poll(70000); assertNull(c.pending)
    reject(SessionFailure.STATE) { c.receive(SessionControl(ControlKind.PONG, 1), 70000) }
    s.receive(ping, 70000)
    val pong = requireNotNull(s.pending)
    s.issuing(pong, 70000); s.submitted(pong, 70000); c.receive(pong, 70000)
    reject(SessionFailure.STATE) { c.receive(pong, 70001) }
    reject(SessionFailure.STATE) { s.receive(ping, 70001) }
    reject(SessionFailure.STATE) { s.receive(SessionControl(ControlKind.RENEWAL_REQUEST), 70001) }
    c.poll(130001); assertEquals(SessionControl(ControlKind.PING, 1), c.pending)
    val lost = pair().first
    lost.poll(60000); val pending = requireNotNull(lost.pending)
    lost.issuing(pending, 60000); lost.submitted(pending, 60000)
    lost.activity(79999) // Unrelated authenticated traffic cannot satisfy an outstanding ping.
    reject(SessionFailure.CONTROL_TIMEOUT) { lost.receive(SessionControl(ControlKind.PONG, 0), 80000) }
    reject(SessionFailure.CONTROL_TIMEOUT) { lost.poll(80000) }
    val max = pair(0xffffffffL).first
    max.poll(60000); val final = requireNotNull(max.pending)
    max.issuing(final, 60000); max.submitted(final, 60000)
    max.receive(SessionControl(ControlKind.PONG, 0xffffffffL), 60000)
    reject(SessionFailure.CONTROL_TIMEOUT) { max.poll(120000) }
    val legacy = SessionLiveness(false)
    legacy.start(0)
    reject(SessionFailure.STATE) { legacy.receive(SessionControl(ControlKind.HELLO_ACK), 0) }
    legacy.poll(10000); assertEquals(false, legacy.support); assertNull(legacy.pending)
    reject(SessionFailure.STATE) { legacy.receive(SessionControl(ControlKind.HELLO_ACK), 10000) }
  }

  @Test fun encryptedControlsBackpressureLegacyFallbackAndHardLifetime() = runBlocking {
    val helper = SessionTests()
    val fixture = helper.root().getJSONArray("valid").getJSONObject(0)
    for (serverControls in listOf(true, false)) {
      var clock = 0L
      var writable = true
      val signals = java.util.concurrent.atomic.AtomicInteger()
      val outboundI = java.util.ArrayDeque<ByteArray>()
      val outboundR = java.util.ArrayDeque<ByteArray>()
      val delivered = mutableListOf<ByteArray>()
      val client = SessionConnection(helper.engine(fixture, false), false, { writable }, { outboundI.add(it) }, {}, {}, true, { clock }, changed = { signals.incrementAndGet() })
      val server = SessionConnection(helper.engine(fixture, true), true, { true }, { outboundR.add(it) }, { delivered.add(it) }, {}, serverControls, { clock })
      suspend fun pump() {
        var count = 0
        while (outboundI.isNotEmpty() || outboundR.isNotEmpty()) {
          check(++count <= 32) { "Unbounded control exchange" }
          if (outboundI.isNotEmpty()) server.receive(outboundI.removeFirst())
          if (outboundR.isNotEmpty()) client.receive(outboundR.removeFirst())
        }
      }
      try {
        client.start(); pump()
        if (serverControls) {
          assertEquals(true, client.controlSupport); assertEquals(true, server.controlSupport)
          assertTrue(delivered.isEmpty())
          clock = 60000; writable = false; client.tick()
          assertTrue(outboundI.isEmpty())
          writable = true; clock = 61000; client.tick(); pump()
          assertTrue(delivered.isEmpty())
          clock = 121000; client.tick(); pump() // Quiet connection exceeds the former idle cutoff.
        } else {
          clock = 10000; client.tick()
          assertEquals(false, client.controlSupport)
          delivered.clear() // Legacy dispatch receives HELLO as ordinary data and ignores it in the app.
        }
        writable = false
        val signalsBeforeRefusal = signals.get()
        try { client.sendData(byteArrayOf(1)); fail("Unwritable transport admitted DATA") }
        catch (_: SessionBackpressure) {}
        assertEquals("Refusal must not wake its own capacity waiter", signalsBeforeRefusal, signals.get())
        writable = true
        client.sendData("aniCe connection check".toByteArray()); pump()
        assertEquals(1, delivered.size)
        clock = 3600000
        try { client.tick(); fail("Keepalive extended the hard lifetime") }
        catch (error: SessionException) { assertEquals(SessionFailure.EXPIRED, error.reason) }
        assertEquals(SessionExpiry.LIFETIME, client.expiration)
        assertTrue(client.isClosed)
      } finally { client.close(); server.close() }
    }
  }
  @Test fun delayedMaintenanceDoesNotMoveCompatibilityOrPongDeadlines() {
    val legacy = SessionLiveness(false)
    legacy.start(0)
    val hello = requireNotNull(legacy.pending)
    legacy.issuing(hello, 0); legacy.submitted(hello, 0)
    reject(SessionFailure.STATE) { legacy.receive(SessionControl(ControlKind.HELLO_ACK), 10500) }
    legacy.poll(11000)
    assertEquals(false, legacy.support)
    assertNull(legacy.pending)
    val client = pair().first
    client.poll(60500)
    val ping = requireNotNull(client.pending)
    assertEquals(SessionControl(ControlKind.PING, 0), ping)
    client.issuing(ping, 60500); client.submitted(ping, 60500)
    client.activity(81000)
    // No maintenance ran at expiry; receive must still reject a late authenticated response.
    reject(SessionFailure.CONTROL_TIMEOUT) { client.receive(SessionControl(ControlKind.PONG, 0), 81000) }
    reject(SessionFailure.CONTROL_TIMEOUT) { client.poll(81000) }
  }
  @Test fun automaticOffRetainsForegroundChannelAndHardLifetime() = runBlocking {
    assertTrue(retainForegroundSession(true, true, ConnectionState.SECURED, false))
    assertFalse(retainForegroundSession(false, true, ConnectionState.SECURED, false))
    assertFalse(retainForegroundSession(true, false, ConnectionState.SECURED, false))
    assertFalse(retainForegroundSession(true, true, ConnectionState.SECURED, true))
    val terminal = listOf(ConnectionState.CONNECTING, ConnectionState.FAILED, ConnectionState.DISCONNECTED)
    assertEquals(3, terminal.size)
    terminal.forEach { assertFalse(retainForegroundSession(true, true, it, false)) }
    val helper = SessionTests()
    val fixtures = helper.root().getJSONArray("valid")
    assertTrue(fixtures.length() >= 1)
    val fixture = fixtures.getJSONObject(0)
    var clock = 0L
    val outgoing = java.util.ArrayDeque<ByteArray>()
    val replies = java.util.ArrayDeque<ByteArray>()
    var delivered = 0
    val client = SessionConnection(helper.engine(fixture, false), false, { true }, { outgoing.add(it) },
      {}, {}, true, { clock }, true)
    val server = SessionConnection(helper.engine(fixture, true), true, { true }, { replies.add(it) },
      { delivered++ }, {}, true, { clock }, true)
    suspend fun pump() {
      var frames = 0
      while (outgoing.isNotEmpty() || replies.isNotEmpty()) {
        assertTrue(++frames <= 32)
        if (outgoing.isNotEmpty()) server.receive(outgoing.removeFirst())
        if (replies.isNotEmpty()) client.receive(replies.removeFirst())
      }
    }
    try {
      client.start(); pump()
      client.disableRenewal(); server.disableRenewal()
      repeat(55) { clock = (it + 1) * 60000L; client.tick(); pump() }
      assertNull(client.renewalReason)
      assertFalse(client.isClosed)
      client.sendData("still connected".toByteArray()); pump()
      assertEquals(1, delivered)
      clock = 3600000
      try { client.tick(); fail("Automatic off extended the session lifetime") }
      catch (error: SessionException) { assertEquals(SessionFailure.EXPIRED, error.reason) }
      assertTrue(client.isClosed)
    } finally { client.close(); server.close() }
  }
  @Test fun encryptedRenewalBackpressureFailureAndStop() = runBlocking {
    val helper = SessionTests()
    val fixture = helper.root().getJSONArray("valid").getJSONObject(0)
    for (fault in listOf("none", "submission", "stop")) {
      var clock = 0L
      var writable = true
      val outI = java.util.ArrayDeque<ByteArray>()
      val outR = java.util.ArrayDeque<ByteArray>()
      var delivered = 0
      val client = SessionConnection(helper.engine(fixture, false), false, { true }, { outI.add(it) },
        { delivered++ }, {}, true, { clock }, true)
      val server = SessionConnection(helper.engine(fixture, true), true, { writable }, {
        if (clock >= 3300000 && fault == "submission") throw SessionException(SessionFailure.AUTHENTICATION)
        outR.add(it)
      }, { delivered++ }, {}, true, { clock }, true)
      suspend fun pump() {
        var count = 0
        while (outI.isNotEmpty() || outR.isNotEmpty()) {
          assertTrue(++count <= 32)
          if (outI.isNotEmpty()) server.receive(outI.removeFirst())
          if (outR.isNotEmpty()) client.receive(outR.removeFirst())
        }
      }
      try {
        client.start(); pump()
        repeat(54) { clock = (it + 1) * 60000L; client.tick(); pump() }
        clock = 3300000; writable = false; server.tick()
        assertTrue(outR.isEmpty()) // Preflight retains one logical renewal, without consuming a nonce.
        try { server.sendData(byteArrayOf(1)); fail("Application escaped renewal") }
        catch (_: SessionBackpressure) {}
        if (fault == "stop") {
          server.close(); writable = true
          try { server.tick(); fail("Retired renewal submitted") }
          catch (error: SessionException) { assertEquals(SessionFailure.CANCELLED, error.reason) }
          assertTrue(outR.isEmpty())
        } else {
          writable = true
          if (fault == "submission") {
            try { server.tick(); fail("Renewal submission failure accepted") }
            catch (error: SessionException) { assertEquals(SessionFailure.AUTHENTICATION, error.reason) }
            assertTrue(server.isClosed)
          } else {
            client.tick(); assertEquals(1L, client.renewalReason)
            server.tick(); pump(); assertEquals(1L, client.renewalReason)
            try { client.sendData(byteArrayOf(1)); fail("Application escaped renewal") }
            catch (_: SessionBackpressure) {}
            client.disconnect(); pump()
            assertTrue(client.isClosed); assertTrue(server.isClosed)
          }
        }
        assertEquals(0, delivered)
      } finally { client.close(); server.close() }
    }
  }
  @Test fun encryptedControlFailuresRetireWithoutApplicationDelivery() = runBlocking {
    val helper = SessionTests()
    val fixture = helper.root().getJSONArray("valid").getJSONObject(0)
    val cases = listOf("wrongPong", "missingPong", "malformed", "submission")
    assertEquals(4, cases.size)
    for (fault in cases) {
      var clock = 0L
      var rejectSubmission = false
      val outI = java.util.ArrayDeque<ByteArray>()
      val outR = java.util.ArrayDeque<ByteArray>()
      var delivered = 0
      val client = SessionConnection(helper.engine(fixture, false), false, { true }, {
        if (rejectSubmission) throw SessionException(SessionFailure.AUTHENTICATION)
        outI.add(it)
      }, { delivered++ }, {}, true, { clock })
      val server = SessionConnection(helper.engine(fixture, true), true, { true }, { outR.add(it) },
        { delivered++ }, {}, true, { clock })
      suspend fun pump() {
        var count = 0
        while (outI.isNotEmpty() || outR.isNotEmpty()) {
          check(++count <= 32)
          if (outI.isNotEmpty()) server.receive(outI.removeFirst())
          if (outR.isNotEmpty()) client.receive(outR.removeFirst())
        }
      }
      try {
        client.start(); pump()
        val expected = when (fault) {
          "wrongPong" -> {
            server.sendData(SessionControl(ControlKind.PONG, 7).encode())
            SessionFailure.STATE
          }
          "malformed" -> {
            server.sendData(byteArrayOf(0x84.toByte()))
            SessionFailure.MALFORMED
          }
          "missingPong" -> {
            clock = 60000; client.tick(); server.receive(outI.removeFirst())
            outR.clear(); clock = 80000
            SessionFailure.CONTROL_TIMEOUT
          }
          else -> { clock = 60000; rejectSubmission = true; SessionFailure.AUTHENTICATION }
        }
        try {
          if (outR.isNotEmpty()) client.receive(outR.removeFirst()) else client.tick()
          fail("Accepted $fault")
        } catch (error: SessionException) { assertEquals(expected, error.reason) }
        assertTrue(client.isClosed)
        assertEquals(0, delivered)
      } finally { client.close(); server.close() }
    }
  }
}
