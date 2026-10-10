// SPDX-License-Identifier: GPL-3.0-or-later
package io.github.anisharyal09.anice.infrastructure.session

import java.nio.ByteBuffer
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

enum class RecordKind(val wire: Int) {
  READY(1),
  READY_ACK(2),
  DATA(3),
  CLOSE(4),
}

enum class ChannelStage {
  WAITING,
  READY_SENT,
  READY_RECEIVED,
  SECURED,
  CLOSED,
}

enum class SessionExpiry {
  READINESS,
  IDLE,
  LIFETIME,
  RECORD_LIMIT,
}

class SessionBackpressure : Exception("Session queue is full")

// Counters never wrap or roll back; exhausting the per-key budget requires fresh EDHOC.
internal class RecordSequence {
  var value = 0uL
    private set

  fun reserve(): ULong {
    if (value >= (1uL shl 20)) throw SessionException(SessionFailure.EXPIRED)
    return value++
  }

  fun advance() {
    reserve()
  }
}

// Stateless wire codec; SecureSession owns sequence consumption and failure retirement.
object SessionRecordCodec {
  fun nonce(iv: ByteArray, sequence: ULong): ByteArray {
    if (iv.size != 12) throw SessionException(SessionFailure.MALFORMED)
    val mask = ByteBuffer.allocate(12).putInt(0).putLong(sequence.toLong()).array()
    return ByteArray(12) { (iv[it].toInt() xor mask[it].toInt()).toByte() }
  }

  fun seal(
    key: ByteArray,
    iv: ByteArray,
    id: ByteArray,
    direction: Int,
    kind: RecordKind,
    sequence: ULong,
    plaintext: ByteArray,
  ): ByteArray {
    if (
      key.size != 32 ||
        iv.size != 12 ||
        id.size != 32 ||
        direction !in 1..2 ||
        plaintext.size > 4000 ||
        (kind != RecordKind.DATA && plaintext.isNotEmpty())
    )
      throw SessionException(SessionFailure.MALFORMED)
    val header =
      ByteBuffer.allocate(14)
        .put(1)
        .put(kind.wire.toByte())
        .putLong(sequence.toLong())
        .putInt(plaintext.size)
        .array()
    return header +
      crypt(key, nonce(iv, sequence), header + id + direction.toByte(), plaintext, true)
  }

  fun open(
    key: ByteArray,
    iv: ByteArray,
    id: ByteArray,
    direction: Int,
    expected: ULong,
    record: ByteArray,
  ): Pair<RecordKind, ByteArray> {
    if (key.size != 32 || iv.size != 12 || id.size != 32 || direction !in 1..2)
      throw SessionException(SessionFailure.MALFORMED)
    if (record.size !in 30..4030) throw SessionException(SessionFailure.MALFORMED)
    val h = ByteBuffer.wrap(record)
    if (h.get().toInt() != 1) throw SessionException(SessionFailure.MALFORMED)
    val kind =
      RecordKind.entries.firstOrNull { it.wire == h.get(1).toInt() }
        ?: throw SessionException(SessionFailure.MALFORMED)
    h.position(2)
    val sequence = h.long.toULong()
    val length = h.int.toLong() and 0xffffffffL
    if (length > 4000 || record.size.toLong() != 30 + length)
      throw SessionException(SessionFailure.MALFORMED)
    if (sequence != expected) throw SessionException(SessionFailure.AUTHENTICATION)
    val plain =
      crypt(
        key,
        nonce(iv, sequence),
        record.copyOfRange(0, 14) + id + direction.toByte(),
        record.copyOfRange(14, record.size),
        false,
      )
    if (kind != RecordKind.DATA && plain.isNotEmpty())
      throw SessionException(SessionFailure.MALFORMED)
    return kind to plain
  }

  private fun crypt(
    key: ByteArray,
    nonce: ByteArray,
    aad: ByteArray,
    data: ByteArray,
    encrypt: Boolean,
  ): ByteArray {
    try {
      val cipher = Cipher.getInstance("AES/GCM/NoPadding")
      cipher.init(
        if (encrypt) Cipher.ENCRYPT_MODE else Cipher.DECRYPT_MODE,
        SecretKeySpec(key, "AES"),
        GCMParameterSpec(128, nonce),
      )
      cipher.updateAAD(aad)
      return cipher.doFinal(data)
    } catch (e: java.security.GeneralSecurityException) {
      throw SessionException(SessionFailure.AUTHENTICATION)
    }
  }
}

