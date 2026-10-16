// SPDX-License-Identifier: GPL-3.0-or-later
// Defines bounded Find Device envelopes within authenticated application DATA.
package io.github.anisharyal09.anice.features.finddevice

import io.github.anisharyal09.anice.infrastructure.session.*
import java.util.UUID

enum class FindResult { SUBMITTED, BLOCKED, STALE, BUSY, FAILED }
class FindWireException : Exception()
data class FindDeviceMessage(val kind: Long, val id: String = "", val sequence: Long = 0, val result: Long = 0) {
    fun encode(): ByteArray {
        val fields = if (kind == 1L) emptyList() else listOf(Cbor.Text(id), Cbor.Integer(sequence)) +
            if (kind == 3L) listOf(Cbor.Integer(result)) else emptyList()
        return SessionCbor.encode(Cbor.Array(listOf(Cbor.Text(TAG), Cbor.Integer(1), Cbor.Integer(kind), Cbor.Array(fields)))).also { decode(it) }
    }
    companion object {
        const val TAG = "aniCe find device"
        fun decode(bytes: ByteArray): FindDeviceMessage? {
            if (bytes.size > 4000) return null
            val row = (SessionCbor.decode(bytes) as? Cbor.Array)?.value ?: return null
            if ((row.firstOrNull() as? Cbor.Text)?.value != TAG) return null
            if (bytes.size > 128 || row.size != 4 || (row[1] as? Cbor.Integer)?.value != 1L) throw FindWireException()
            val kind = (row[2] as? Cbor.Integer)?.value ?: throw FindWireException()
            val fields = (row[3] as? Cbor.Array)?.value ?: throw FindWireException()
            if (kind == 1L && fields.isEmpty()) return FindDeviceMessage(1)
            if (!(kind == 2L && fields.size == 2 || kind == 3L && fields.size == 3)) throw FindWireException()
            val id = (fields[0] as? Cbor.Text)?.value ?: throw FindWireException()
            val validId = try { UUID.fromString(id).toString() == id } catch (_: IllegalArgumentException) { false }
            val sequence = (fields[1] as? Cbor.Integer)?.value ?: throw FindWireException()
            val result = if (kind == 3L) (fields[2] as? Cbor.Integer)?.value ?: throw FindWireException() else 0L
            if (!validId || sequence !in 1L..4294967295L || result !in 0L..4L) throw FindWireException()
            return FindDeviceMessage(kind, id, sequence, result)
        }
    }
}
