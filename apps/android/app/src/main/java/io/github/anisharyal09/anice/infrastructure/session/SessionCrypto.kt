// SPDX-License-Identifier: GPL-3.0-or-later
package io.github.anisharyal09.anice.infrastructure.session

import io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity
import io.github.anisharyal09.anice.infrastructure.identity.IdentityCrypto
import java.math.BigInteger
import java.security.AlgorithmParameters
import java.security.KeyFactory
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.PrivateKey
import java.security.SecureRandom
import java.security.spec.ECFieldFp
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECParameterSpec
import java.security.spec.ECPrivateKeySpec
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.Mac
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

object SessionCrypto {
  internal val parameters: ECParameterSpec by lazy {
    AlgorithmParameters.getInstance("EC")
      .apply { init(ECGenParameterSpec("secp256r1")) }
      .getParameterSpec(ECParameterSpec::class.java)
  }

  fun hash(bytes: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(bytes)

  fun extract(salt: ByteArray, ikm: ByteArray): ByteArray = mac(salt, ikm)

  private fun mac(key: ByteArray, data: ByteArray): ByteArray =
    Mac.getInstance("HmacSHA256").run {
      init(SecretKeySpec(key, "HmacSHA256"))
      doFinal(data)
    }

  fun kdf(prk: ByteArray, label: Long, context: ByteArray, length: Int): ByteArray {
    if (prk.size != 32 || length !in 1..4096) throw SessionException(SessionFailure.MALFORMED)
    val info =
      SessionCbor.sequence(Cbor.Integer(label), Cbor.Bytes(context), Cbor.Integer(length.toLong()))
    val output = ByteArray(length)
    var previous = ByteArray(0)
    var offset = 0
    var index = 1
    while (offset < length) {
      val next = mac(prk, previous + info + byteArrayOf(index++.toByte()))
      previous.fill(0)
      previous = next
      val count = minOf(32, length - offset)
      next.copyInto(output, offset, 0, count)
      offset += count
    }
    previous.fill(0)
    return output
  }

  // Only immutable device ID/key fields bind trust; display names do not enter the transcript.
  fun credential(identity: DeviceIdentity): Cbor {
    identity.validate()
    val point = IdentityCrypto.decodeBase64(identity.publicKey)
    fun n(value: Long) = Cbor.Integer(value)
    val key =
      Cbor.Map(
        listOf(
          n(1) to n(2),
          n(3) to n(-7),
          n(-1) to n(1),
          n(-2) to Cbor.Bytes(point.copyOfRange(1, 33)),
          n(-3) to Cbor.Bytes(point.copyOfRange(33, 65)),
        )
      )
    return Cbor.Map(
      listOf(n(2) to Cbor.Text(identity.deviceId), n(8) to Cbor.Map(listOf(n(1) to key)))
    )
  }

  fun kid(identity: DeviceIdentity): ByteArray = identity.kid()

  fun idCredential(identity: DeviceIdentity): Cbor =
    Cbor.Map(listOf(Cbor.Integer(4) to Cbor.Bytes(kid(identity))))

  fun signingInput(identity: DeviceIdentity, th: ByteArray, mac: ByteArray): ByteArray =
    SessionCbor.encode(
      Cbor.Array(
        listOf(
          Cbor.Text("Signature1"),
          Cbor.Bytes(SessionCbor.encode(idCredential(identity))),
          Cbor.Bytes(SessionCbor.sequence(Cbor.Bytes(th), credential(identity))),
          Cbor.Bytes(mac),
        )
      )
    )

  fun aad(th: ByteArray): ByteArray =
    SessionCbor.encode(
      Cbor.Array(listOf(Cbor.Text("Encrypt0"), Cbor.Bytes(byteArrayOf()), Cbor.Bytes(th)))
    )

  fun aead(
    key: ByteArray,
    iv: ByteArray,
    th: ByteArray,
    bytes: ByteArray,
    encrypt: Boolean,
  ): ByteArray {
    if (key.size != 32 || iv.size != 12) throw SessionException(SessionFailure.MALFORMED)
    try {
      val cipher = Cipher.getInstance("ChaCha20-Poly1305")
      cipher.init(
        if (encrypt) Cipher.ENCRYPT_MODE else Cipher.DECRYPT_MODE,
        SecretKeySpec(key, "ChaCha20"),
        IvParameterSpec(iv),
      )
      cipher.updateAAD(aad(th))
      return cipher.doFinal(bytes)
    } catch (_: javax.crypto.AEADBadTagException) {
      throw SessionException(SessionFailure.AUTHENTICATION)
    }
  }

  /** SEC1 decompression is wire conversion; scalar multiplication remains with JCA. */
  internal fun pointFromX(xBytes: ByteArray): ByteArray {
    if (xBytes.size != 32) throw SessionException(SessionFailure.MALFORMED)
    val p = (parameters.curve.field as ECFieldFp).p
    val x = BigInteger(1, xBytes)
    if (x >= p) throw SessionException(SessionFailure.MALFORMED)
    val rhs = x.pow(3).add(parameters.curve.a.multiply(x)).add(parameters.curve.b).mod(p)
    var y = rhs.modPow(p.add(BigInteger.ONE).shiftRight(2), p)
    if (y.multiply(y).mod(p) != rhs) throw SessionException(SessionFailure.MALFORMED)
    if (y.testBit(0)) y = p.subtract(y)
    val b = y.toByteArray().let { if (it.size == 33) it.copyOfRange(1, 33) else it }
    return byteArrayOf(4) + xBytes + ByteArray(32 - b.size) + b
  }
}

class SessionEphemeral
private constructor(private var privateKey: PrivateKey?, val publicX: ByteArray) {
  fun agree(peerX: ByteArray): ByteArray {
    val point = SessionCrypto.pointFromX(peerX)
    return KeyAgreement.getInstance("ECDH").run {
      init(privateKey ?: throw SessionException(SessionFailure.CANCELLED))
      doPhase(IdentityCrypto.publicKey(point), true)
      generateSecret()
    }
  }

  fun close() {
    privateKey = null
  }

  companion object {
    fun generate(): SessionEphemeral {
      val key =
        KeyPairGenerator.getInstance("EC")
          .apply { initialize(ECGenParameterSpec("secp256r1")) }
          .generateKeyPair()
      return fromPair(key)
    }

    private fun fromPair(pair: KeyPair) =
      SessionEphemeral(pair.private, IdentityCrypto.exportPublicKey(pair.public).copyOfRange(1, 33))

    internal fun fixture(privateBytes: ByteArray, publicBytes: ByteArray): SessionEphemeral {
      val scalar = BigInteger(1, privateBytes)
      require(scalar.signum() > 0 && scalar < SessionCrypto.parameters.order)
      val key =
        KeyFactory.getInstance("EC")
          .generatePrivate(ECPrivateKeySpec(scalar, SessionCrypto.parameters))
      return SessionEphemeral(
        key,
        IdentityCrypto.exportPublicKey(IdentityCrypto.publicKey(publicBytes)).copyOfRange(1, 33),
      )
    }

    fun connectionId(): ByteArray = ByteArray(8).also { SecureRandom().nextBytes(it) }
  }
}

/** Converts strict minimal DER to/from fixed-width COSE ES256, enforcing 1 <= r,s < n. */
object SessionSignature {
  private val order =
    BigInteger("ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551", 16)

