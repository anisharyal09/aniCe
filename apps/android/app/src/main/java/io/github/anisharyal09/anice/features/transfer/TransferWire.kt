// SPDX-License-Identifier: GPL-3.0-or-later
// Validates bounded transfer envelopes carried by existing authenticated DATA records.
package io.github.anisharyal09.anice.features.transfer

import io.github.anisharyal09.anice.infrastructure.session.*
import java.util.UUID

class TransferWireException : Exception("Invalid transfer message")

data class TransferMessage(val kind: Long, val fields: List<Cbor>) {
    fun string(i: Int) = (fields.getOrNull(i) as? Cbor.Text)?.value.orEmpty()
    fun number(i: Int) = (fields.getOrNull(i) as? Cbor.Integer)?.value ?: 0L
    fun bytes(i: Int) = (fields.getOrNull(i) as? Cbor.Bytes)?.value ?: ByteArray(0)

    fun encode(maximumChunkBytes: Int = 3072): ByteArray {
        validate(maximumChunkBytes)
        return SessionCbor.encode(
            Cbor.Array(
                listOf(
                    Cbor.Text("aniCe transfer"),
                    Cbor.Integer(1),
                    Cbor.Integer(kind),
                    Cbor.Array(fields)
                )
            ),
            maximumBytes = if (maximumChunkBytes > 262016) 524416 else if (maximumChunkBytes > 3072) 262144 else 4096
        ).also { if (it.size > if (maximumChunkBytes > 262016) 524416 else if (maximumChunkBytes > 3072) 262144 else 4000) throw TransferWireException() }
    }

    fun validate(maximumChunkBytes: Int = 3072) {
        require(maximumChunkBytes in 1..524288)
        fun check(v: Boolean) { if (!v) throw TransferWireException() }
        fun n(v: Cbor?, min: Long, max: Long) = (v as? Cbor.Integer)?.value?.let { it in min..max } == true
        fun t(v: Cbor?, max: Int, uuid: Boolean = false, empty: Boolean = false): Boolean {
            val s = (v as? Cbor.Text)?.value ?: return false
            val utf8Size = s.toByteArray(Charsets.UTF_8).size
            if (utf8Size > max || '\u0000' in s) return false
            if (uuid) {
                if (empty && s.isEmpty()) return true
                return s.length == 36 && runCatching { UUID.fromString(s).toString().equals(s, true) }.getOrDefault(false)
            }
            return utf8Size > 0 || empty
        }
        fun filename(v: Cbor?): Boolean {
            val s = (v as? Cbor.Text)?.value ?: return false
            val bytes = s.toByteArray(Charsets.UTF_8)
            if (bytes.isEmpty() || bytes.size > 255) return false
            if ('/' in s || '\\' in s || '\u0000' in s) return false
            if (s == "." || s == ".." || s.contains("../") || s.contains("..\\")) return false
            return s.none { it < ' ' }
        }
        fun b(v: Cbor?, size: Int): Boolean = (v as? Cbor.Bytes)?.value?.size == size

        when (kind) {
            1L -> { // capability
                check(fields.size == 3 && (n(fields[0], 1, 1) && n(fields[1], 1, 3072) && n(fields[2], 1, 64) ||
                    maximumChunkBytes > 3072 && n(fields[0], 2, 2) && n(fields[1], 1, minOf(131072, maximumChunkBytes).toLong()) && n(fields[2], 1, 8) ||
                    maximumChunkBytes > 131072 && n(fields[0], 3, 3) && n(fields[1], 1, minOf(262016, maximumChunkBytes).toLong()) && n(fields[2], 1, 8) ||
                    maximumChunkBytes > 262016 && n(fields[0], 4, 4) && n(fields[1], 1, maximumChunkBytes.toLong()) && n(fields[2], 1, 8)))
            }
            2L -> { // offer: [batch, sliceIndex, totalSlices, totalFiles, totalBytes, files]
                check(fields.size == 6 && t(fields[0], 36, uuid = true) && n(fields[1], 0, 15) &&
                    n(fields[2], 1, 16) && n(fields[3], 1, 128) && n(fields[4], 0, Long.MAX_VALUE))
                check(number(1) < number(2))
                val files = (fields[5] as? Cbor.Array)?.value ?: throw TransferWireException()
                check(files.isNotEmpty() && files.size <= 8)
                val fileIds = mutableSetOf<String>()
                files.forEach { f ->
                    val row = (f as? Cbor.Array)?.value ?: throw TransferWireException()
                    check(row.size == 4)
                    check(t(row[0], 36, uuid = true))
                    val id = (row[0] as Cbor.Text).value
                    check(fileIds.add(id))
                    check(filename(row[1]))
                    check(n(row[2], 0, Long.MAX_VALUE))
                    check(b(row[3], 32))
                }
            }
            3L -> { // accept: [batch, acceptedFiles]
                check(fields.size == 2 && t(fields[0], 36, uuid = true))
                val files = (fields[1] as? Cbor.Array)?.value ?: throw TransferWireException()
                check(files.size <= 64)
                files.forEach { check(t(it, 36, uuid = true)) }
            }
            4L -> { // reject: [batch, reason]
                check(fields.size == 2 && t(fields[0], 36, uuid = true) && n(fields[1], 0, 4))
            }
            5L -> { // chunk: [batch, file, offset, data]
                check(fields.size == 4 && t(fields[0], 36, uuid = true) && t(fields[1], 36, uuid = true) &&
                    n(fields[2], 0, Long.MAX_VALUE))
                val data = (fields[3] as? Cbor.Bytes)?.value ?: throw TransferWireException()
                check(data.isNotEmpty() && data.size <= maximumChunkBytes)
            }
            6L -> { // ack: [batch, file, written]
                check(fields.size == 3 && t(fields[0], 36, uuid = true) && t(fields[1], 36, uuid = true) &&
                    n(fields[2], 0, Long.MAX_VALUE))
            }
            7L -> { // file-result: [batch, file, result, hash]
                check(fields.size == 4 && t(fields[0], 36, uuid = true) && t(fields[1], 36, uuid = true) &&
                    n(fields[2], 0, 3) && b(fields[3], 32))
            }
            8L -> { // batch-result: [batch, result]
                check(fields.size == 2 && t(fields[0], 36, uuid = true) && n(fields[1], 0, 3))
            }
            9L -> { // cancel: [batch, file, reason]
                check(fields.size == 3 && t(fields[0], 36, uuid = true) && t(fields[1], 36, uuid = true, empty = true) &&
                    n(fields[2], 0, 4))
            }
            10L -> { // resume: [batch, file, offset, prefixHash]
                check(fields.size == 4 && t(fields[0], 36, uuid = true) && t(fields[1], 36, uuid = true) &&
                    n(fields[2], 0, Long.MAX_VALUE) && b(fields[3], 32))
            }
            11L -> { // status: [batch, file, bytesTransferred, state]
                check(fields.size == 4 && t(fields[0], 36, uuid = true) && t(fields[1], 36, uuid = true, empty = true) &&
                    n(fields[2], 0, Long.MAX_VALUE) && n(fields[3], 0, 4))
            }
            else -> throw TransferWireException()
        }
    }

