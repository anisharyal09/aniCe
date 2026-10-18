// SPDX-License-Identifier: GPL-3.0-or-later
// Decodes GSM 03.40 SMS-DELIVER PDUs and combines multipart segments without Android telephony classes.
package io.github.anisharyal09.anice.features.sms

import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.util.Calendar
import java.util.TimeZone

/** One unique incoming SMS after multipart combination and NUL sanitization. */
data class SmsLiveEvent(val address: String, val dateMillis: Long, val body: String) {
    val normalizedAddress: String get() = smsNormalizedAddress(address)
    // The canonical conversation key keeps alphanumeric sender IDs as their own thread.
    val threadId: String get() = "addr:" + normalizedAddress.ifEmpty { address }
    val messageId: String get() = smsLiveMessageId(address, dateMillis, body)
}

/** Deterministic live ID so duplicate SMS_RECEIVED deliveries collapse under the same messageId. */
fun smsLiveMessageId(address: String, dateMillis: Long, body: String): String =
    "live:" + MessageDigest.getInstance("SHA-256").digest((address + dateMillis.toString() + body).toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }.take(32)

object SmsPduParser {
    private val GSM7 = charArrayOf(
        '@', '£', '$', '¥', 'è', 'é', 'ù', 'ì', 'ò', 'Ç', '\n', 'Ø', 'ø', '\r', 'Å', 'å',
        'Δ', '_', 'Φ', 'Γ', 'Λ', 'Ω', 'Π', 'Ψ', 'Σ', 'Θ', 'Ξ', '\u001B', 'Æ', 'æ', 'ß', 'É',
        ' ', '!', '"', '#', '¤', '%', '&', '\'', '(', ')', '*', '+', ',', '-', '.', '/',
        '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', ':', ';', '<', '=', '>', '?',
        '¡', 'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M', 'N', 'O',
        'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z', 'Ä', 'Ö', 'Ñ', 'Ü', '§',
        '¿', 'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm', 'n', 'o',
        'p', 'q', 'r', 's', 't', 'u', 'v', 'w', 'x', 'y', 'z', 'ä', 'ö', 'ñ', 'ü', 'à',
    )
    private val GSM7_EXTENSION = mapOf(0x0A to '\u000C', 0x14 to '^', 0x28 to '{', 0x29 to '}', 0x2F to '\\', 0x3C to '[', 0x3D to '~', 0x3E to ']', 0x40 to '|', 0x65 to '€')

    private class Part(val address: String, val timestamp: Long, val body: String, val reference: Int?, val count: Int?, val index: Int?)

    /** Parses every 3gpp SMS-DELIVER PDU; malformed or non-deliver PDUs and non-3gpp formats yield no events. */
    fun parse(format: String?, pdus: List<ByteArray>): List<SmsLiveEvent> {
        if (format != null && !format.equals("3gpp", ignoreCase = true)) return emptyList()
        val parts = pdus.mapNotNull(::decodeDeliver)
        val events = mutableListOf<SmsLiveEvent>()
        parts.filter { it.reference == null }.forEach { events += event(it.address, it.timestamp, it.body) }
        parts.filter { it.reference != null }
            .groupBy { Triple(it.address, it.reference, it.count) }
            .values
            .forEach { group ->
                val count = group.first().count ?: return@forEach
                val ordered = group.sortedBy { it.index ?: 0 }
                if (ordered.size != count || ordered.map { it.index }.distinct().size != count) return@forEach
                events += event(ordered.first().address, ordered.first().timestamp, ordered.joinToString("") { it.body })
            }
        return events
    }

    private fun event(address: String, timestamp: Long, body: String): SmsLiveEvent =
        SmsLiveEvent(address, smsClampDate(timestamp), body.replace('\u0000', '\uFFFD'))

    private fun decodeDeliver(bytes: ByteArray): Part? {
        try {
            var offset = 0
            val scaLength = bytes[offset++].toInt() and 255
            offset += scaLength
            val firstOctet = bytes[offset++].toInt() and 255
            if (firstOctet and 0x03 != 0) return null
            if (firstOctet and 0x20 != 0) return null
            val addressLength = bytes[offset++].toInt() and 255
            val typeOfAddress = bytes[offset++].toInt() and 255
            val addressOctets = (addressLength + 1) / 2
            val address = decodeAddress(bytes, offset, addressOctets, addressLength, typeOfAddress) ?: return null
            offset += addressOctets
            offset += 1
            val dcs = bytes[offset++].toInt() and 255
            val timestamp = decodeTimestamp(bytes, offset) ?: return null
            offset += 7
            val userDataLength = bytes[offset++].toInt() and 255
            val userData = bytes.copyOfRange(offset, minOf(offset + userDataLength, bytes.size))
            var reference: Int? = null
            var count: Int? = null
            var index: Int? = null
            var body: String?
            if (firstOctet and 0x40 != 0 && userData.isNotEmpty()) {
                val headerLength = userData[0].toInt() and 255
                if (headerLength + 1 > userData.size) return null
                var i = 1
                while (i + 1 <= headerLength) {
                    val identifier = userData[i].toInt() and 255
                    val length = userData[i + 1].toInt() and 255
                    if (i + 2 + length > userData.size) return null
                    when (identifier) {
                        0x00 -> if (length >= 3) {
                            reference = userData[i + 2].toInt() and 255
                            count = userData[i + 3].toInt() and 255
                            index = userData[i + 4].toInt() and 255
                        }
                        0x08 -> if (length >= 4) {
                            reference = ((userData[i + 2].toInt() and 255) shl 8) or (userData[i + 3].toInt() and 255)
                            count = userData[i + 4].toInt() and 255
                            index = userData[i + 5].toInt() and 255
                        }
                    }
                    i += 2 + length
                }
                body = decodeBody(dcs, userData, headerLength + 1, userDataLength)
            } else {
                body = decodeBody(dcs, userData, 0, userDataLength)
            }
            if (body == null) return null
            // TS 23.040 9.2.3.24.1: concatenation sequence numbers are 1-based.
            if (reference != null && (count == null || index == null || count <= 0 || index <= 0 || index > count)) return null
            return Part(address, timestamp, body, reference, count, index)
        } catch (_: IndexOutOfBoundsException) {
            return null
        } catch (_: Exception) {
            return null
        }
    }

