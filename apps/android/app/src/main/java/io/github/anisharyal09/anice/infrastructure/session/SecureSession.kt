// SPDX-License-Identifier: GPL-3.0-or-later
// Owns bounded directional records, readiness and generation-fenced native validation.
package io.github.anisharyal09.anice.infrastructure.session

import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

// Diagnostic identifiers are process-local object identities, never session key material.
internal object SessionTiming {
  @Volatile var sink: ((String) -> Unit)? = null
  fun start(): Long = if (sink == null) 0 else System.nanoTime()
  fun end(owner: Any, event: String, start: Long, bytes: Int = 0) {
    if (start != 0L) sink?.invoke("record event=$event owner=${System.identityHashCode(owner)} bytes=$bytes duration_us=${(System.nanoTime() - start) / 1000}")
  }
}

enum class SessionProfile(val wire: Int, val maximumPlaintext: Int, val maximumEnvelope: Int, val exporterLabel: String) {
  STANDARD(1, 4000, 4096, "aniCe session"),
  BULK_PROBE(2, 4194304, 4194335, "aniCe bulk probe"),
  LAN_TRANSFER(3, 262144, 262175, "aniCe LAN transfer"),
}

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
    return ByteArray(12).also { nonce(iv, sequence, it) }
  }

  // iv XOR (0x00000000 || big-endian sequence) written into out; no mask allocation per record.
  internal fun nonce(iv: ByteArray, sequence: ULong, out: ByteArray) {
    System.arraycopy(iv, 0, out, 0, 4)
    val value = sequence.toLong()
    for (i in 0 until 8)
      out[4 + i] = (iv[4 + i].toInt() xor (value ushr (56 - i * 8)).toByte().toInt()).toByte()
  }

  fun seal(
    key: ByteArray,
    iv: ByteArray,
    id: ByteArray,
    direction: Int,
    kind: RecordKind,
    sequence: ULong,
    plaintext: ByteArray,
    profile: SessionProfile = SessionProfile.STANDARD,
  ): ByteArray = RecordCipher(key, iv, id, direction).seal(kind, sequence, plaintext, profile)

  fun open(
    key: ByteArray,
    iv: ByteArray,
    id: ByteArray,
    direction: Int,
    expected: ULong,
    record: ByteArray,
    profile: SessionProfile = SessionProfile.STANDARD,
  ): Pair<RecordKind, ByteArray> = RecordCipher(key, iv, id, direction).open(expected, record, profile)
}

/**
 * One AES-GCM state owned by a single serialized session direction. The provider cipher, the key
 * spec and the `id || direction` authentication suffix are built once per session rather than per
 * record; the header is written into the record buffer instead of being concatenated onto it.
 * Never shared between concurrent owners: SecureSession serializes each direction with its mutex.
 */
internal class RecordCipher(key: ByteArray, iv: ByteArray, id: ByteArray, direction: Int) {
  init {
    if (key.size != 32 || iv.size != 12 || id.size != 32 || direction !in 1..2)
      throw SessionException(SessionFailure.MALFORMED)
  }

  private val baseIV = iv.copyOf()
  private val keySpec = SecretKeySpec(key, "AES")
  private val aad = id + direction.toByte()
  private val header = ByteArray(14)
  private val cipher =
    try {
      Cipher.getInstance("AES/GCM/NoPadding")
    } catch (_: java.security.GeneralSecurityException) {
      throw SessionException(SessionFailure.AUTHENTICATION)
    }

  fun seal(kind: RecordKind, sequence: ULong, plaintext: ByteArray, profile: SessionProfile): ByteArray {
    if (plaintext.size > profile.maximumPlaintext || (kind != RecordKind.DATA && plaintext.isNotEmpty()))
      throw SessionException(SessionFailure.MALFORMED)
    header[0] = profile.wire.toByte()
    header[1] = kind.wire.toByte()
    putLong(header, 2, sequence.toLong())
    putInt(header, 10, plaintext.size)
    try {
      cipher.init(Cipher.ENCRYPT_MODE, keySpec, GCMParameterSpec(128, nonce(sequence)))
      // GCM concatenates successive AAD updates; two updates avoid materializing header + id.
      cipher.updateAAD(header)
      cipher.updateAAD(aad)
      val ciphertext = cipher.doFinal(plaintext, 0, plaintext.size)
      val record = ByteArray(plaintext.size + 30)
      System.arraycopy(header, 0, record, 0, 14)
      System.arraycopy(ciphertext, 0, record, 14, ciphertext.size)
      return record
    } catch (_: java.security.GeneralSecurityException) {
      throw SessionException(SessionFailure.AUTHENTICATION)
    }
  }