    companion object {
        private val header = byteArrayOf(0x84.toByte(), 0x6e) + "aniCe transfer".toByteArray(Charsets.UTF_8) + byteArrayOf(1)
        // Session CBOR rejects non-minimal lengths; classification never replaces full validation.
        internal fun peekKind(bytes: ByteArray): Int? =
            if (bytes.size > header.size && header.indices.all { bytes[it] == header[it] })
                (bytes[header.size].toInt() and 255).takeIf { it in 1..11 } else null

        fun decode(bytes: ByteArray, maximumChunkBytes: Int = 3072): TransferMessage? {
            if (bytes.size > if (maximumChunkBytes > 262016) 524416 else if (maximumChunkBytes > 3072) 262144 else 4000) throw TransferWireException()
            val row = (SessionCbor.decode(bytes, if (maximumChunkBytes > 262016) 524416 else if (maximumChunkBytes > 3072) 262144 else 4096) as? Cbor.Array)?.value ?: return null
            if (row.firstOrNull() != Cbor.Text("aniCe transfer")) return null
            if (row.size != 4 || row[1] != Cbor.Integer(1)) throw TransferWireException()
            val kind = (row[2] as? Cbor.Integer)?.value ?: throw TransferWireException()
            val fields = (row[3] as? Cbor.Array)?.value ?: throw TransferWireException()
            return TransferMessage(kind, fields).also { it.validate(maximumChunkBytes) }
        }

        fun capability(version: Long = 1L, maxChunkBytes: Long = 3072L, maxWindow: Long = 64L) =
            TransferMessage(1L, listOf(Cbor.Integer(version), Cbor.Integer(maxChunkBytes), Cbor.Integer(maxWindow)))

        fun offer(batch: String, sliceIndex: Long, totalSlices: Long, totalFiles: Long, totalBytes: Long, files: List<Cbor>) =
            TransferMessage(2L, listOf(Cbor.Text(batch), Cbor.Integer(sliceIndex), Cbor.Integer(totalSlices), Cbor.Integer(totalFiles), Cbor.Integer(totalBytes), Cbor.Array(files)))

        fun accept(batch: String, files: List<String> = emptyList()) =
            TransferMessage(3L, listOf(Cbor.Text(batch), Cbor.Array(files.map { Cbor.Text(it) })))

        fun reject(batch: String, reason: Long) =
            TransferMessage(4L, listOf(Cbor.Text(batch), Cbor.Integer(reason)))

        fun chunk(batch: String, file: String, offset: Long, data: ByteArray) =
            TransferMessage(5L, listOf(Cbor.Text(batch), Cbor.Text(file), Cbor.Integer(offset), Cbor.Bytes(data)))

        /** Frames a chunk straight out of a reused read buffer, copying the chunk bytes only once. */
        fun chunkFrom(batch: String, file: String, offset: Long, source: ByteArray, length: Int) =
            TransferMessage(5L, listOf(Cbor.Text(batch), Cbor.Text(file), Cbor.Integer(offset), Cbor.Bytes(source, 0, length)))

        fun ack(batch: String, file: String, written: Long) =
            TransferMessage(6L, listOf(Cbor.Text(batch), Cbor.Text(file), Cbor.Integer(written)))

        fun fileResult(batch: String, file: String, result: Long, hash: ByteArray) =
            TransferMessage(7L, listOf(Cbor.Text(batch), Cbor.Text(file), Cbor.Integer(result), Cbor.Bytes(hash)))

        fun batchResult(batch: String, result: Long) =
            TransferMessage(8L, listOf(Cbor.Text(batch), Cbor.Integer(result)))

        fun cancel(batch: String, file: String = "", reason: Long = 0L) =
            TransferMessage(9L, listOf(Cbor.Text(batch), Cbor.Text(file), Cbor.Integer(reason)))

        fun resume(batch: String, file: String, offset: Long, prefixHash: ByteArray) =
            TransferMessage(10L, listOf(Cbor.Text(batch), Cbor.Text(file), Cbor.Integer(offset), Cbor.Bytes(prefixHash)))

        fun status(batch: String, file: String = "", bytesTransferred: Long, state: Long) =
            TransferMessage(11L, listOf(Cbor.Text(batch), Cbor.Text(file), Cbor.Integer(bytesTransferred), Cbor.Integer(state)))
    }
}
