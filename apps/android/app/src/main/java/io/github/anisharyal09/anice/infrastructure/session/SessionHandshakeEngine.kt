// SPDX-License-Identifier: GPL-3.0-or-later
// Owns pinned EDHOC authentication and export with native identity validation at every trust boundary.
package io.github.anisharyal09.anice.infrastructure.session

import io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity
import io.github.anisharyal09.anice.infrastructure.identity.IdentityCrypto
import io.github.anisharyal09.anice.infrastructure.identity.IdentityService
import io.github.anisharyal09.anice.infrastructure.pairing.PeerTrustStore
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

data class SessionProof(val identity: DeviceIdentity, val der: ByteArray)

enum class HandshakeStage {
  NEW,
  MESSAGE_2,
  MESSAGE_3,
  MESSAGE_4,
  COMPLETE,
  CLOSED,
}

/** RFC 9528 method 0 / suite 5. No transport or durable state is owned here. */
class SessionHandshakeEngine
internal constructor(
  private val local: DeviceIdentity,
  private val responder: Boolean,
  private val trusted: () -> List<DeviceIdentity>,
  private val currentIdentity: () -> DeviceIdentity,
  private val signer: suspend (ByteArray) -> SessionProof,
  private val selectedPeer: DeviceIdentity? = null,
  private var ephemeral: SessionEphemeral? = SessionEphemeral.generate(),
  private val connectionId: ByteArray = SessionEphemeral.connectionId(),
  private val now: () -> Long = { System.nanoTime() / 1_000_000 },
) {
  private val mutex = Mutex()
  private val generation = AtomicLong(0)
  private val started = now()
  @Volatile
  var stage = HandshakeStage.NEW
    private set

  private var message1 = byteArrayOf()
  private var prk = byteArrayOf()
  private var th = byteArrayOf()
  private var peer: DeviceIdentity? = null
  private var prkExporter = byteArrayOf()

  init {
    local.validate()
    require(connectionId.size == 8)
    require(local.platform == if (responder) "macos" else "android")
    require(responder || selectedPeer?.platform == "macos")
  }

  private fun same(a: DeviceIdentity, b: DeviceIdentity) =
    a.deviceId == b.deviceId && a.fingerprint == b.fingerprint && a.publicKey == b.publicKey

  internal fun nextDeadline(): Long? = (started + 30000).takeIf {
    stage != HandshakeStage.COMPLETE && stage != HandshakeStage.CLOSED
  }

  internal fun checkTime() {
    if (stage == HandshakeStage.CLOSED) throw SessionException(SessionFailure.CANCELLED)
    if (stage != HandshakeStage.COMPLETE && now() - started >= 30000)
      throw SessionException(SessionFailure.EXPIRED)
  }

  private fun check() {
    checkTime()
    // Revalidate current identity and pinned trust even after handshake completion.
    if (!same(currentIdentity(), local)) throw SessionException(SessionFailure.CANCELLED)
    peer?.let {
      if (!same(resolve(SessionCrypto.kid(it)), it))
        throw SessionException(SessionFailure.UNTRUSTED_PEER)
    }
  }

  private fun resolve(kid: ByteArray): DeviceIdentity {
    // Resolve against all trusted peers before applying selection; ambiguity must fail.
    val matches =
      trusted()
        .filter { it.platform == if (responder) "android" else "macos" }
        .filter { java.security.MessageDigest.isEqual(SessionCrypto.kid(it), kid) }
    if (matches.size != 1) throw SessionException(SessionFailure.UNTRUSTED_PEER)
    val result = matches.single().validate()
    if (!responder && selectedPeer?.let { same(result, it) } != true)
      throw SessionException(SessionFailure.UNTRUSTED_PEER)
    return result
  }

  private suspend fun <T> operate(expected: HandshakeStage, block: suspend () -> T): T =
    withContext(Dispatchers.IO) {
      mutex.withLock {
        val op = generation.get()
        try {
          check()
          if (op != generation.get()) throw SessionException(SessionFailure.CANCELLED)
          if (stage != expected) throw SessionException(SessionFailure.STATE)
          val result = block()
          if (op != generation.get()) throw SessionException(SessionFailure.CANCELLED)
          result
        } catch (e: Exception) {
          retire()
          throw e
        }
      }
    }

  private fun fields(data: ByteArray, count: Int) =
    SessionCbor.decodeSequence(data).also {
      if (it.size != count) throw SessionException(SessionFailure.MALFORMED)
    }

  private suspend fun proof(input: ByteArray): ByteArray {
    val op = generation.get()
    // Protected signing may prompt or suspend; reject reset/cancelled results before use.
    val signed = signer(input)
    if (op != generation.get() || !same(signed.identity, local))
      throw SessionException(SessionFailure.CANCELLED)
    check()
    val raw = SessionSignature.derToCose(signed.der)
    if (
      !local.let {
        IdentityCrypto.verify(IdentityCrypto.decodeBase64(it.publicKey), input, signed.der)
      }
    )
      throw SessionException(SessionFailure.AUTHENTICATION)
    return raw
  }

  private fun verify(identity: DeviceIdentity, input: ByteArray, signature: ByteArray) {
    val valid =
      try {
        IdentityCrypto.verify(
          IdentityCrypto.decodeBase64(identity.publicKey),
          input,
          SessionSignature.coseToDer(signature),
        )
      } catch (_: SessionException) {
        false
      }
    if (!valid) throw SessionException(SessionFailure.AUTHENTICATION)
  }

  private fun derive(label: Long, context: ByteArray, length: Int) =
    SessionCrypto.kdf(prk, label, context, length)

  private fun crypt(bytes: ByteArray, encrypt: Boolean, final: Boolean = false): ByteArray {
    val key = derive(if (final) 8 else 3, th, 32)
    val iv = derive(if (final) 9 else 4, th, 12)
    return try {
      SessionCrypto.aead(key, iv, th, bytes, encrypt)
    } finally {
      key.fill(0)
      iv.fill(0)
    }
  }

  suspend fun initiate(): ByteArray =
    operate(HandshakeStage.NEW) {
      if (responder) throw SessionException(SessionFailure.STATE)
      resolve(SessionCrypto.kid(requireNotNull(selectedPeer)))
      message1 =
        SessionCbor.sequence(
          Cbor.Integer(0),
          Cbor.Integer(5),
          Cbor.Bytes(requireNotNull(ephemeral).publicX),
          Cbor.Bytes(connectionId),
        )
      stage = HandshakeStage.MESSAGE_2
      message1.copyOf()
    }

  suspend fun respond(message: ByteArray): ByteArray =
    operate(HandshakeStage.NEW) {
      if (!responder) throw SessionException(SessionFailure.STATE)
      val f = fields(message, 4)
      if (f[0] != Cbor.Integer(0) || f[1] != Cbor.Integer(5))
        throw SessionException(SessionFailure.UNSUPPORTED_PROFILE)
      val gx = f[2].bytes(32)
      f[3].bytes(8)
      message1 = message.copyOf()
      val key = requireNotNull(ephemeral)
      th =
        SessionCrypto.hash(
          SessionCbor.sequence(Cbor.Bytes(key.publicX), Cbor.Bytes(SessionCrypto.hash(message1)))
        )
      val z = key.agree(gx)
      prk =
        try {
          SessionCrypto.extract(th, z)
        } finally {
          z.fill(0)
          key.close()
          ephemeral = null
        }
      val context =
        SessionCbor.sequence(
          Cbor.Bytes(connectionId),
          SessionCrypto.idCredential(local),
          Cbor.Bytes(th),
          SessionCrypto.credential(local),
        )
      val mac = derive(2, context, 32)
      val signature = proof(SessionCrypto.signingInput(local, th, mac))
      val plaintext =
        SessionCbor.sequence(
          Cbor.Bytes(connectionId),
          Cbor.Bytes(SessionCrypto.kid(local)),
          Cbor.Bytes(signature),
        )
      val stream = derive(0, th, plaintext.size)
      val ciphertext =
        ByteArray(plaintext.size) { (plaintext[it].toInt() xor stream[it].toInt()).toByte() }
      stream.fill(0)
      th =
        SessionCrypto.hash(
          SessionCbor.encode(Cbor.Bytes(th)) +
            plaintext +
            SessionCbor.encode(SessionCrypto.credential(local))
        )
      stage = HandshakeStage.MESSAGE_3
      SessionCbor.encode(Cbor.Bytes(key.publicX + ciphertext))
    }

  suspend fun authenticateResponder(message: ByteArray): ByteArray =
    operate(HandshakeStage.MESSAGE_2) {
      val payload = SessionCbor.decode(message).bytes()
      if (payload.size != 32 + 109) throw SessionException(SessionFailure.MALFORMED)
      val gy = payload.copyOfRange(0, 32)
      th =
        SessionCrypto.hash(
          SessionCbor.sequence(Cbor.Bytes(gy), Cbor.Bytes(SessionCrypto.hash(message1)))
        )
      val key = requireNotNull(ephemeral)
      val z = key.agree(gy)
      prk =
        try {
          SessionCrypto.extract(th, z)
        } finally {
          z.fill(0)
          key.close()
          ephemeral = null
        }
      val stream = derive(0, th, payload.size - 32)
      val plaintext =
        ByteArray(stream.size) { (payload[it + 32].toInt() xor stream[it].toInt()).toByte() }
      stream.fill(0)
      val f = fields(plaintext, 3)
      val cr = f[0].bytes(8)
      val identity = resolve(f[1].bytes(32))
      peer = identity
      val context =
        SessionCbor.sequence(
          Cbor.Bytes(cr),
          SessionCrypto.idCredential(identity),
          Cbor.Bytes(th),
          SessionCrypto.credential(identity),
        )
      verify(
        identity,
        SessionCrypto.signingInput(identity, th, derive(2, context, 32)),
        f[2].bytes(64),
      )
      th =
        SessionCrypto.hash(
          SessionCbor.encode(Cbor.Bytes(th)) +
            plaintext +
            SessionCbor.encode(SessionCrypto.credential(identity))
        )
      val context3 =
        SessionCbor.sequence(
          SessionCrypto.idCredential(local),
          Cbor.Bytes(th),
          SessionCrypto.credential(local),
        )
      val signature = proof(SessionCrypto.signingInput(local, th, derive(6, context3, 32)))
      val p3 = SessionCbor.sequence(Cbor.Bytes(SessionCrypto.kid(local)), Cbor.Bytes(signature))
      val m3 = SessionCbor.encode(Cbor.Bytes(crypt(p3, true)))
      th =
        SessionCrypto.hash(
          SessionCbor.encode(Cbor.Bytes(th)) +
            p3 +
            SessionCbor.encode(SessionCrypto.credential(local))
        )
      stage = HandshakeStage.MESSAGE_4
      m3
    }

  suspend fun authenticateInitiator(message: ByteArray): ByteArray =
    operate(HandshakeStage.MESSAGE_3) {
      val ciphertext = SessionCbor.decode(message).bytes(116)
      val plaintext = crypt(ciphertext, false)
      val f = fields(plaintext, 2)
      val identity = resolve(f[0].bytes(32))
      peer = identity
      val context =
        SessionCbor.sequence(
          SessionCrypto.idCredential(identity),
          Cbor.Bytes(th),
          SessionCrypto.credential(identity),
        )
      verify(
        identity,
        SessionCrypto.signingInput(identity, th, derive(6, context, 32)),
        f[1].bytes(64),
      )
      th =
        SessionCrypto.hash(
          SessionCbor.encode(Cbor.Bytes(th)) +
            plaintext +
            SessionCbor.encode(SessionCrypto.credential(identity))
        )
      check()
      val m4 = SessionCbor.encode(Cbor.Bytes(crypt(byteArrayOf(), true, true)))
      complete()
      m4
    }

  suspend fun confirmResponder(message: ByteArray) =
    operate(HandshakeStage.MESSAGE_4) {
      val plaintext = crypt(SessionCbor.decode(message).bytes(), false, true)
      if (plaintext.isNotEmpty()) throw SessionException(SessionFailure.MALFORMED)
      check()
      complete()
    }

  private fun complete() {
    val out = derive(7, th, 32)
    prkExporter =
      try {
        SessionCrypto.kdf(out, 10, byteArrayOf(), 32)
      } finally {
        out.fill(0)
      }
    prk.fill(0)
    prk = byteArrayOf()
    message1.fill(0)
    message1 = byteArrayOf()
    stage = HandshakeStage.COMPLETE
  }

  suspend fun export(context: ByteArray, length: Int): ByteArray =
    operate(HandshakeStage.COMPLETE) { SessionCrypto.kdf(prkExporter, 32768, context, length) }

  // Canonical credentials are returned in wire-role order, independent of the local role.
  suspend fun bindings(): Pair<ByteArray, ByteArray> =
    operate(HandshakeStage.COMPLETE) {
      val remote = requireNotNull(peer)
      val initiator = if (responder) remote else local
      val server = if (responder) local else remote
      SessionCbor.encode(SessionCrypto.credential(initiator)) to
        SessionCbor.encode(SessionCrypto.credential(server))
    }

  suspend fun receiveError(message: ByteArray): Nothing =
    withContext(Dispatchers.IO) {
      mutex.withLock {
        try {
          if (stage == HandshakeStage.COMPLETE || stage == HandshakeStage.CLOSED)
            throw SessionException(SessionFailure.STATE)
          SessionError.validate(message)
          throw SessionException(SessionFailure.AUTHENTICATION)
        } finally {
          retire()
        }
      }
    }

  suspend fun checkDeadline() =
    withContext(Dispatchers.IO) {
      mutex.withLock {
        try {
          check()
        } catch (e: Exception) {
          retire()
          throw e
        }
      }
    }

  fun invalidate() {
    generation.incrementAndGet()
    stage = HandshakeStage.CLOSED
  }

  suspend fun close() {
    invalidate() // Invalidates a suspended signer before waiting for serialization.
    mutex.withLock { retire() }
  }

  private fun retire() {
    generation.incrementAndGet()
    stage = HandshakeStage.CLOSED
    ephemeral?.close()
    ephemeral = null
    listOf(prk, prkExporter, th, message1).forEach { it.fill(0) }
    prk = byteArrayOf()
    prkExporter = byteArrayOf()
    th = byteArrayOf()
    message1 = byteArrayOf()
    peer = null
  }

  companion object {
    suspend fun initiator(
      identity: IdentityService,
      trust: PeerTrustStore,
      selected: DeviceIdentity,
      now: () -> Long = { System.nanoTime() / 1_000_000 },
    ): SessionHandshakeEngine =
      withContext(Dispatchers.IO) {
        val local = identity.getOrCreateIdentity().identity
        SessionHandshakeEngine(
          local,
          false,
          { trust.list(local.fingerprint).map { it.peer } },
          { identity.getOrCreateIdentity().identity },
          { message ->
            identity.sign(message).let { SessionProof(it.snapshot.identity, it.signature) }
          },
          selected,
          now = now,
        )
      }
  }
}

object SessionError {
  fun generic(): ByteArray = SessionCbor.sequence(Cbor.Integer(1), Cbor.Text("Handshake failed"))

  fun validate(message: ByteArray) {
    val f = SessionCbor.decodeSequence(message)
    if (f.size != 2) throw SessionException(SessionFailure.MALFORMED)
    val valid =
      when (f[0]) {
        Cbor.Integer(1) -> f[1] is Cbor.Text && (f[1] as Cbor.Text).value.toByteArray().size <= 64
        Cbor.Integer(2) -> f[1] == Cbor.Integer(5)
        Cbor.Integer(3) -> f[1] == Cbor.Bool(true)
        else -> false
      }
    if (!valid) throw SessionException(SessionFailure.MALFORMED)
  }
}