  fun open(expected: ULong, record: ByteArray, profile: SessionProfile): Pair<RecordKind, ByteArray> {
    if (record.size !in 30..(profile.maximumPlaintext + 30)) throw SessionException(SessionFailure.MALFORMED)
    if ((record[0].toInt() and 255) != profile.wire) throw SessionException(SessionFailure.MALFORMED)
    val kind =
      RecordKind.entries.firstOrNull { it.wire == (record[1].toInt() and 255) }
        ?: throw SessionException(SessionFailure.MALFORMED)
    val sequence = getLong(record, 2).toULong()
    val length = getInt(record, 10).toLong() and 0xffffffffL
    if (length > profile.maximumPlaintext || record.size.toLong() != 30 + length)
      throw SessionException(SessionFailure.MALFORMED)
    if (sequence != expected) throw SessionException(SessionFailure.AUTHENTICATION)
    val plain =
      try {
        cipher.init(Cipher.DECRYPT_MODE, keySpec, GCMParameterSpec(128, nonce(sequence)))
        cipher.updateAAD(record, 0, 14)
        cipher.updateAAD(aad)
        // The tag verifies synchronously; only authenticated plaintext can leave this method.
        cipher.doFinal(record, 14, record.size - 14)
      } catch (_: java.security.GeneralSecurityException) {
        throw SessionException(SessionFailure.AUTHENTICATION)
      }
    if (kind != RecordKind.DATA && plain.isNotEmpty()) throw SessionException(SessionFailure.MALFORMED)
    return kind to plain
  }

  private fun nonce(sequence: ULong) = ByteArray(12).also { SessionRecordCodec.nonce(baseIV, sequence, it) }

  private fun putLong(target: ByteArray, offset: Int, value: Long) {
    for (i in 0 until 8) target[offset + i] = (value ushr (56 - i * 8)).toByte()
  }

  private fun putInt(target: ByteArray, offset: Int, value: Int) {
    for (i in 0 until 4) target[offset + i] = (value ushr (24 - i * 8)).toByte()
  }

  private fun getLong(source: ByteArray, offset: Int): Long {
    var value = 0L
    for (i in 0 until 8) value = (value shl 8) or (source[offset + i].toLong() and 255)
    return value
  }

  private fun getInt(source: ByteArray, offset: Int): Int {
    var value = 0
    for (i in 0 until 4) value = (value shl 8) or (source[offset + i].toInt() and 255)
    return value
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
  private val profile: SessionProfile = SessionProfile.STANDARD,
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

  // One provider cipher per direction, built after the material above is validated. Each is used
  // only under its own mutex, so no record path performs a provider lookup or key import.
  private val sendCipher = RecordCipher(sendKey, sendIV, sessionID, if (responder) 2 else 1)
  private val receiveCipher = RecordCipher(receiveKey, receiveIV, sessionID, if (responder) 1 else 2)

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
    val validationStart = SessionTiming.start()
    try { validate() } finally { SessionTiming.end(this, "validation", validationStart) }
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
          if (plaintext.size > profile.maximumPlaintext || (kind != RecordKind.DATA && plaintext.isNotEmpty()))
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
          val sequence =
            transition(op) {
              if (kind == RecordKind.READY) stage = ChannelStage.READY_SENT
              sendSequence.reserve().also {
                reserved = true
              } // Burn before invoking encryption; failures are terminal.
            }
          val record = sendCipher.seal(kind, sequence, plaintext, profile)
          checkTime(op)
          val submissionStart = SessionTiming.start()
          try { submit(record) } finally { SessionTiming.end(this, "submission", submissionStart, record.size) }
          // Native validation runs before sealing and after awaited submission; the generation and
          // deadline fence bracketing encryption is check(op) above and checkTime(op) here.
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
          checkTime(op)
          if (received >= (1uL shl 20)) {
            transition(op) { expiration = SessionExpiry.RECORD_LIMIT }
            throw SessionException(SessionFailure.EXPIRED)
          }
          val decodeStart = SessionTiming.start()
          val result = receiveCipher.open(received, record, profile)
          SessionTiming.end(this, "open", decodeStart, record.size)
          // Native identity/trust validation gates delivery after synchronous tag verification.
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
      profile: SessionProfile = SessionProfile.STANDARD,
    ): SecureSession {
      // Binding order is initiator/responder on both peers; purpose/direction separate exports.
      val bindings = handshake.bindings()
      suspend fun export(direction: Int, purpose: String, length: Int) =
        handshake.export(
          SessionCbor.encode(
            Cbor.Array(
              listOf(Cbor.Text(profile.exporterLabel), Cbor.Integer(1)) +
                (if (profile == SessionProfile.STANDARD) emptyList() else listOf(Cbor.Integer(profile.maximumPlaintext.toLong()))) +
                listOf(Cbor.Bytes(bindings.first), Cbor.Bytes(bindings.second),
                  Cbor.Integer(direction.toLong()), Cbor.Text(purpose))
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
          profile,
        )
      } catch (e: Exception) {
        material.forEach { it.fill(0) }
        throw e
      }
    }
  }
}
