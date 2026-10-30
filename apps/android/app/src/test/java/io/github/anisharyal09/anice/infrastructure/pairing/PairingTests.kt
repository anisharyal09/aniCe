// SPDX-License-Identifier: GPL-3.0-or-later
// Checks pairing fixtures, directional encryption, replay rejection and framing bounds.
package io.github.anisharyal09.anice.infrastructure.pairing

import io.github.anisharyal09.anice.infrastructure.identity.IdentityCrypto
import java.math.BigInteger
import java.security.KeyFactory
import java.security.interfaces.ECPublicKey
import java.security.spec.ECPrivateKeySpec
import javax.crypto.KeyAgreement
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class PairingTests {
  private val vector =
      JSONObject(javaClass.classLoader!!.getResource("pairing-vectors.json")!!.readText())

  private fun hex(field: String) =
      vector.getString(field).chunked(2).map { it.toInt(16).toByte() }.toByteArray()

  @Test
  fun sharedQRAndDerivationVectors() {
    assertEquals(1, vector.getInt("fixtureVersion"))
    val qr = PairingQR.decode(vector.getString("qr"))
    assertArrayEquals(hex("secretHex"), qr.secret)
    assertArrayEquals(hex("rendezvousHex"), qr.rendezvous)
    assertArrayEquals(hex("fingerprintHex"), qr.fingerprint)
    assertArrayEquals(hex("fingerprintHex"), PairingCodec.hash(hex("serverPublicHex")))
    assertArrayEquals(hex("transcriptHashHex"), PairingCodec.hash(hex("transcriptHex")))
    val serverPublic = IdentityCrypto.publicKey(hex("serverPublicHex")) as ECPublicKey
    val clientPrivate =
        KeyFactory.getInstance("EC")
            .generatePrivate(ECPrivateKeySpec(BigInteger.ONE, serverPublic.params))
    val nativeShared =
        KeyAgreement.getInstance("ECDH").run {
          init(clientPrivate)
          doPhase(serverPublic, true)
          generateSecret()
        }
    assertArrayEquals(hex("sharedSecretHex"), nativeShared)
    assertEquals(vector.getString("qr"), qr.text())
    val key =
        PairingCodec.hkdf(
            hex("sharedSecretHex"),
            qr.secret,
            PairingCodec.fields("aniCe qr bootstrap v1".toByteArray(), hex("transcriptHashHex")),
        )
    assertArrayEquals(hex("bootstrapKeyHex"), key)
    assertArrayEquals(
        hex("serverMacHex"),
        PairingCodec.mac(
            PairingCodec.derive(key, "server-auth", hex("transcriptHashHex")),
            hex("transcriptHex"),
        ),
    )
    assertArrayEquals(
        hex("clientMacHex"),
        PairingCodec.mac(
            PairingCodec.derive(key, "client-auth", hex("transcriptHashHex")),
            hex("transcriptHex")),
    )
    val bad = vector.getJSONArray("invalidQR")
    assertTrue("Negative QR fixture inventory was reduced", bad.length() >= 3)
    repeat(bad.length()) { i ->
      reject { PairingQR.decode(bad.getJSONObject(i).getString("text")) }
    }
  }

  @Test
  fun directionalEncryptionAndReplay() {
    val c = PairingChannel(hex("bootstrapKeyHex"), hex("transcriptHex"), false)
    val s = PairingChannel(hex("bootstrapKeyHex"), hex("transcriptHex"), true)
    assertArrayEquals(hex("confirmationHex"), c.confirm())
    val bytes = c.seal(PairingCodec.message(12))
    assertArrayEquals(hex("encryptedApprovalHex"), bytes)
    assertArrayEquals(PairingCodec.message(12), s.open(bytes))
    reject { s.open(bytes) }
    val wrong = PairingChannel(ByteArray(32), hex("transcriptHex"), true)
    reject { wrong.open(bytes) }
    val tampered = bytes.clone().also { it[it.lastIndex] = (it.last().toInt() xor 1).toByte() }
    reject { PairingChannel(hex("bootstrapKeyHex"), hex("transcriptHex"), true).open(tampered) }
    c.destroy()
    s.destroy()
    wrong.destroy()
  }

  @Test
  fun defaultMtuLargeMessagesAndMalformedFragments() {
    for (capacity in listOf(20, 253, 514)) {
      val data = ByteArray(2048) { it.toByte() }
      val r = PairingReassembler()
      val frames = PairingReassembler.fragments(data, 0, capacity)
      frames.dropLast(1).forEach { assertNull(r.receive(it)) }
      assertArrayEquals(data, r.receive(frames.last()))
      reject { r.receive(frames.first()) }
    }
    val frames = PairingReassembler.fragments(ByteArray(40), 0, 20)
    reject { PairingReassembler().receive(frames[1]) }
    reject { PairingReassembler().receive(byteArrayOf(1, 0, 0, 0, 0, 0, 0, 1)) }
    reject { PairingReassembler.fragments(ByteArray(4097), 0, 20) }
    val r = PairingReassembler()
    repeat(8) { id ->
      PairingReassembler.fragments(ByteArray(4096), id.toLong(), 514).forEach { r.receive(it) }
    }
    reject { PairingReassembler.fragments(ByteArray(1), 8, 514).forEach { r.receive(it) } }
  }

  @Test
  fun boundedFieldParser() {
    reject { PairingCodec.parse(byteArrayOf(0, 0, 0, 7)) }
    reject { PairingCodec.parse(ByteArray(4097)) }
    reject { PairingCodec.unpack(PairingCodec.message(12, byteArrayOf(1)), 12, 0) }
  }

  @Test
  fun pairingUuidsMatchCanonicalLayout() {
    val writeUuid = java.util.UUID.fromString(PairingCodec.WRITE_UUID)
    val indicateUuid = java.util.UUID.fromString(PairingCodec.INDICATE_UUID)
    assertEquals("414e4953-4843-654a-494c-534149303903", writeUuid.toString().lowercase())
    assertEquals("414e4953-4843-654a-494c-534149303904", indicateUuid.toString().lowercase())
    assertEquals("414E4953-4843-654A-494C-534149303903", PairingCodec.WRITE_UUID)
    assertEquals("414E4953-4843-654A-494C-534149303904", PairingCodec.INDICATE_UUID)
  }

  private fun reject(body: () -> Unit) {
    try {
      body()
      fail("Malformed or unauthenticated input accepted")
    } catch (_: IllegalArgumentException) {} catch (_: IllegalStateException) {} catch (
        _: javax.crypto.AEADBadTagException) {}
  }
}
