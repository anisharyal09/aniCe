// SPDX-License-Identifier: GPL-3.0-or-later
// Validates bounded Phone-to-Mac input envelopes inside authenticated DATA.
package io.github.anisharyal09.anice.features.phoneinput

import io.github.anisharyal09.anice.infrastructure.session.Cbor
import io.github.anisharyal09.anice.infrastructure.session.SessionCbor
import java.util.UUID

class PhoneInputWireException : Exception()

data class PhoneInputMessage(val kind: Long, val fields: List<Cbor>) {
    fun text(index: Int) = (fields[index] as Cbor.Text).value
    fun number(index: Int) = (fields[index] as Cbor.Integer).value
    fun flag(index: Int) = (fields[index] as Cbor.Bool).value

    fun encode(): ByteArray {
        validate()
        return SessionCbor.encode(
            Cbor.Array(
                listOf(
                    Cbor.Text(TAG),
                    Cbor.Integer(VERSION),
                    Cbor.Integer(kind),
                    Cbor.Array(fields),
                ),
            ),
        )
    }

    private fun validate() {
        fun requireWire(value: Boolean) {
            if (!value) throw PhoneInputWireException()
        }

        fun value(index: Int) = fields.getOrNull(index) ?: throw PhoneInputWireException()
        fun number(index: Int) = (value(index) as? Cbor.Integer)?.value ?: throw PhoneInputWireException()
        fun text(index: Int) = (value(index) as? Cbor.Text)?.value ?: throw PhoneInputWireException()
        fun flag(index: Int) = (value(index) as? Cbor.Bool)?.value ?: throw PhoneInputWireException()
        fun uuid(index: Int) {
            val encoded = text(index)
            requireWire(runCatching { UUID.fromString(encoded).toString() == encoded }.getOrDefault(false))
        }
        fun sequence(index: Int) = requireWire(number(index) in 1L..MAX_SEQUENCE)
        fun sessionSequence() {
            requireWire(fields.size >= 2)
            uuid(0)
            sequence(1)
        }

        when (kind) {
            1L -> {
                requireWire(fields.size == 2)
                requireWire(number(0) in 1L..MAX_TEXT_BYTES)
                requireWire(number(1) in 1L..SUPPORTED_EVENTS)
            }
            2L -> {
                requireWire(fields.size == 1)
                uuid(0)
            }
            3L -> {
                requireWire(fields.size == 2)
                uuid(0)
                requireWire(number(1) in 0L..3L)
            }
            4L -> {
                requireWire(fields.size == 3)
                sessionSequence()
                val value = text(2)
                requireWire(value.isNotEmpty() && value.toByteArray(Charsets.UTF_8).size <= MAX_TEXT_BYTES)
            }
            5L -> {
                requireWire(fields.size == 5)
                sessionSequence()
                requireWire(number(2) in MIN_KEY_USAGE..MAX_KEY_USAGE)
                requireWire(number(3) in 0L..255L)
                flag(4)
            }
            6L, 8L -> {
                requireWire(fields.size == 4)
                sessionSequence()
                requireWire(number(2) in MIN_DELTA..MAX_DELTA)
                requireWire(number(3) in MIN_DELTA..MAX_DELTA)
            }
            7L -> {
                requireWire(fields.size == 4)
                sessionSequence()
                requireWire(number(2) in 0L..MAX_BUTTONS)
                requireWire(number(3) in 0L..255L)
            }
            9L, 10L -> {
                requireWire(fields.size == 2)
                sessionSequence()
            }
            else -> throw PhoneInputWireException()
        }
    }

    companion object {
        const val TAG = "aniCe phone input"
        const val VERSION = 1L
        const val MAX_TEXT_BYTES = 1024L
        const val SUPPORTED_EVENTS = 7L
        private const val MAX_SEQUENCE = 4294967295L
        private const val MIN_KEY_USAGE = 4L
        private const val MAX_KEY_USAGE = 231L
        private const val MIN_DELTA = -32767L
        private const val MAX_DELTA = 32767L
        private const val MAX_BUTTONS = 7L

        fun decode(bytes: ByteArray): PhoneInputMessage? {
            if (bytes.size > 4000) return null
            val row = (SessionCbor.decode(bytes) as? Cbor.Array)?.value ?: return null
            if ((row.firstOrNull() as? Cbor.Text)?.value != TAG) return null
            if (row.size != 4 || (row[1] as? Cbor.Integer)?.value != VERSION) {
                throw PhoneInputWireException()
            }
            val message =
                PhoneInputMessage(
                    (row[2] as? Cbor.Integer)?.value ?: throw PhoneInputWireException(),
                    (row[3] as? Cbor.Array)?.value ?: throw PhoneInputWireException(),
                )
            message.validate()
            if (!message.encode().contentEquals(bytes)) throw PhoneInputWireException()
            return message
        }

        fun of(kind: Long, vararg fields: Cbor) = PhoneInputMessage(kind, fields.toList())
    }
}