    private fun decodeAddress(bytes: ByteArray, offset: Int, octets: Int, length: Int, typeOfAddress: Int): String? {
        if (offset + octets > bytes.size) return null
        val alphabet = typeOfAddress and 0x70
        if (alphabet == 0x50) {
            // The address length for an alphanumeric address counts semi-octets (AOSP: addressLength * 4 / 7 septets).
            val semiOctets = if (length % 2 == 1) length + 1 else length
            val text = buildString { unpackSeptets(bytes, offset, 0, minOf(semiOctets * 4 / 7, octets * 2)).forEach { septet -> append(gsm7Char(septet, '@')) } }
            return text.ifEmpty { null }
        }
        val digits = StringBuilder()
        for (i in 0 until octets) {
            val value = bytes[offset + i].toInt() and 255
            val low = value and 0x0F
            val high = value ushr 4 and 0x0F
            digits.append(if (low <= 9) '0' + low else 'f')
            digits.append(if (high <= 9) '0' + high else 'f')
        }
        val text = digits.toString().trimEnd('f', 'F')
        if (text.isEmpty() || text.any { it !in '0'..'9' }) return null
        return if (alphabet == 0x10) "+$text" else text
    }

    private fun decodeBody(dcs: Int, userData: ByteArray, udhBytes: Int, declaredLength: Int): String? {
        if (dcs and 0x20 != 0) return null
        return when {
            dcs and 0x08 != 0 -> {
                if (userData.size - udhBytes <= 0) null
                else decodeStrict(userData.copyOfRange(udhBytes, userData.size), StandardCharsets.UTF_16BE)?.takeIf { it.isNotEmpty() }
            }
            dcs and 0x04 != 0 -> null
            else -> {
                // The declared length counts septets; the octet padding must never decode as an extra character.
                val available = (userData.size * 8) / 7
                val total = minOf(if (declaredLength > 0) declaredLength else available, available)
                val headerSeptets = if (udhBytes > 0) (udhBytes * 8 + 6) / 7 else 0
                if (total <= headerSeptets) null
                else {
                    val body = StringBuilder()
                    var escape = false
                    for (septet in unpackSeptets(userData, 0, headerSeptets * 7, total - headerSeptets)) {
                        when {
                            escape -> { body.append(GSM7_EXTENSION[septet] ?: ' '); escape = false }
                            septet == 0x1B -> escape = true
                            else -> body.append(GSM7[septet])
                        }
                    }
                    body.toString().ifEmpty { null }
                }
            }
        }
    }

    private fun gsm7Char(septet: Int, default: Char): Char = when {
        septet == 0x1B -> default
        septet !in 0..127 -> default
        else -> GSM7[septet]
    }

    private fun unpackSeptets(bytes: ByteArray, offset: Int, bitOffset: Int, septets: Int): IntArray {
        val out = IntArray(septets)
        for (i in 0 until septets) {
            val bit = bitOffset + i * 7
            val byteIndex = offset + bit / 8
            val shift = bit % 8
            var value = (bytes.getOrElse(byteIndex) { 0 }.toInt() and 255) ushr shift
            if (shift > 1) value = value or ((bytes.getOrElse(byteIndex + 1) { 0 }.toInt() and 255) shl (8 - shift))
            out[i] = value and 0x7F
        }
        return out
    }

    private fun decodeStrict(bytes: ByteArray, charset: java.nio.charset.Charset): String? =
        try {
            charset.newDecoder().onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes)).toString()
        } catch (_: java.nio.charset.CharacterCodingException) {
            null
        }

    private fun decodeTimestamp(bytes: ByteArray, offset: Int): Long? {
        if (offset + 7 > bytes.size) return null
        fun digit(i: Int): Int? {
            val byte = bytes[offset + i].toInt() and 255
            val low = byte and 0x0F
            val high = byte ushr 4
            if (low > 9 || high > 9) return null
            return low * 10 + high
        }
        val year = digit(0) ?: return null
        val month = digit(1) ?: return null
        val day = digit(2) ?: return null
        val hour = digit(3) ?: return null
        val minute = digit(4) ?: return null
        val second = digit(5) ?: return null
        if (month !in 1..12 || day !in 1..31 || hour > 23 || minute > 59 || second > 59) return null
        val tzByte = bytes[offset + 6].toInt() and 255
        val low = tzByte and 0x0F
        val negative = low and 0x08 != 0
        val quarters = (low and 0x07) * 10 + (tzByte ushr 4)
        val calendar = Calendar.getInstance(TimeZone.getTimeZone("UTC"))
        calendar.clear()
        calendar.set(if (year >= 90) 1900 + year else 2000 + year, month - 1, day, hour, minute, second)
        return calendar.timeInMillis - (if (negative) -quarters else quarters) * 15 * 60_000L
    }
}