/**
 * One owner serializes each seal through transport submission. Close invalidates suspended work.
 */
class SecureSession
internal constructor(
  private val responder: Boolean,
  private val sendKey: ByteArray,
  private val receiveKey: ByteArray,
  private val sendIV: ByteArray,
  private val receiveIV: ByteArray,
  private val sessionID: ByteArray,
  private val validate: suspend () -> Unit,
  private val capacity: suspend (Int) -> Boolean,
  private val submit: suspend (ByteArray) -> Unit,
  private val now: () -> Long = { System.nanoTime() / 1_000_000 },
) {
  private val stateLock = Any()
  private val sendMutex = Mutex()
  private val receiveMutex = Mutex()
  private val generation = java.util.concurrent.atomic.AtomicLong()
  private val started = now()
  @Volatile private var activity = started
  @Volatile
  var expiration: SessionExpiry? = null
    private set

  private val sendSequence = RecordSequence()
  private val receiveSequence = RecordSequence()
  internal val sent
    get() = sendSequence.value

  internal val received
    get() = receiveSequence.value

  internal fun renewalReason(): Long? = renewalReason(now() - started, sent, received)


  @Volatile
  var stage = ChannelStage.WAITING
    private set

  init {
    require(
      sendKey.size == 32 &&
        receiveKey.size == 32 &&
        sendIV.size == 12 &&
        receiveIV.size == 12 &&
        sessionID.size == 32
    )
  }

  suspend fun tick() =
    withContext(Dispatchers.IO) {
      try {
        check(generation.get())
      } catch (e: Exception) {
        close()
        throw e
      }
    }

  private fun <T> transition(op: Long, action: () -> T): T =
    synchronized(stateLock) {
      if (stage == ChannelStage.CLOSED || generation.get() != op)
        throw SessionException(SessionFailure.CANCELLED)
      action()
    }

  internal fun nextDeadline(renew: Boolean = false): Long? = synchronized(stateLock) {
    if (stage == ChannelStage.CLOSED) null else listOfNotNull(
      started + 3600000,
      (started + 10000).takeIf { stage != ChannelStage.SECURED },
      activity + 120000,
      (if (renewalReason() != null) now() else started + 3300000).takeIf { renew },
    ).minOrNull()
  }

  internal fun checkDeadlines() {
    try { checkTime(generation.get()) } catch (e: SessionException) { close(); throw e }
  }

  private suspend fun check(op: Long) {
    checkTime(op)
    validate()
    if (stage == ChannelStage.CLOSED || generation.get() != op)
      throw SessionException(SessionFailure.CANCELLED)
  }

  private fun checkTime(op: Long) {
    if (stage == ChannelStage.CLOSED || generation.get() != op)
      throw SessionException(SessionFailure.CANCELLED)
    val time = now()
    val expired =
      when {
        time - started >= 3600000 -> SessionExpiry.LIFETIME
        stage != ChannelStage.SECURED && time - started >= 10000 -> SessionExpiry.READINESS
        time - activity >= 120000 -> SessionExpiry.IDLE
        else -> null
      }
    if (expired != null) {
      transition(op) { expiration = expired }
      throw SessionException(SessionFailure.EXPIRED)
    }
  }

  private suspend fun <T> serializeSend(block: suspend () -> T): T {
    if (!sendMutex.tryLock()) throw SessionBackpressure()
    try {
      return block()
    } finally {
      sendMutex.unlock()
    }
  }

  suspend fun send(kind: RecordKind, plaintext: ByteArray = byteArrayOf()) =
    withContext(Dispatchers.IO) {
      serializeSend {
        val op = generation.get()
        var reserved = false
        try {
          check(op)
          if (plaintext.size > 4000 || (kind != RecordKind.DATA && plaintext.isNotEmpty()))
            throw SessionException(SessionFailure.MALFORMED)
          val permitted =
            when (kind) {
              RecordKind.READY -> !responder && stage == ChannelStage.WAITING
              RecordKind.READY_ACK -> responder && stage == ChannelStage.READY_RECEIVED
              RecordKind.DATA,
              RecordKind.CLOSE -> stage == ChannelStage.SECURED
            }
          if (!permitted) throw SessionException(SessionFailure.STATE)
          if (sent >= (1uL shl 20)) {
            transition(op) { expiration = SessionExpiry.RECORD_LIMIT }
            throw SessionException(SessionFailure.EXPIRED)
          }
          // Include the record header, tag and envelope byte before consuming a nonce.
          if (!capacity(plaintext.size + 31)) throw SessionBackpressure()
          check(op)
          val sequence =
            transition(op) {
              if (kind == RecordKind.READY) stage = ChannelStage.READY_SENT
              sendSequence.reserve().also {
                reserved = true
              } // Burn before invoking encryption; failures are terminal.
            }
          val record =
            SessionRecordCodec.seal(
              sendKey,
              sendIV,
              sessionID,
              if (responder) 2 else 1,
              kind,
              sequence,
              plaintext,
            )
          check(op)
          submit(record)
          check(op)
          transition(op) {
            activity = now()
            if (kind == RecordKind.READY_ACK) stage = ChannelStage.SECURED
            if (kind == RecordKind.CLOSE) close()
          }
        } catch (e: SessionBackpressure) {
          if (reserved) {
            close()
            throw SessionException(SessionFailure.STATE)
          }
          throw e
        } catch (e: Exception) {
          close()
          throw e
        }
      }
    }

  suspend fun receive(record: ByteArray): Pair<RecordKind, ByteArray> =
    withContext(Dispatchers.IO) {
      receiveMutex.withLock {
        val op = generation.get()
        try {
          check(op)
          if (received >= (1uL shl 20)) {
            transition(op) { expiration = SessionExpiry.RECORD_LIMIT }
            throw SessionException(SessionFailure.EXPIRED)
          }
          val result =
            SessionRecordCodec.open(
              receiveKey,
              receiveIV,
              sessionID,
              if (responder) 1 else 2,
              received,
              record,
            )
          check(op)
          val allowed =
            when (result.first) {
              RecordKind.READY -> responder && stage == ChannelStage.WAITING
              RecordKind.READY_ACK -> !responder && stage == ChannelStage.READY_SENT
              RecordKind.DATA,
              RecordKind.CLOSE -> stage == ChannelStage.SECURED
            }
          transition(op) {
            if (!allowed) throw SessionException(SessionFailure.STATE)
            // Advance only after tag verification and a valid readiness/state transition.
            receiveSequence.advance()
            activity = now()
            when (result.first) {
              RecordKind.READY -> stage = ChannelStage.READY_RECEIVED
              RecordKind.READY_ACK -> stage = ChannelStage.SECURED
              RecordKind.CLOSE -> close()
              else -> Unit
            }
          }
          result
        } catch (e: Exception) {
          close()
          throw e
        }
      }
    }

  fun close() =
    synchronized(stateLock) {
      generation.incrementAndGet()
      stage = ChannelStage.CLOSED
      // Best effort: wiping owned arrays cannot erase JVM or provider-owned copies.
      listOf(sendKey, receiveKey, sendIV, receiveIV, sessionID).forEach { it.fill(0) }
    }

  companion object {
    // Leave 1,024 records and five minutes for retirement; these margins never extend hard limits.
    internal fun renewalReason(age: Long, sent: ULong, received: ULong): Long? = when {
      age >= 55 * 60_000L -> 1
      sent >= (1uL shl 20) - 1024u || received >= (1uL shl 20) - 1024u -> 2
      else -> null
    }
    suspend fun fromHandshake(
      handshake: SessionHandshakeEngine,
      responder: Boolean,
      capacity: suspend (Int) -> Boolean,
      submit: suspend (ByteArray) -> Unit,
      now: () -> Long = { System.nanoTime() / 1_000_000 },
    ): SecureSession {
      // Binding order is initiator/responder on both peers; purpose/direction separate exports.
      val bindings = handshake.bindings()
      suspend fun export(direction: Int, purpose: String, length: Int) =
        handshake.export(
          SessionCbor.encode(
            Cbor.Array(
              listOf(
                Cbor.Text("aniCe session"),
                Cbor.Integer(1),
                Cbor.Bytes(bindings.first),
                Cbor.Bytes(bindings.second),
                Cbor.Integer(direction.toLong()),
                Cbor.Text(purpose),
              )
            )
          ),
          length,
        )
      val i = if (responder) 2 else 1
      val r = if (responder) 1 else 2
      val material = mutableListOf<ByteArray>()
      try {
        material += export(i, "key", 32)
        material += export(r, "key", 32)
        material += export(i, "iv", 12)
        material += export(r, "iv", 12)
        material += export(0, "session-id", 32)
        return SecureSession(
          responder,
          material[0],
          material[1],
          material[2],
          material[3],
          material[4],
          { handshake.checkDeadline() },
          capacity,
          submit,
          now,
        )
      } catch (e: Exception) {
        material.forEach { it.fill(0) }
        throw e
      }
    }
  }
}
