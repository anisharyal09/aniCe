// SPDX-License-Identifier: GPL-3.0-or-later
package io.github.anisharyal09.anice.infrastructure.identity

import java.math.BigInteger
import java.security.AlgorithmParameters
import java.security.KeyFactory
import java.security.MessageDigest
import java.security.PublicKey
import java.security.Signature
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECParameterSpec
import java.security.spec.ECPoint
import java.security.spec.ECPublicKeySpec
import java.util.Base64
import java.util.UUID
import org.json.JSONObject

/** Public identity defined by protocol/schemas/identity.schema.json. */
data class DeviceIdentity(
    val deviceId: String,
    val deviceName: String,
    val platform: String,
    val publicKey: String,
    val fingerprint: String,
    val identitySchemaVersion: Int = 1,
    val algorithm: String = "ECDSA_P256_SHA256",
) {
    fun toJson(): JSONObject = JSONObject().put("identitySchemaVersion", identitySchemaVersion)
        .put("deviceId", deviceId).put("deviceName", deviceName).put("platform", platform)
        .put("algorithm", algorithm).put("publicKey", publicKey).put("fingerprint", fingerprint)

    @Volatile @Transient private var validated: Boolean = false
    @Volatile @Transient private var cachedKid: ByteArray? = null

    fun validate(): DeviceIdentity {
        if (validated) return this
        require(identitySchemaVersion == 1 && algorithm == "ECDSA_P256_SHA256")
        require(UUID_V4.matches(deviceId))
        require(deviceName.isNotBlank() && deviceName == deviceName.trim())
        require(deviceName.codePointCount(0, deviceName.length) <= 64)
        require(platform == "android" || platform == "macos")
        val bytes = IdentityCrypto.decodeBase64(publicKey)
        IdentityCrypto.publicKey(bytes)
        require(fingerprint == IdentityCrypto.fingerprint(bytes))
        validated = true
        return this
    }

    fun kid(): ByteArray {
        validate()
        return cachedKid ?: MessageDigest.getInstance("SHA-256").digest(IdentityCrypto.decodeBase64(publicKey)).also { cachedKid = it }
    }

    companion object {
        private val UUID_V4 = Regex("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")

        fun newId(): String = UUID.randomUUID().toString()

        fun displayName(value: String): String {
            val trimmed = value.trim().ifEmpty { "Android" }
            val count = trimmed.codePointCount(0, trimmed.length).coerceAtMost(64)
            return trimmed.substring(0, trimmed.offsetByCodePoints(0, count)).trimEnd()
        }

        fun fromJson(json: JSONObject): DeviceIdentity {
            require(json.keys().asSequence().toSet() == setOf(
                "identitySchemaVersion", "deviceId", "deviceName", "platform", "algorithm", "publicKey", "fingerprint",
            ))
            require(json.get("identitySchemaVersion") is Int)
            fun text(name: String): String = json.get(name) as? String ?: error("Invalid $name")
            return DeviceIdentity(text("deviceId"), text("deviceName"), text("platform"),
                text("publicKey"), text("fingerprint"), json.getInt("identitySchemaVersion"), text("algorithm")).validate()
        }
    }
}

object IdentityCrypto {
    private val parameters: ECParameterSpec by lazy {
        AlgorithmParameters.getInstance("EC").apply { init(ECGenParameterSpec("secp256r1")) }
            .getParameterSpec(ECParameterSpec::class.java)
    }

    fun encodeBase64(bytes: ByteArray): String = Base64.getEncoder().encodeToString(bytes)

    fun decodeBase64(value: String): ByteArray {
        val bytes = Base64.getDecoder().decode(value)
        require(encodeBase64(bytes) == value) { "Noncanonical Base64" }
        return bytes
    }

    // BigInteger may add a sign byte or omit leading zeroes; normalize each coordinate to 32 bytes.
    fun exportPublicKey(key: PublicKey): ByteArray {
        val ec = key as ECPublicKey
        require(ec.params.order == parameters.order && ec.params.curve == parameters.curve)
        fun coordinate(value: BigInteger): ByteArray {
            require(value.signum() >= 0 && value.bitLength() <= 256)
            val unsigned = value.toByteArray().let { if (it.size == 33 && it[0] == 0.toByte()) it.copyOfRange(1, 33) else it }
            return ByteArray(32 - unsigned.size) + unsigned
        }
        return byteArrayOf(4) + coordinate(ec.w.affineX) + coordinate(ec.w.affineY)
    }

    fun publicKey(bytes: ByteArray): PublicKey {
        require(bytes.size == 65 && bytes[0] == 4.toByte()) { "Invalid uncompressed P-256 point" }
        val x = BigInteger(1, bytes.copyOfRange(1, 33))
        val y = BigInteger(1, bytes.copyOfRange(33, 65))
        val p = (parameters.curve.field as java.security.spec.ECFieldFp).p
        require(x < p && y < p)
        require(y.multiply(y).mod(p) == x.pow(3).add(parameters.curve.a.multiply(x)).add(parameters.curve.b).mod(p))
        return KeyFactory.getInstance("EC").generatePublic(ECPublicKeySpec(ECPoint(x, y), parameters))
    }

    fun fingerprint(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes)
        .joinToString("") { "%02x".format(it.toInt() and 255) }

    fun verify(publicKey: ByteArray, message: ByteArray, signature: ByteArray): Boolean = try {
        requireCanonicalDer(signature)
        Signature.getInstance("SHA256withECDSA").run {
            initVerify(publicKey(publicKey)); update(message); verify(signature)
        }
    } catch (_: java.security.GeneralSecurityException) { false }
      catch (_: IllegalArgumentException) { false }

    // Signature bytes are malleable and must never serve as replay identifiers.
    private fun requireCanonicalDer(bytes: ByteArray) {
        require(bytes.size in 8..72 && bytes[0] == 0x30.toByte() && bytes[1].toInt() == bytes.size - 2)
        var offset = 2
        repeat(2) {
            require(offset + 2 <= bytes.size && bytes[offset++] == 2.toByte())
            val length = bytes[offset++].toInt() and 255
            require(length in 1..33 && offset + length <= bytes.size)
            val first = bytes[offset].toInt() and 255
            require(first < 128)
            require(length == 1 || first != 0 || (bytes[offset + 1].toInt() and 128) != 0)
            val scalar = BigInteger(1, bytes.copyOfRange(offset, offset + length))
            require(scalar.signum() > 0 && scalar < parameters.order)
            offset += length
        }
        require(offset == bytes.size)
    }
}
