// SPDX-License-Identifier: GPL-3.0-or-later
package io.github.anisharyal09.anice.infrastructure.pairing

import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

enum class PairingMethod(val wire: Int) {
    QR(1),
    PIN(2),
}

class PairingException : Exception("Pairing operation failed")

data class PairingQR(val rendezvous: ByteArray, val secret: ByteArray, val fingerprint: ByteArray) {
    fun text() =
        "anice:pair:1:" +
            Base64.getUrlEncoder()
                .withoutPadding()
                .encodeToString(byteArrayOf(1) + rendezvous + secret + fingerprint)

    companion object {
        fun decode(text: String): PairingQR {
            require(text.startsWith("anice:pair:1:") && text.length == 121)
            val bytes = Base64.getUrlDecoder().decode(text.substring(13))
            require(bytes.size == 81 && bytes[0] == 1.toByte())
            return PairingQR(
                    bytes.copyOfRange(1, 17),
                    bytes.copyOfRange(17, 49),
                    bytes.copyOfRange(49, 81),
                )
                .also { require(it.text() == text) }
        }
    }
}

object PairingCodec {
    const val WRITE_UUID = "414E4953-4853-4149-4A49-4C4365090903"
    const val INDICATE_UUID = "414E4953-4853-4149-4A49-4C4365090904"

    fun number(n: Long, size: Int): ByteArray =
        ByteArray(size) { (n ushr ((size - it - 1) * 8)).toByte() }

    fun integer(b: ByteArray): Long = b.fold(0L) { n, v -> (n shl 8) or (v.toLong() and 255) }

    fun fields(vararg values: ByteArray): ByteArray =
        values.fold(byteArrayOf()) { out, v -> out + number(v.size.toLong(), 4) + v }

    fun parse(data: ByteArray): List<ByteArray> {
        require(data.size <= 4096)
        val result = mutableListOf<ByteArray>()
        var offset = 0
        while (offset < data.size) {
            require(offset + 4 <= data.size && result.size < 10)
            val size = integer(data.copyOfRange(offset, offset + 4))
            offset += 4
            require(size in 0..(data.size - offset).toLong())
            result.add(data.copyOfRange(offset, offset + size.toInt()))
            offset += size.toInt()
        }
        return result
    }

    fun message(type: Int, vararg values: ByteArray) = byteArrayOf(type.toByte()) + fields(*values)

    fun unpack(data: ByteArray, type: Int, count: Int): List<ByteArray> {
        require(data.firstOrNull() == type.toByte())
        return parse(data.copyOfRange(1, data.size)).also { require(it.size == count) }
    }

    fun random(size: Int) = ByteArray(size).also { SecureRandom().nextBytes(it) }

    fun hash(bytes: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(bytes)

    fun mac(key: ByteArray, data: ByteArray): ByteArray =
        Mac.getInstance("HmacSHA256").run {
            init(SecretKeySpec(key, "HmacSHA256"))
            doFinal(data)
        }

    fun hkdf(ikm: ByteArray, salt: ByteArray, info: ByteArray): ByteArray =
        mac(mac(salt, ikm), info + byteArrayOf(1))

    fun derive(key: ByteArray, label: String, hash: ByteArray) =
        hkdf(key, hash, ("aniCe pairing v1 " + label).toByteArray())

    fun equal(a: ByteArray, b: ByteArray) = MessageDigest.isEqual(a, b)

    fun proof(hash: ByteArray, client: ByteArray, server: ByteArray, role: Int? = null) =
        fields(
            *listOf("aniCe identity proof v1".toByteArray(), hash, client, server)
                .let { if (role == null) it else it + listOf(byteArrayOf(role.toByte())) }
                .toTypedArray()
        )

    fun receipt(transcript: ByteArray, role: Int) =
        fields("aniCe trust stored v1".toByteArray(), transcript, byteArrayOf(role.toByte()))
}

class PairingReassembler {
    private val framing = io.github.anisharyal09.anice.infrastructure.bluetooth.GattReassembler(1)
    private var budget = 0

    fun receive(fragment: ByteArray): ByteArray? {
        try {
            val result = framing.receive(fragment)
            if (result != null) {
                budget += result.size
                require(budget <= 32768)
            }
            return result
        } catch (e: io.github.anisharyal09.anice.infrastructure.session.SessionException) {
            throw IllegalArgumentException(e)
        }
    }

    companion object {
        fun fragments(data: ByteArray, id: Long, capacity: Int): List<ByteArray> =
            try {
                io.github.anisharyal09.anice.infrastructure.bluetooth.GattReassembler.fragments(
                    data,
                    id,
                    capacity,
                    1,
                )
            } catch (e: io.github.anisharyal09.anice.infrastructure.session.SessionException) {
                throw IllegalArgumentException(e)
            }
    }
}

class PairingChannel(
    private val key: ByteArray,
    val transcript: ByteArray,
    private val server: Boolean,
) {
    val hash = PairingCodec.hash(transcript)
    private var sent = 0L
    private var received = 0L

    fun confirm() = PairingCodec.mac(PairingCodec.derive(key, "channel-confirm", hash), transcript)

    fun seal(bytes: ByteArray): ByteArray {
        check(sent >= 0 && sent < Long.MAX_VALUE)
        val counter = PairingCodec.number(sent, 8)
        val out = crypt(Cipher.ENCRYPT_MODE, bytes, counter, if (server) 2 else 1)
        sent++
        return PairingCodec.message(7, counter, out)
    }

    fun open(bytes: ByteArray): ByteArray {
        val f = PairingCodec.unpack(bytes, 7, 2)
        require(
            f[0].size == 8 &&
                received >= 0 &&
                PairingCodec.integer(f[0]) == received &&
                received < Long.MAX_VALUE
        )
        val out = crypt(Cipher.DECRYPT_MODE, f[1], f[0], if (server) 1 else 2)
        received++
        return out
    }

    private fun crypt(mode: Int, bytes: ByteArray, counter: ByteArray, direction: Int): ByteArray {
        val label = if (direction == 1) "client-to-server" else "server-to-client"
        return Cipher.getInstance("AES/GCM/NoPadding").run {
            init(
                mode,
                SecretKeySpec(PairingCodec.derive(key, label, hash), "AES"),
                GCMParameterSpec(128, ByteArray(4) + counter),
            )
            updateAAD(
                PairingCodec.fields(
                    "aniCe pairing encrypted v1".toByteArray(),
                    hash,
                    byteArrayOf(direction.toByte()),
                    counter,
                )
            )
            doFinal(bytes)
        }
    }

    fun destroy() {
        key.fill(0)
    }
}
