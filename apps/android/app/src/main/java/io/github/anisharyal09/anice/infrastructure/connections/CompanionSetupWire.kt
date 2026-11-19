// SPDX-License-Identifier: GPL-3.0-or-later
// Requests bounded native enrollment visibility inside an existing authenticated BLE channel.
package io.github.anisharyal09.anice.infrastructure.connections

import io.github.anisharyal09.anice.infrastructure.session.*

internal data class CompanionSetupMessage(val kind: Long, val available: Boolean = false, val seconds: Long = 0) {
    fun encode(): ByteArray {
        val fields = when (kind) {
            1L -> listOf(Cbor.Integer(1))
            2L -> { require(seconds == 0L || seconds == 60L); listOf(Cbor.Integer(seconds)) }
            3L -> listOf(Cbor.Bool(available))
            else -> error("Unsupported companion setup kind")
        }
        return SessionCbor.encode(Cbor.Array(listOf(Cbor.Text(TAG), Cbor.Integer(1),
            Cbor.Integer(kind), Cbor.Array(fields))), 128)
    }
    companion object {
        const val TAG = "aniCe companion setup"
        fun decode(bytes: ByteArray): CompanionSetupMessage? {
            if (bytes.size > 128) return null
            val row = (SessionCbor.decode(bytes) as? Cbor.Array)?.value ?: return null
            if ((row.firstOrNull() as? Cbor.Text)?.value != TAG) return null
            require(row.size == 4 && row[1] == Cbor.Integer(1))
            val fields = (row[3] as? Cbor.Array)?.value ?: error("Invalid companion setup fields")
            require(fields.size == 1)
            val kind = (row[2] as? Cbor.Integer)?.value ?: error("Invalid companion setup kind")
            return when (kind) {
                1L -> { require(fields[0] == Cbor.Integer(1)); CompanionSetupMessage(kind) }
                2L -> {
                    val seconds = (fields[0] as? Cbor.Integer)?.value ?: error("Invalid companion setup seconds")
                    require(seconds == 0L || seconds == 60L)
                    CompanionSetupMessage(kind, seconds = seconds)
                }
                3L -> CompanionSetupMessage(kind,
                    available = (fields[0] as? Cbor.Bool)?.value ?: error("Invalid companion setup ack"))
                else -> error("Unsupported companion setup kind")
            }
        }
    }
}
