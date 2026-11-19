// SPDX-License-Identifier: GPL-3.0-or-later
// Carries a peer's automatic-connection pause over an existing authenticated session.
package io.github.anisharyal09.anice.features.connectionpause

import io.github.anisharyal09.anice.infrastructure.session.Cbor
import io.github.anisharyal09.anice.infrastructure.session.SessionCbor
import io.github.anisharyal09.anice.infrastructure.session.SessionException

class ConnectionPauseWireException : Exception()

/** Kind 1 pauses until [until] epoch milliseconds (0 means until manually resumed); kind 2 resumes. */
data class ConnectionPauseMessage(val kind: Long, val until: Long = 0L) {
    fun encode(): ByteArray {
        val fields = when (kind) {
            1L -> {
                if (until !in 0L..MAX_UNTIL_MILLIS) throw ConnectionPauseWireException()
                listOf(Cbor.Integer(until))
            }
            2L -> {
                if (until != 0L) throw ConnectionPauseWireException()
                listOf(Cbor.Integer(0))
            }
            else -> throw ConnectionPauseWireException()
        }
        val bytes = SessionCbor.encode(Cbor.Array(listOf(Cbor.Text(TAG), Cbor.Integer(1),
            Cbor.Integer(kind), Cbor.Array(fields))))
        if (bytes.size > MAX_BYTES) throw ConnectionPauseWireException()
        decode(bytes) ?: throw ConnectionPauseWireException()
        return bytes
    }

    companion object {
        const val TAG = "aniCe connection pause"
        const val MAX_BYTES = 128
        const val MAX_UNTIL_MILLIS = 253402300799999L

        fun decode(bytes: ByteArray): ConnectionPauseMessage? {
            if (bytes.size > MAX_BYTES) return null
            val row = try { (SessionCbor.decode(bytes, maximumBytes = MAX_BYTES) as? Cbor.Array)?.value }
                catch (_: SessionException) { throw ConnectionPauseWireException() }
                ?: return null
            if ((row.firstOrNull() as? Cbor.Text)?.value != TAG) return null
            if (row.size != 4 || (row[1] as? Cbor.Integer)?.value != 1L) throw ConnectionPauseWireException()
            val kind = (row[2] as? Cbor.Integer)?.value ?: throw ConnectionPauseWireException()
            val fields = (row[3] as? Cbor.Array)?.value ?: throw ConnectionPauseWireException()
            val until = (fields.singleOrNull() as? Cbor.Integer)?.value ?: throw ConnectionPauseWireException()
            val message = ConnectionPauseMessage(kind, until)
            if (kind !in 1L..2L || until !in 0L..MAX_UNTIL_MILLIS || (kind == 2L && until != 0L))
                throw ConnectionPauseWireException()
            return message
        }
    }
}
