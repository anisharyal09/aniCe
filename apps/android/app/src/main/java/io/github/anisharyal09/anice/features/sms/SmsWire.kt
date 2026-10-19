// SPDX-License-Identifier: GPL-3.0-or-later
// Validates canonical bounded SMS relay envelopes inside authenticated DATA.
package io.github.anisharyal09.anice.features.sms

import io.github.anisharyal09.anice.infrastructure.session.*
import java.util.UUID

class SmsWireException : Exception()

data class SmsWireMessage(val kind: Long, val fields: List<Cbor>) {
    fun text(i: Int) = (fields[i] as Cbor.Text).value
    fun number(i: Int) = (fields[i] as Cbor.Integer).value
    fun flag(i: Int) = (fields[i] as Cbor.Bool).value
    fun bytes(i: Int) = (fields[i] as Cbor.Bytes).value
    fun encode(): ByteArray = SessionCbor.encode(Cbor.Array(listOf(Cbor.Text(TAG), Cbor.Integer(2), Cbor.Integer(kind), Cbor.Array(fields)))).also { validate() }
    private fun validate() {
        fun requireWire(value: Boolean) { if (!value) throw SmsWireException() }
        fun uuid(i: Int) { val s = text(i); requireWire(runCatching { UUID.fromString(s).toString() == s }.getOrDefault(false)) }
        fun uuidOrEmpty(i: Int) { if (text(i).isNotEmpty()) uuid(i) }
        fun cursorId(i: Int) { val s = text(i); requireWire(s.isEmpty() || MESSAGE_ID.matches(s)) }
        fun millis(i: Int) = requireWire(number(i) in 0..MAX_DATE)
        fun result(i: Int) = requireWire(number(i) in 0..6)
        fun subscription(i: Int) = requireWire(number(i) in 0..MAX_SUBSCRIPTION)
        fun threadId(i: Int) = requireWire(text(i).toByteArray(Charsets.UTF_8).size in 1..80)
        fun address(i: Int) = requireWire(text(i).toByteArray(Charsets.UTF_8).size in 1..64)
        fun snippet(i: Int) = requireWire(text(i).toByteArray(Charsets.UTF_8).size <= 160)
        fun body(total: Int, count: Int) {
            val bytes = number(total)
            requireWire(bytes in 1..MAX_BODY_BYTES && number(count) == (bytes + 3071) / 3072 && number(count) in 1..MAX_FRAGMENTS)
        }
        try {
            when (kind) {
                1L -> { requireWire(fields.size == 4); requireWire(number(0) == MAX_BODY_BYTES && number(1) == MAX_FRAGMENTS && number(2) in 1..50 && number(3) in 1..50) }
                2L -> { requireWire(fields.size == 1); uuid(0) }
                3L -> { requireWire(fields.size == 6); uuid(0); threadId(1); address(2); snippet(3); millis(4); millis(5) }
                4L -> { requireWire(fields.size == 2); uuid(0); result(1) }
                5L -> { requireWire(fields.size == 5); uuid(0); threadId(1); millis(2); cursorId(3); requireWire(number(4) in 1..50) }
                6L -> {
                    requireWire(fields.size == 11); uuid(0); uuidOrEmpty(1); requireWire(MESSAGE_ID.matches(text(2))); threadId(3); address(4); millis(5)
                    requireWire(number(6) in 0..1); flag(7); body(8, 9); requireWire(bytes(10).size == 32)
                }
                7L -> { requireWire(fields.size == 3); uuid(0); requireWire(number(1) in 0..MAX_FRAGMENTS - 1 && bytes(2).size in 1..3072) }
                8L, 13L -> { requireWire(fields.size == 1); uuid(0) }
                9L -> { requireWire(fields.size == 2); uuid(0); result(1) }
                10L -> { requireWire(fields.size == 4); uuid(0); result(1); millis(2); cursorId(3) }
                11L -> { requireWire(fields.size == 7); uuid(0); threadId(1); address(2); body(3, 4); requireWire(bytes(5).size == 32); subscription(6) }
                12L -> { requireWire(fields.size == 3); uuid(0); requireWire(number(1) in 0..MAX_FRAGMENTS - 1 && bytes(2).size in 1..3072) }
                14L -> {
                    requireWire(fields.size == 4); uuid(0); val code = number(1); requireWire(code in 0..6); val id = text(2)
                    requireWire(id.isEmpty() || MESSAGE_ID.matches(id)); if (code != 0L) requireWire(id.isEmpty()); millis(3)
                }
                15L -> { requireWire(fields.size == 1); uuid(0) }
                16L -> {
                    requireWire(fields.size == 3); uuid(0); result(1)
                    val entries = (fields[2] as Cbor.Array).value
                    requireWire(entries.size <= 8)
                    for (entry in entries) {
                        val cells = (entry as Cbor.Array).value
                        requireWire(cells.size == 4)
                        requireWire((cells[0] as Cbor.Integer).value in 0..MAX_SUBSCRIPTION)
                        requireWire((cells[1] as Cbor.Integer).value in 0..15L)
                        requireWire((cells[2] as Cbor.Text).value.toByteArray(Charsets.UTF_8).size <= 40)
                        requireWire(cells[3] is Cbor.Bool)
                    }
                }
                17L -> {
                    requireWire(fields.size == 5); uuid(0)
                    requireWire(text(1).toByteArray(Charsets.UTF_8).size in 2..64)
                    millis(2); cursorId(3); requireWire(number(4) in 1..50)
                }
                18L -> { requireWire(fields.size == 4); uuid(0); result(1); millis(2); cursorId(3) }
                else -> throw SmsWireException()
            }
        } catch (_: ClassCastException) { throw SmsWireException() }
        catch (_: IndexOutOfBoundsException) { throw SmsWireException() }
    }
    companion object {
        const val TAG = "aniCe sms"
        const val MAX_BODY_BYTES = 24576L
        const val MAX_FRAGMENTS = 8L
        const val MAX_DATE = 9007199254740991L
        const val MAX_SUBSCRIPTION = 2147483647L
        val MESSAGE_ID = Regex("(sms|mms):[0-9]{1,19}|live:[0-9a-f]{32}")
        fun decode(data: ByteArray): SmsWireMessage? {
            if (data.size > 4000) return null
            val row = (SessionCbor.decode(data) as? Cbor.Array)?.value ?: return null
            if ((row.firstOrNull() as? Cbor.Text)?.value != TAG) return null
            if (row.size != 4 || (row[1] as? Cbor.Integer)?.value != 2L) throw SmsWireException()
            val m = SmsWireMessage((row[2] as? Cbor.Integer)?.value ?: throw SmsWireException(), (row[3] as? Cbor.Array)?.value ?: throw SmsWireException())
            m.validate()
            if (!m.encode().contentEquals(data)) throw SmsWireException()
            return m
        }
        fun of(kind: Long, vararg fields: Cbor) = SmsWireMessage(kind, fields.toList())
    }
}

fun text(value: String) = Cbor.Text(value)
fun number(value: Long) = Cbor.Integer(value)
fun flag(value: Boolean) = Cbor.Bool(value)
fun data(value: ByteArray) = Cbor.Bytes(value)
