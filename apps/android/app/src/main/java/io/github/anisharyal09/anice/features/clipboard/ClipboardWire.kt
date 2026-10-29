// SPDX-License-Identifier: GPL-3.0-or-later
// Validates canonical bounded clipboard envelopes inside authenticated DATA.
package io.github.anisharyal09.anice.features.clipboard

import io.github.anisharyal09.anice.infrastructure.session.*
import java.net.URI
import java.util.UUID

class ClipboardWireException : Exception()
data class ClipboardMessage(val kind: Long, val fields: List<Cbor>) {
    fun text(i: Int) = (fields[i] as Cbor.Text).value
    fun number(i: Int) = (fields[i] as Cbor.Integer).value
    fun flag(i: Int) = (fields[i] as Cbor.Bool).value
    fun bytes(i: Int) = (fields[i] as Cbor.Bytes).value
    fun encode(): ByteArray = SessionCbor.encode(Cbor.Array(listOf(Cbor.Text(TAG), Cbor.Integer(1), Cbor.Integer(kind), Cbor.Array(fields)))).also { validate() }
    private fun validate() {
        fun requireWire(value: Boolean) { if (!value) throw ClipboardWireException() }
        fun uuid(i: Int) { val s = text(i); requireWire(runCatching { UUID.fromString(s).toString() == s }.getOrDefault(false)) }
        fun revision(i: Int) = requireWire(number(i) in 1..4294967295L)
        try {
            when (kind) {
                1L -> { requireWire(fields.size == 3); uuid(0); requireWire(number(1) == 65536L && number(2) == 3072L) }
                2L -> { requireWire(fields.size == 2); revision(0); flag(1) }
                3L -> {
                    requireWire(fields.size == 8); uuid(0); revision(1); uuid(2)
                    requireWire(number(3) in 0..2); flag(4)
                    requireWire(number(5) in 1..65536 && number(6) == (number(5) + 3071) / 3072 && bytes(7).size == 32)
                }
                4L -> { requireWire(fields.size == 3); uuid(0); requireWire(number(1) in 0..21 && bytes(2).size in 1..3072) }
                5L, 7L -> { requireWire(fields.size == 1); uuid(0) }
                6L -> { requireWire(fields.size == 2); uuid(0); requireWire(number(1) in 0..7) }
                8L -> requireWire(fields.isEmpty())
                else -> throw ClipboardWireException()
            }
        } catch (_: ClassCastException) { throw ClipboardWireException() }
        catch (_: IndexOutOfBoundsException) { throw ClipboardWireException() }
    }
    companion object {
        const val TAG = "aniCe clipboard"
        fun decode(data: ByteArray): ClipboardMessage? {
            if (data.size > 4000) return null
            val row = (SessionCbor.decode(data) as? Cbor.Array)?.value ?: return null
            if ((row.firstOrNull() as? Cbor.Text)?.value != TAG) return null
            if (row.size != 4 || (row[1] as? Cbor.Integer)?.value != 1L) throw ClipboardWireException()
            val m = ClipboardMessage((row[2] as? Cbor.Integer)?.value ?: throw ClipboardWireException(), (row[3] as? Cbor.Array)?.value ?: throw ClipboardWireException())
            m.validate()
            if (!m.encode().contentEquals(data)) throw ClipboardWireException()
            return m
        }
        fun of(kind: Long, vararg fields: Cbor) = ClipboardMessage(kind, fields.toList())
        fun id(kind: Long, id: String) = of(kind, Cbor.Text(id))
        fun result(id: String, code: Long) = of(6, Cbor.Text(id), Cbor.Integer(code))
    }
}

internal fun clipboardLink(value: String?): String? {
    val text = value?.trim()?.takeIf { it.isNotEmpty() && it.none(Char::isWhitespace) } ?: return null
    val uri = runCatching { URI(text) }.getOrNull() ?: return null
    return text.takeIf { (uri.scheme.equals("http", true) || uri.scheme.equals("https", true)) && !uri.host.isNullOrBlank() }
}
