// SPDX-License-Identifier: GPL-3.0-or-later
// Validates bounded notification mirroring records inside authenticated application DATA.
package io.github.anisharyal09.anice.features.notifications

import io.github.anisharyal09.anice.infrastructure.session.Cbor
import io.github.anisharyal09.anice.infrastructure.session.SessionCbor
import io.github.anisharyal09.anice.infrastructure.session.SessionException
import java.util.UUID

data class MirroredAction(val index: Long, val title: String, val replyPlaceholder: String)

data class NotificationWireMessage(val kind: Long, val fields: List<Cbor>) {
    fun text(index: Int) = (fields[index] as Cbor.Text).value
    fun number(index: Int) = (fields[index] as Cbor.Integer).value
    fun bytes(index: Int) = (fields[index] as Cbor.Bytes).value
    fun actions(index: Int): List<MirroredAction> = ((fields[index] as Cbor.Array).value).map {
        val row = (it as Cbor.Array).value
        MirroredAction((row[0] as Cbor.Integer).value, (row[1] as Cbor.Text).value, (row[2] as Cbor.Text).value)
    }

    fun encode(): ByteArray {
        validate()
        return SessionCbor.encode(Cbor.Array(listOf(Cbor.Text(TAG), Cbor.Integer(VERSION), Cbor.Integer(kind), Cbor.Array(fields))), 4000)
    }

    private fun validate() {
        fun requireWire(value: Boolean) { if (!value) throw NotificationWireException() }
        fun string(index: Int, maxBytes: Int, allowEmpty: Boolean = true) {
            val value = (fields[index] as Cbor.Text).value
            val size = value.toByteArray(Charsets.UTF_8).size
            requireWire((allowEmpty || size > 0) && size <= maxBytes)
        }
        fun uuid(index: Int) {
            val value = (fields[index] as Cbor.Text).value
            requireWire(runCatching { UUID.fromString(value).toString() == value }.getOrDefault(false))
        }
        fun id(index: Int) { requireWire(ID.matches((fields[index] as Cbor.Text).value)) }
        fun sequence(index: Int) { requireWire((fields[index] as Cbor.Integer).value in 1..MAX_SEQUENCE) }
        try {
            when (kind) {
                1L -> { requireWire(fields.size == 1); requireWire(number(0) == MAX_ACTIONS) }
                2L -> {
                    requireWire(fields.size == 9)
                    string(0, 36); if (text(0).isNotEmpty()) uuid(0); id(1); uuid(2); sequence(3)
                    string(4, 255, false); string(5, 128, false); string(6, 512); string(7, 1024)
                    val rows = (fields[8] as Cbor.Array).value
                    requireWire(rows.size <= MAX_ACTIONS)
                    val indices = mutableSetOf<Long>()
                    for (row in rows) {
                        val cells = (row as Cbor.Array).value
                        requireWire(cells.size == 3)
                        val actionIndex = (cells[0] as Cbor.Integer).value
                        requireWire(actionIndex in 0 until MAX_ACTIONS && indices.add(actionIndex))
                        requireWire((cells[1] as Cbor.Text).value.toByteArray(Charsets.UTF_8).size in 1..48)
                        requireWire((cells[2] as Cbor.Text).value.toByteArray(Charsets.UTF_8).size <= 48)
                    }
                }
                3L -> { requireWire(fields.size == 3); id(0); uuid(1); sequence(2) }
                4L -> { requireWire(fields.size == 3); uuid(0); uuid(1); requireWire(number(2) in 0..MAX_SEQUENCE) }
                5L -> { requireWire(fields.size == 1); uuid(0) }
                6L -> {
                    requireWire(fields.size == 6); uuid(0); id(1); uuid(2); sequence(3)
                    requireWire(number(4) in -1 until MAX_ACTIONS); string(5, 1024)
                    if (number(4) == -1L) requireWire(text(5).isEmpty())
                }
                7L -> { requireWire(fields.size == 2); uuid(0); requireWire(number(1) in 0..3) }
                8L -> { requireWire(fields.size == 4); uuid(0); id(1); uuid(2); sequence(3) }
                9L -> {
                    requireWire(fields.size == 2)
                    string(0, 255, false)
                    requireWire(validSourceIcon(bytes(1)))
                }
                else -> throw NotificationWireException()
            }
        } catch (_: ClassCastException) { throw NotificationWireException() }
        catch (_: IndexOutOfBoundsException) { throw NotificationWireException() }
    }

    companion object {
        const val TAG = "aniCe notifications"
        const val VERSION = 1L
        const val MAX_ACTIONS = 8L
        const val MAX_SEQUENCE = 9007199254740991L
        const val MAX_SOURCE_ICON_BYTES = 3000
        private val PNG_SIGNATURE = byteArrayOf(0x89.toByte(), 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a)
        private val PNG_IHDR_LENGTH = byteArrayOf(0, 0, 0, 13)
        private val PNG_IHDR_TYPE = byteArrayOf(0x49, 0x48, 0x44, 0x52)
        private val ID = Regex("[0-9a-f]{64}")

        private fun validSourceIcon(icon: ByteArray): Boolean {
            if (icon.size !in 33..MAX_SOURCE_ICON_BYTES ||
                !icon.copyOfRange(0, 8).contentEquals(PNG_SIGNATURE) ||
                !icon.copyOfRange(8, 12).contentEquals(PNG_IHDR_LENGTH) ||
                !icon.copyOfRange(12, 16).contentEquals(PNG_IHDR_TYPE)
            ) return false
            fun dimension(offset: Int) = (0..3).fold(0L) { value, index ->
                (value shl 8) or (icon[offset + index].toLong() and 0xff)
            }
            return dimension(16) in 1L..128L && dimension(20) in 1L..128L
        }

        fun decode(bytes: ByteArray): NotificationWireMessage? {
            if (bytes.size > 4000) return null
            val row = (SessionCbor.decode(bytes) as? Cbor.Array)?.value ?: return null
            if ((row.firstOrNull() as? Cbor.Text)?.value != TAG) return null
            if (row.size != 4 || (row[1] as? Cbor.Integer)?.value != VERSION) throw NotificationWireException()
            val message = NotificationWireMessage(
                (row[2] as? Cbor.Integer)?.value ?: throw NotificationWireException(),
                (row[3] as? Cbor.Array)?.value ?: throw NotificationWireException(),
            )
            message.validate()
            if (!message.encode().contentEquals(bytes)) throw NotificationWireException()
            return message
        }

        fun of(kind: Long, vararg fields: Cbor) = NotificationWireMessage(kind, fields.toList())
    }
}

class NotificationWireException : Exception()

fun notificationText(value: String, maxBytes: Int): String {
    val output = StringBuilder()
    var bytes = 0
    for (codePoint in value.codePoints().toArray()) {
        val chars = String(Character.toChars(codePoint))
        val size = chars.toByteArray(Charsets.UTF_8).size
        if (bytes + size > maxBytes) break
        output.append(chars)
        bytes += size
    }
    return output.toString()
}
