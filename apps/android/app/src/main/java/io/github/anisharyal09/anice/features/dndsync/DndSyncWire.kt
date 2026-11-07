// SPDX-License-Identifier: GPL-3.0-or-later
package io.github.anisharyal09.anice.features.dndsync

import io.github.anisharyal09.anice.infrastructure.session.Cbor
import io.github.anisharyal09.anice.infrastructure.session.SessionCbor
import java.util.UUID

data class DndSyncMessage(val kind: Long, val sending: Boolean = false, val receiving: Boolean = false,
    val id: String = "", val enabled: Boolean = false, val result: Long = 0) {
    fun encode(): ByteArray {
        val fields = when (kind) {
            1L -> listOf(Cbor.Bool(sending), Cbor.Bool(receiving))
            2L -> listOf(Cbor.Text(id), Cbor.Bool(enabled))
            3L -> listOf(Cbor.Text(id), Cbor.Integer(result))
            else -> error("Invalid DND record")
        }
        return SessionCbor.encode(Cbor.Array(listOf(Cbor.Text(TAG), Cbor.Integer(1), Cbor.Integer(kind), Cbor.Array(fields))))
            .also { require(decode(it) == this) }
    }
    companion object {
        const val TAG = "aniCe dnd sync"
        fun decode(bytes: ByteArray): DndSyncMessage? {
            val row = (SessionCbor.decode(bytes) as? Cbor.Array)?.value ?: return null
            if ((row.firstOrNull() as? Cbor.Text)?.value != TAG) return null
            require(bytes.size <= 128 && row.size == 4 && row[1] == Cbor.Integer(1))
            val kind = (row[2] as? Cbor.Integer)?.value ?: error("Invalid kind")
            val fields = (row[3] as? Cbor.Array)?.value ?: error("Invalid fields")
            require(fields.size == 2)
            if (kind == 1L) return DndSyncMessage(kind, sending = (fields[0] as? Cbor.Bool)?.value ?: error("Invalid flag"),
                receiving = (fields[1] as? Cbor.Bool)?.value ?: error("Invalid flag"))
            val id = (fields[0] as? Cbor.Text)?.value ?: error("Invalid ID")
            require(id.length == 36 && UUID.fromString(id).toString() == id)
            return when (kind) {
                2L -> DndSyncMessage(kind, id = id, enabled = (fields[1] as? Cbor.Bool)?.value ?: error("Invalid state"))
                3L -> DndSyncMessage(kind, id = id, result = (fields[1] as? Cbor.Integer)?.value?.also { require(it in 0L..4L) } ?: error("Invalid result"))
                else -> error("Invalid kind")
            }
        }
    }
}

// Suppress the asynchronous native callback caused by a remote change; callbacks carry no request ID.
class DndEchoGuard {
    private var observed: Boolean? = null
    private var expected: Boolean? = null
    private var expires = 0L
    fun baseline(value: Boolean?) { observed = value; expected = null }
    fun applying(value: Boolean, now: Long) { expected = value; expires = now + 15_000 }
    fun changed(value: Boolean, now: Long): Boolean {
        val duplicate = observed == value
        observed = value
        val echo = expected == value && now <= expires
        if (echo || !duplicate || now > expires) expected = null
        return !duplicate && !echo
    }
}