  fun derToCose(der: ByteArray): ByteArray {
    fun fail(): Nothing = throw SessionException(SessionFailure.MALFORMED)
    if (der.size !in 8..72 || der[0] != 0x30.toByte() || der[1].toInt() != der.size - 2) fail()
    var offset = 2
    val parts =
      List(2) {
        if (offset + 2 > der.size || der[offset++] != 2.toByte()) fail()
        val size = der[offset++].toInt() and 255
        if (size !in 1..33 || offset + size > der.size) fail()
        val first = der[offset].toInt() and 255
        if (first >= 128 || (size > 1 && first == 0 && (der[offset + 1].toInt() and 128) == 0))
          fail()
        val scalar = BigInteger(1, der.copyOfRange(offset, offset + size))
        offset += size
        if (scalar.signum() == 0 || scalar >= order) fail()
        val bytes = scalar.toByteArray().let { if (it.size == 33) it.copyOfRange(1, 33) else it }
        ByteArray(32 - bytes.size) + bytes
      }
    if (offset != der.size) fail()
    return parts[0] + parts[1]
  }

  fun coseToDer(cose: ByteArray): ByteArray {
    if (cose.size != 64) throw SessionException(SessionFailure.MALFORMED)
    val parts =
      List(2) {
        val scalar = BigInteger(1, cose.copyOfRange(it * 32, (it + 1) * 32))
        if (scalar.signum() == 0 || scalar >= order)
          throw SessionException(SessionFailure.MALFORMED)
        val bytes = scalar.toByteArray()
        byteArrayOf(2, bytes.size.toByte()) + bytes
      }
    val body = parts[0] + parts[1]
    return byteArrayOf(0x30, body.size.toByte()) + body
  }
}
