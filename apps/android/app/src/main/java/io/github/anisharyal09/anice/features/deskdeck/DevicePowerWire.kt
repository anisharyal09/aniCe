// SPDX-License-Identifier: GPL-3.0-or-later
// Carries truthful Android battery state over an existing authenticated session.
package io.github.anisharyal09.anice.features.deskdeck

import io.github.anisharyal09.anice.infrastructure.session.Cbor
import io.github.anisharyal09.anice.infrastructure.session.SessionCbor

class DevicePowerWireException : Exception()

data class DevicePowerMessage(val kind: Long, val state: Long = 0, val percent: Long = -1, val source: Long = 0) {
    fun encode(): ByteArray {
        val fields = when (kind) {
            1L -> listOf(Cbor.Integer(1))
            2L -> listOf(Cbor.Integer(state), Cbor.Integer(percent), Cbor.Integer(source))
            else -> throw DevicePowerWireException()
        }
        val bytes = SessionCbor.encode(Cbor.Array(listOf(Cbor.Text(TAG), Cbor.Integer(1), Cbor.Integer(kind), Cbor.Array(fields))))
        if (bytes.size > MAX_BYTES) throw DevicePowerWireException()
        decode(bytes) ?: throw DevicePowerWireException()
        return bytes
    }

    companion object {
        const val TAG = "aniCe device power"
        const val MAX_BYTES = 128

        fun decode(bytes: ByteArray): DevicePowerMessage? {
            if (bytes.size > MAX_BYTES) return null
            val row = (SessionCbor.decode(bytes) as? Cbor.Array)?.value ?: return null
            if ((row.firstOrNull() as? Cbor.Text)?.value != TAG) return null
            if (row.size != 4 || (row[1] as? Cbor.Integer)?.value != 1L) throw DevicePowerWireException()
            val kind = (row[2] as? Cbor.Integer)?.value ?: throw DevicePowerWireException()
            val fields = (row[3] as? Cbor.Array)?.value ?: throw DevicePowerWireException()
            fun number(index: Int) = (fields.getOrNull(index) as? Cbor.Integer)?.value ?: throw DevicePowerWireException()
            if (kind == 1L) {
                if (fields.size != 1 || number(0) != 1L) throw DevicePowerWireException()
                return DevicePowerMessage(kind)
            }
            if (kind == 2L) {
                if (fields.size != 3) throw DevicePowerWireException()
                val message = DevicePowerMessage(kind, number(0), number(1), number(2))
                if (message.state !in 0L..5L || message.percent !in -1L..100L || message.source !in 0L..5L ||
                    (message.state in 0L..1L && message.percent != -1L)) {
                    throw DevicePowerWireException()
                }
                return message
            }
            throw DevicePowerWireException()
        }
    }
}
