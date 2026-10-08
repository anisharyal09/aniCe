// SPDX-License-Identifier: GPL-3.0-or-later
package io.github.anisharyal09.anice.infrastructure.session

import io.github.anisharyal09.anice.infrastructure.bluetooth.*
import kotlinx.coroutines.*
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class SessionChannelTests {
  private fun b(row: JSONObject, name: String) =
    row.getString(name + "Hex").chunked(2).map { it.toInt(16).toByte() }.toByteArray()

  private fun vectors() = SessionTests().root("record-vectors.json")

  private suspend fun rejects(reason: SessionFailure, action: suspend () -> Unit) {
    try {
      action()
      fail("Expected $reason")
    } catch (e: SessionException) {
      assertEquals(reason, e.reason)
    }
  }

  @Test
  fun independentRecordsAndUnsignedCounters() {
    val rows = vectors().getJSONArray("valid")
    assertTrue(rows.length() >= 3)
    repeat(rows.length()) { i ->
      val v = rows.getJSONObject(i)
      val kind = RecordKind.entries.first { it.wire == v.getInt("kind") }
      val seq = v.getString("sequence").toULong()
      assertArrayEquals(b(v, "nonce"), SessionRecordCodec.nonce(b(v, "iv"), seq))
      val actual =
        SessionRecordCodec.seal(
          b(v, "key"),
          b(v, "iv"),
          b(v, "session"),
          v.getInt("direction"),
          kind,
          seq,
          b(v, "plain"),
        )
      assertArrayEquals(b(v, "record"), actual)
      assertArrayEquals(
        b(v, "plain"),
        SessionRecordCodec.open(
            b(v, "key"),
            b(v, "iv"),
            b(v, "session"),
            v.getInt("direction"),
            seq,
            actual,
          )
          .second,
      )
    }
  }

  @Test
  fun allRecordNegativesAreTyped() = runBlocking {
    val rows = vectors().getJSONArray("invalid")
    assertTrue(rows.length() >= 15)
    repeat(rows.length()) { i ->
      val v = rows.getJSONObject(i)
      rejects(
        if (v.getString("reason") == "malformed") SessionFailure.MALFORMED
        else SessionFailure.AUTHENTICATION
      ) {
        SessionRecordCodec.open(
          b(v, "key"),
          b(v, "iv"),
          b(v, "session"),
          v.getInt("direction"),
          v.getString("sequence").toULong(),
          b(v, "record"),
        )
      }
    }
  }

  @Test
  fun codecRejectsInvalidMaterialAndSealBounds() = runBlocking {
    val key = ByteArray(32)
    val iv = ByteArray(12)
    val id = ByteArray(32)
    val cases =
      listOf(
        Triple(0, 12, 32),
        Triple(16, 12, 32),
        Triple(31, 12, 32),
        Triple(33, 12, 32),
        Triple(32, 0, 32),
        Triple(32, 11, 32),
        Triple(32, 13, 32),
        Triple(32, 12, 0),
        Triple(32, 12, 31),
        Triple(32, 12, 33),
      )
    assertTrue(cases.size >= 10)
    for ((k, v, s) in cases) rejects(SessionFailure.MALFORMED) {
      SessionRecordCodec.seal(
        ByteArray(k),
        ByteArray(v),
        ByteArray(s),
        1,
        RecordKind.DATA,
        0uL,
        byteArrayOf(),
      )
    }
    for (direction in listOf(0, 3)) rejects(SessionFailure.MALFORMED) {
      SessionRecordCodec.seal(key, iv, id, direction, RecordKind.DATA, 0uL, byteArrayOf())
    }
    rejects(SessionFailure.MALFORMED) {
      SessionRecordCodec.seal(key, iv, id, 1, RecordKind.DATA, 0uL, ByteArray(4001))
    }
    rejects(SessionFailure.MALFORMED) {
      SessionRecordCodec.seal(key, iv, id, 1, RecordKind.READY, 0uL, byteArrayOf(1))
    }
    rejects(SessionFailure.MALFORMED) { SessionRecordCodec.nonce(ByteArray(11), 0uL) }
  }

  private fun channel(
    server: Boolean = false,
    now: () -> Long = { 0L },
    validate: suspend () -> Unit = {},
    capacity: suspend (Int) -> Boolean = { true },
    submit: suspend (ByteArray) -> Unit = {},
  ): SecureSession {
    val v = vectors().getJSONArray("valid").getJSONObject(0)
    return SecureSession(
      server,
      b(v, "key"),
      b(v, "key"),
      b(v, "iv"),
      b(v, "iv"),
      b(v, "session"),
      validate,
      capacity,
      submit,
      now,
    )
  }

  @Test
  fun readinessEarlyDataFailureAndTransportNonceBurn() = runBlocking {
    val early = channel()
    rejects(SessionFailure.STATE) { early.send(RecordKind.DATA, byteArrayOf(1)) }
    assertEquals(ChannelStage.CLOSED, early.stage)
    assertEquals(0uL, early.sent)
    val failed = channel(submit = { throw SessionException(SessionFailure.AUTHENTICATION) })
    rejects(SessionFailure.AUTHENTICATION) { failed.send(RecordKind.READY) }
    assertEquals(1uL, failed.sent)
    assertEquals(ChannelStage.CLOSED, failed.stage)
    rejects(SessionFailure.CANCELLED) { failed.send(RecordKind.READY) }
    assertEquals(1uL, failed.sent)
    val changedCapacity = channel(submit = { throw SessionBackpressure() })
    rejects(SessionFailure.STATE) { changedCapacity.send(RecordKind.READY) }
    assertEquals(1uL, changedCapacity.sent)
    assertEquals(ChannelStage.CLOSED, changedCapacity.stage)
    val capacity = channel(capacity = { false })
    try {
      capacity.send(RecordKind.READY)
      fail("Expected backpressure")
    } catch (_: SessionBackpressure) {}
    assertEquals(0uL, capacity.sent)
    assertEquals(ChannelStage.WAITING, capacity.stage)
  }

  @Test
  fun timeoutRevocationAndSuspendedSubmissionAreTerminal() = runBlocking {
    var now = 0L
    val expired = channel(now = { now })
    now = 10000
    rejects(SessionFailure.EXPIRED) { expired.tick() }
    assertEquals(SessionExpiry.READINESS, expired.expiration)
    assertEquals(ChannelStage.CLOSED, expired.stage)
    val revoked = channel(validate = { throw SessionException(SessionFailure.UNTRUSTED_PEER) })
    rejects(SessionFailure.UNTRUSTED_PEER) { revoked.send(RecordKind.READY) }
    assertEquals(0uL, revoked.sent)
    val entered = CompletableDeferred<Unit>()
    val resume = CompletableDeferred<Unit>()
    val blocked =
      channel(
        submit = {
          entered.complete(Unit)
          resume.await()
        }
      )
    val sending = async { rejects(SessionFailure.CANCELLED) { blocked.send(RecordKind.READY) } }
    entered.await()
    try {
      blocked.send(RecordKind.READY)
      fail("Concurrent send must return backpressure")
    } catch (_: SessionBackpressure) {}
    assertEquals(1uL, blocked.sent)
    blocked.close()
    resume.complete(Unit)
    sending.await()
    assertEquals(1uL, blocked.sent)
    assertEquals(ChannelStage.CLOSED, blocked.stage)
  }

  @Test
  fun completeConnectionReadinessAndBidirectionalDataOverMtu23() = runBlocking {
    val h = SessionTests()
    val v = h.root().getJSONArray("valid").getJSONObject(0)
    val outboundI = java.util.ArrayDeque<ByteArray>()
    val outboundR = java.util.ArrayDeque<ByteArray>()
    var securedI = 0
    var securedR = 0
    val dataI = mutableListOf<ByteArray>()
    val dataR = mutableListOf<ByteArray>()
    val c =
      SessionConnection(
        h.engine(v, false),
        false,
        { true },
        { outboundI.add(it) },
        { dataI.add(it) },
        { securedI++ },
      )
    val s =
      SessionConnection(
        h.engine(v, true),
        true,
        { true },
        { outboundR.add(it) },
        { dataR.add(it) },
        { securedR++ },
      )
    val incomingI = GattReassembler(2)
    val incomingR = GattReassembler(2)
    var idI = 0L
    var idR = 0L
    suspend fun deliver(
      queue: java.util.ArrayDeque<ByteArray>,
      to: SessionConnection,
      assembly: GattReassembler,
      id: Long,
    ) {
      val frames = GattReassembler.fragments(queue.removeFirst(), id, 20, 2)
      for (frame in frames) {
        val complete = assembly.receive(frame)
        if (complete != null) to.receive(complete)
      }
    }
    c.start()
    assertEquals(0, securedI)
    assertEquals(0, securedR)
    deliver(outboundI, s, incomingR, idI++)
    deliver(outboundR, c, incomingI, idR++)
    deliver(outboundI, s, incomingR, idI++)
    deliver(outboundR, c, incomingI, idR++)
    assertEquals(0, securedI)
    assertEquals(0, securedR)
    deliver(outboundI, s, incomingR, idI++)
    assertEquals(1, securedR)
    assertEquals(0, securedI)
    deliver(outboundR, c, incomingI, idR++)
    assertEquals(1, securedI)
    val payload = ByteArray(4000) { it.toByte() }
    c.sendData(payload)
    deliver(outboundI, s, incomingR, idI++)
    s.sendData(byteArrayOf(7))
    deliver(outboundR, c, incomingI, idR++)
    assertArrayEquals(payload, dataR.single())
    assertArrayEquals(byteArrayOf(7), dataI.single())
    s.disconnect()
    deliver(outboundR, c, incomingI, idR)
    assertTrue(c.isClosed)
    assertTrue(s.isClosed)
    assertTrue(c.closedByPeer)
    assertFalse(s.closedByPeer)
    rejects(SessionFailure.CANCELLED) { c.tick() }
    assertTrue(c.closedByPeer)
    assertNull(c.expiration)
  }

  @Test
  fun recordLimitsQueueSaturationIdleAndLifetime() = runBlocking {
    val counter = RecordSequence()
    repeat(1 shl 20) { assertEquals(it.toULong(), counter.reserve()) }
    rejects(SessionFailure.EXPIRED) { counter.reserve() }
    assertEquals(1uL shl 20, counter.value)
    val queue = GattQueueBudget()
    repeat(8) { queue.reserve(4096) }
    assertEquals(32768, queue.bytes)
    assertFalse(queue.canReserve(1))
    try {
      queue.reserve(1)
      fail("Expected queue saturation")
    } catch (_: SessionBackpressure) {}
    assertEquals(8, queue.messages)
    queue.release(4096)
    queue.reserve(4096)
    queue.clear()
    assertEquals(0, queue.bytes)
    assertFalse(queue.canReserve(4097))
    assertFalse(queue.canReserve(0))
    suspend fun ready(now: () -> Long): SecureSession {
      val ch = channel(now = now)
      ch.send(RecordKind.READY)
      val v = vectors().getJSONArray("valid").getJSONObject(0)
      val ack =
        SessionRecordCodec.seal(
          b(v, "key"),
          b(v, "iv"),
          b(v, "session"),
          2,
          RecordKind.READY_ACK,
          0uL,
          byteArrayOf(),
        )
      ch.receive(ack)
      return ch
    }
    var now = 0L
    val idle = ready { now }
    now = 120000
    rejects(SessionFailure.EXPIRED) { idle.tick() }
    assertEquals(ChannelStage.CLOSED, idle.stage)
    assertEquals(SessionExpiry.IDLE, idle.expiration)
    now = 0
    val age = ready { now }
    for (time in 100000L..3500000L step 100000L) {
      now = time
      age.send(RecordKind.DATA)
    }
    now = 3600000
    rejects(SessionFailure.EXPIRED) { age.tick() }
    assertEquals(ChannelStage.CLOSED, age.stage)
    assertEquals(SessionExpiry.LIFETIME, age.expiration)
    for (sequence in listOf(0uL, 2uL, ULong.MAX_VALUE)) {
      val ch = ready { 0L }
      val v = vectors().getJSONArray("valid").getJSONObject(0)
      val record =
        SessionRecordCodec.seal(
          b(v, "key"),
          b(v, "iv"),
          b(v, "session"),
          2,
          RecordKind.DATA,
          sequence,
          byteArrayOf(1),
        )
      rejects(SessionFailure.AUTHENTICATION) { ch.receive(record) }
      assertEquals(1uL, ch.received)
      assertEquals(ChannelStage.CLOSED, ch.stage)
    }
  }

  @Test
  fun submissionFailureAtEveryHandshakeAndReadinessTransition() = runBlocking {
    val helper = SessionTests()
    val v = helper.root().getJSONArray("valid").getJSONObject(0)
    val saved = v.toString()
    for (target in listOf(1 to false, 2 to true, 3 to false, 4 to true, 6 to false, 6 to true)) {
      val clientOut = java.util.ArrayDeque<ByteArray>()
      val serverOut = java.util.ArrayDeque<ByteArray>()
      var applicationData = 0
      var secured = 0
      var injected = false
      suspend fun submit(bytes: ByteArray, server: Boolean) {
        if (bytes[0].toInt() == target.first && server == target.second) {
          injected = true
          throw SessionException(SessionFailure.AUTHENTICATION)
        }
        (if (server) serverOut else clientOut).add(bytes)
      }
      val c =
        SessionConnection(
          helper.engine(v, false),
          false,
          { true },
          { submit(it, false) },
          { applicationData++ },
          { secured++ },
        )
      val s =
        SessionConnection(
          helper.engine(v, true),
          true,
          { true },
          { submit(it, true) },
          { applicationData++ },
          { secured++ },
        )
      rejects(SessionFailure.AUTHENTICATION) {
        c.start()
        repeat(6) {
          if (clientOut.isNotEmpty()) s.receive(clientOut.removeFirst())
          if (serverOut.isNotEmpty()) c.receive(serverOut.removeFirst())
        }
      }
      assertTrue(injected)
      assertEquals(0, applicationData)
      assertEquals(0, secured)
      assertTrue((if (target.second) s else c).isClosed)
      assertEquals(saved, v.toString())
      c.close()
      s.close()
    }
  }

  @Test
  fun fragmentationBoundariesAndMalformedTraffic() = runBlocking {
    val data = ByteArray(4096) { it.toByte() }
    val r = GattReassembler(2)
    val frames = GattReassembler.fragments(data, 0, 20, 2)
    assertEquals(373, frames.size)
    var result: ByteArray? = null
    frames.forEach { result = r.receive(it) }
    assertArrayEquals(data, result)
    val bad = mutableListOf<ByteArray>()
    bad += byteArrayOf()
    bad += frames[0].copyOf(9)
    bad += frames[0].copyOf().also { it[0] = 1 }
    bad += frames[1]
    for (offset in 1..8) bad +=
      frames[0].copyOf().also { it[offset] = (it[offset].toInt() xor 1).toByte() }
    // Total length 4095 with the same first fragment is valid initially; finish must reject it.
    bad.removeAll { it.size == 20 && it[5] == 15.toByte() && it[6] == 1.toByte() }
    for (bytes in bad) rejects(SessionFailure.MALFORMED) { GattReassembler(2).receive(bytes) }
    var now = 0L
    val timed = GattReassembler(2) { now }
    timed.receive(frames[0])
    now = 10000
    rejects(SessionFailure.EXPIRED) { timed.tick() }
    rejects(SessionFailure.MALFORMED) { GattReassembler.fragments(data, 0x100000000L, 20, 2) }
    assertTrue(GattReassembler.fragments(byteArrayOf(1), 0xffffffffL, 20, 2).isNotEmpty())
    rejects(SessionFailure.MALFORMED) { SessionEnvelope.decode(byteArrayOf(9, 0)) }
  }
}
