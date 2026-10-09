// SPDX-License-Identifier: GPL-3.0-or-later
package io.github.anisharyal09.anice.infrastructure.session

import io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity
import io.github.anisharyal09.anice.infrastructure.identity.IdentityErrorKind
import io.github.anisharyal09.anice.infrastructure.identity.IdentityException
import java.util.Base64
import javax.crypto.Cipher
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class SessionTests {
  internal fun root(name: String = "session-vectors.json"): JSONObject =
    JSONObject(
      requireNotNull(javaClass.classLoader!!.getResourceAsStream("session/$name"))
        .bufferedReader()
        .use { it.readText() }
    )

  private fun hex(text: String) = text.chunked(2).map { it.toInt(16).toByte() }.toByteArray()

  private fun b(v: JSONObject, name: String) = hex(v.getString(name + "Hex"))

  private fun identity(v: JSONObject, name: String): DeviceIdentity {
    val r = v.getJSONObject(name)
    return DeviceIdentity(
        r.getString("deviceId"),
        "Fixture",
        r.getString("platform"),
        Base64.getEncoder().encodeToString(b(r, "public")),
        r.getString("fingerprintHex"),
      )
      .validate()
  }

  internal fun engine(
    v: JSONObject,
    server: Boolean,
    trusted: (() -> List<DeviceIdentity>)? = null,
    current: (() -> DeviceIdentity)? = null,
    signer: (suspend (ByteArray) -> SessionProof)? = null,
    now: () -> Long = { 0L },
  ): SessionHandshakeEngine {
    val local = identity(v, if (server) "responder" else "initiator")
    val peer = identity(v, if (server) "initiator" else "responder")
    val stage = if (server) 2 else 3
    return SessionHandshakeEngine(
      local,
      server,
      trusted ?: { listOf(peer) },
      current ?: { local },
      signer
        ?: { message ->
          assertArrayEquals(b(v, "signingInput$stage"), message)
          SessionProof(local, SessionSignature.coseToDer(b(v, "signature$stage")))
        },
      if (server) null else peer,
      SessionEphemeral.fixture(
        b(v, if (server) "y" else "x"),
        b(v, if (server) "yPublic" else "xPublic"),
      ),
      b(v, if (server) "cr" else "ci"),
      now,
    )
  }

  @Test fun freshReconnectNeverReusesHandshakeOrExporter() = runBlocking {
    val row = root().getJSONArray("valid").getJSONObject(0)
    val i = identity(row, "initiator"); val r = identity(row, "responder")
    fun fresh(server: Boolean): SessionHandshakeEngine {
      val local = if (server) r else i
      val peer = if (server) i else r
      val public = io.github.anisharyal09.anice.infrastructure.identity.IdentityCrypto.publicKey(Base64.getDecoder().decode(local.publicKey))
      val key = java.security.KeyFactory.getInstance("EC").generatePrivate(java.security.spec.ECPrivateKeySpec(
        java.math.BigInteger(1, b(row.getJSONObject(if (server) "responder" else "initiator"), "private")),
        (public as java.security.interfaces.ECPublicKey).params))
      return SessionHandshakeEngine(local, server, { listOf(peer) }, { local }, {
        val signer = java.security.Signature.getInstance("SHA256withECDSA")
        signer.initSign(key); signer.update(it); SessionProof(local, signer.sign())
      }, if (server) null else peer)
    }
    val messages = mutableListOf<ByteArray>(); val exports = mutableListOf<ByteArray>()
    repeat(3) {
      val c = fresh(false); val s = fresh(true)
      try {
        val m1 = c.initiate(); val m2 = s.respond(m1)
        val m3 = c.authenticateResponder(m2); val m4 = s.authenticateInitiator(m3)
        c.confirmResponder(m4)
        val context = b(row, "exportContext-session-id-0")
        val exported = c.export(context, 32)
        assertArrayEquals(exported, s.export(context, 32))
        assertTrue(messages.none { it.contentEquals(m1) }); assertTrue(exports.none { it.contentEquals(exported) })
        messages.add(m1); exports.add(exported)
      } finally { c.close(); s.close() }
      try { c.export(byteArrayOf(), 32); fail("Retired exporter remained accessible") }
      catch (error: SessionException) { assertEquals(SessionFailure.CANCELLED, error.reason) }
    }
    assertEquals(3, exports.size)
  }

  private fun reason(text: String) =
    when (text) {
      "malformed" -> SessionFailure.MALFORMED
      "authentication" -> SessionFailure.AUTHENTICATION
      "untrustedPeer" -> SessionFailure.UNTRUSTED_PEER
      "unsupportedProfile" -> SessionFailure.UNSUPPORTED_PROFILE
      else -> error("Unknown fixture reason")
    }

  private suspend fun rejects(reason: SessionFailure, operation: suspend () -> Unit) {
    try {
      operation()
      fail("Expected $reason")
    } catch (e: SessionException) {
      assertEquals(reason, e.reason)
    }
  }

  @Test
  fun independentCompleteHandshakesAndExporter() = runBlocking {
    Cipher.getInstance(
      "ChaCha20-Poly1305"
    ) // Missing desktop provider is a failure, never a silent skip.
    val fixtures = root()
    val rows = fixtures.getJSONArray("valid")
    assertTrue(rows.length() >= 3)
    assertTrue(fixtures.getJSONArray("invalid").length() >= 15)
    repeat(rows.length()) { index ->
      val v = rows.getJSONObject(index)
      val c = engine(v, false)
      val s = engine(v, true)
      assertArrayEquals(
        b(v, "credentialI"),
        SessionCbor.encode(SessionCrypto.credential(identity(v, "initiator"))),
      )
      assertArrayEquals(
        b(v, "credentialR"),
        SessionCbor.encode(SessionCrypto.credential(identity(v, "responder"))),
      )
      val m1 = c.initiate()
      assertArrayEquals(b(v, "message1"), m1)
      val m2 = s.respond(m1)
      assertArrayEquals(b(v, "message2"), m2)
      val m3 = c.authenticateResponder(m2)
      assertArrayEquals(b(v, "message3"), m3)
      rejects(SessionFailure.STATE) { engine(v, false).export(byteArrayOf(), 32) }
      val m4 = s.authenticateInitiator(m3)
      assertArrayEquals(b(v, "message4"), m4)
      c.confirmResponder(m4)
      assertEquals(HandshakeStage.COMPLETE, c.stage)
      assertEquals(HandshakeStage.COMPLETE, s.stage)
      for ((purpose, direction, length) in
        listOf(
          Triple("key", 1, 32),
          Triple("key", 2, 32),
          Triple("iv", 1, 12),
          Triple("iv", 2, 12),
          Triple("session-id", 0, 32),
        )) {
        val context = b(v, "exportContext-$purpose-$direction")
        assertArrayEquals(b(v, "export-$purpose-$direction"), c.export(context, length))
        assertArrayEquals(b(v, "export-$purpose-$direction"), s.export(context, length))
      }
      c.close()
      s.close()
      rejects(SessionFailure.CANCELLED) { c.export(byteArrayOf(), 32) }
    }
  }

  @Test
  fun allNegativeFixturesFailClosedWithTypedReasons() = runBlocking {
    val fixtures = root()
    val v = fixtures.getJSONArray("valid").getJSONObject(0)
    val rows = fixtures.getJSONArray("invalid")
    assertTrue(rows.length() >= 15)
    repeat(rows.length()) { i ->
      val row = rows.getJSONObject(i)
      val stage = row.getInt("stage")
      val e = engine(v, stage == 1 || stage == 3)
      when (stage) {
        2 -> e.initiate()
        3 -> e.respond(b(v, "message1"))
        4 -> {
          e.initiate()
          e.authenticateResponder(b(v, "message2"))
        }
      }
      rejects(reason(row.getString("reason"))) {
        when (stage) {
          1 -> e.respond(b(row, "wire"))
          2 -> e.authenticateResponder(b(row, "wire"))
          3 -> e.authenticateInitiator(b(row, "wire"))
          4 -> e.confirmResponder(b(row, "wire"))
          else -> error("Invalid fixture stage")
        }
      }
      assertEquals(row.getString("name"), HandshakeStage.CLOSED, e.stage)
      rejects(SessionFailure.CANCELLED) { e.export(byteArrayOf(), 32) }
    }
  }

  @Test
  fun publishedRfcComponentsAreIndependentOracles() {
    val v = root("rfc9529-components.json")
    assertArrayEquals(
      b(v, "th2"),
      SessionCrypto.hash(
        SessionCbor.sequence(
          Cbor.Bytes(b(v, "gy")),
          Cbor.Bytes(SessionCrypto.hash(b(v, "message1"))),
        )
      ),
    )
    assertArrayEquals(b(v, "prk"), SessionCrypto.extract(b(v, "th2"), b(v, "z")))
    assertArrayEquals(b(v, "mac2"), SessionCrypto.kdf(b(v, "prk"), 2, b(v, "context2"), 32))
    assertArrayEquals(
      b(v, "keystream2"),
      SessionCrypto.kdf(b(v, "prk"), 0, b(v, "th2"), b(v, "plaintext2").size),
    )
    assertArrayEquals(
      b(v, "th3"),
      SessionCrypto.hash(
        SessionCbor.encode(Cbor.Bytes(b(v, "th2"))) + b(v, "plaintext2") + b(v, "credentialR")
      ),
    )
    assertArrayEquals(
      b(v, "th4"),
      SessionCrypto.hash(
        SessionCbor.encode(Cbor.Bytes(b(v, "th3"))) + b(v, "plaintext3") + b(v, "credentialI")
      ),
    )
    assertArrayEquals(b(v, "prkOut"), SessionCrypto.kdf(b(v, "prk"), 7, b(v, "th4"), 32))
    assertArrayEquals(b(v, "prkExporter"), SessionCrypto.kdf(b(v, "prkOut"), 10, byteArrayOf(), 32))
  }

  @Test
  fun cborBoundsCanonicalOrderAndText() = runBlocking {
    val values =
      listOf(
        Cbor.Text("Identity \uD83D\uDD12"),
        Cbor.Bool(true),
        Cbor.Bool(false),
        Cbor.Integer(Long.MIN_VALUE),
        Cbor.Integer(Long.MAX_VALUE),
      )
    values.forEach { assertEquals(it, SessionCbor.decode(SessionCbor.encode(it))) }
    val valid = SessionCbor.encode(Cbor.Bytes(ByteArray(4093)))
    assertEquals(4096, valid.size)
    assertEquals(Cbor.Bytes(ByteArray(4093)), SessionCbor.decode(valid))
    val invalid =
      listOf(
        "1800",
        "1bffffffffffffffff",
        "5f40ff",
        "a201000100",
        "a202000100",
        "61ff",
        "f6",
        "d840",
        "8201",
        "a1180100",
        "0000",
        "580100",
      )
    for (wire in invalid) rejects(SessionFailure.MALFORMED) { SessionCbor.decode(hex(wire)) }
    rejects(SessionFailure.MALFORMED) { SessionCbor.encode(Cbor.Bytes(ByteArray(4094))) }
    rejects(SessionFailure.MALFORMED) { SessionCbor.decode(ByteArray(4097)) }
    assertEquals(512, SessionCbor.decodeSequence(ByteArray(512)).size)
    var nested: Cbor = Cbor.Integer(0)
    repeat(8) { nested = Cbor.Array(listOf(nested)) }
    assertEquals(nested, SessionCbor.decode(SessionCbor.encode(nested)))
    rejects(SessionFailure.MALFORMED) {
      SessionCbor.decode(ByteArray(9) { 0x81.toByte() } + byteArrayOf(0))
    }
    rejects(SessionFailure.MALFORMED) { SessionCbor.decodeSequence(ByteArray(513)) }
    val map =
      Cbor.Map(listOf(Cbor.Integer(8) to Cbor.Bool(true), Cbor.Integer(2) to Cbor.Bool(false)))
    assertEquals(
      "a202f408f5",
      SessionCbor.encode(map).joinToString("") { "%02x".format(it.toInt() and 255) },
    )
    rejects(SessionFailure.MALFORMED) {
      SessionCbor.encode(
        Cbor.Map(
          listOf(
            Cbor.Bytes(byteArrayOf(1)) to Cbor.Bool(true),
            Cbor.Bytes(byteArrayOf(1)) to Cbor.Bool(false),
          )
        )
      )
    }
  }

  @Test
  fun signatureRangeAndPaddingRejections() = runBlocking {
    val order = hex("ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551")
    for (scalar in
      listOf(
        ByteArray(31) + byteArrayOf(1),
        byteArrayOf(0x80.toByte()) + ByteArray(31),
        ByteArray(1) + ByteArray(31) { 0x7f },
        order.copyOf().also { it[31] = 0x50 },
      )) {
      val raw = scalar + scalar
      assertArrayEquals(raw, SessionSignature.derToCose(SessionSignature.coseToDer(raw)))
    }
    for (raw in
      listOf(
        ByteArray(64),
        order + ByteArray(31) + byteArrayOf(1),
        ByteArray(32) { 0xff.toByte() } + ByteArray(31) + byteArrayOf(1),
        ByteArray(63),
        ByteArray(65),
      )) rejects(SessionFailure.MALFORMED) { SessionSignature.coseToDer(raw) }
    for (der in
      listOf(
        "3006020100020101",
        "300702020001020101",
        "3006020180020101",
        "300602010102010100",
        "308106020101020101",
      )) rejects(SessionFailure.MALFORMED) { SessionSignature.derToCose(hex(der)) }
  }

  @Test
  fun revocationAmbiguityWrongSelectionDeadlineAndDuplicateMessages() = runBlocking {
    val v = root().getJSONArray("valid").getJSONObject(0)
    val peer = identity(v, "responder")
    var peers = listOf(peer)
    val c = engine(v, false, trusted = { peers })
    c.initiate()
    c.authenticateResponder(b(v, "message2"))
    peers = emptyList()
    rejects(SessionFailure.UNTRUSTED_PEER) { c.confirmResponder(b(v, "message4")) }
    rejects(SessionFailure.UNTRUSTED_PEER) {
      engine(v, false, trusted = { listOf(peer, peer) }).initiate()
    }
    val wrong = peer.copy(deviceId = "00000000-0000-4000-9000-000000000999")
    rejects(SessionFailure.UNTRUSTED_PEER) {
      engine(v, false, trusted = { listOf(wrong) }).initiate()
    }
    var now = 0L
    val timed = engine(v, false, now = { now })
    timed.initiate()
    now = 30_000
    rejects(SessionFailure.EXPIRED) { timed.checkDeadline() }
    val replay = engine(v, false)
    replay.initiate()
    replay.authenticateResponder(b(v, "message2"))
    rejects(SessionFailure.STATE) { replay.authenticateResponder(b(v, "message2")) }
  }

  @Test
  fun cancellationInvalidatesDelayedSigningAndIdentityReplacement() = runBlocking {
    val v = root().getJSONArray("valid").getJSONObject(0)
    val local = identity(v, "responder")
    val entered = CompletableDeferred<Unit>()
    val resume = CompletableDeferred<Unit>()
    val engine =
      engine(
        v,
        true,
        signer = {
          entered.complete(Unit)
          resume.await()
          SessionProof(local, SessionSignature.coseToDer(b(v, "signature2")))
        },
      )
    val operation = async { rejects(SessionFailure.CANCELLED) { engine.respond(b(v, "message1")) } }
    entered.await()
    val closing = async(start = CoroutineStart.UNDISPATCHED) { engine.close() }
    resume.complete(Unit)
    operation.await()
    closing.await()
    assertEquals(HandshakeStage.CLOSED, engine.stage)
    val replacement = local.copy(deviceId = "00000000-0000-4000-9000-000000000999")
    rejects(SessionFailure.CANCELLED) {
      engine(
          v,
          true,
          signer = { SessionProof(replacement, SessionSignature.coseToDer(b(v, "signature2"))) },
        )
        .respond(b(v, "message1"))
    }
  }

  @Test
  fun signingFailuresRetireAndIdentityChangesAreRejected() = runBlocking {
    val v = root().getJSONArray("valid").getJSONObject(0)
    for (server in listOf(true, false)) {
      var signs = 0
      val e =
        engine(
          v,
          server,
          signer = {
            signs++
            throw IdentityException(IdentityErrorKind.STORAGE_UNAVAILABLE)
          },
        )
      try {
        if (server) e.respond(b(v, "message1"))
        else {
          e.initiate()
          e.authenticateResponder(b(v, "message2"))
        }
        fail("Signing failure was ignored")
      } catch (error: IdentityException) {
        assertEquals(IdentityErrorKind.STORAGE_UNAVAILABLE, error.kind)
      }
      assertEquals(1, signs)
      assertEquals(HandshakeStage.CLOSED, e.stage)
      rejects(SessionFailure.CANCELLED) { e.export(byteArrayOf(), 32) }
    }
    var changed = false
    val original = identity(v, "initiator")
    val e =
      engine(
        v,
        false,
        current = {
          if (changed) original.copy(deviceId = "00000000-0000-4000-9000-000000000999")
          else original
        },
      )
    e.initiate()
    changed = true
    rejects(SessionFailure.CANCELLED) { e.authenticateResponder(b(v, "message2")) }
    assertEquals(HandshakeStage.CLOSED, e.stage)
  }

  @Test
  fun errorsAreBoundedAndTerminal() = runBlocking {
    SessionError.validate(SessionError.generic())
    SessionError.validate(SessionCbor.sequence(Cbor.Integer(3), Cbor.Bool(true)))
    SessionError.validate(SessionCbor.sequence(Cbor.Integer(2), Cbor.Integer(5)))
    for (wire in listOf("0000", "03f4", "0202", "01f5", "03f500")) rejects(
      SessionFailure.MALFORMED
    ) {
      SessionError.validate(hex(wire))
    }
    val e = engine(root().getJSONArray("valid").getJSONObject(0), false)
    e.initiate()
    rejects(SessionFailure.AUTHENTICATION) { e.receiveError(SessionError.generic()) }
    assertEquals(HandshakeStage.CLOSED, e.stage)
  }
}
