// SPDX-License-Identifier: GPL-3.0-or-later
// Stores bounded transfer checkpoints independently of transport keys and record generations.
package io.github.anisharyal09.anice.features.transfer

import android.net.Uri
import java.io.*
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.UUID

internal data class TransferCheckpoint(
    val localFingerprint: String,
    val peerId: String,
    val peerFingerprint: String,
    val batch: TransferBatch,
    val receiving: Boolean,
    val index: Int,
    val offset: Long,
    val folder: String,
    val tree: String,
    val partial: String,
    val document: String,
    val transport: String,
    val expiresAt: Long,
    val stage: Int = 0,
    val fileIdentity: String = "",
    val treeModes: Int = 0,
)

internal class TransferRecoveryStore(private val file: File, private val replace: (File, File) -> Unit = { source, target ->
    Files.move(source.toPath(), target.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
}) {
    fun save(snapshot: TransferCheckpoint) {
        val bytes = encode(snapshot)
        val folder = file.parentFile ?: throw IOException("Missing recovery folder")
        if (!folder.isDirectory && !folder.mkdirs()) throw IOException("Cannot create recovery folder")
        val temporary = File.createTempFile("checkpoint-", ".tmp", folder)
        try {
            FileOutputStream(temporary).use { it.write(bytes); it.fd.sync() }
            replace(temporary, file)
        } finally { if (temporary.exists() && !temporary.delete()) throw IOException("Cannot remove recovery temporary") }
    }

    fun load(): TransferCheckpoint? {
        if (!file.exists()) return null
        if (file.length() !in 1..MAX_BYTES) throw IOException("Invalid transfer checkpoint size")
        return decode(file.readBytes())
    }

    fun clear() {
        if (file.exists() && !file.delete()) throw IOException("Cannot remove transfer checkpoint")
    }

    companion object {
        private const val MAX_BYTES = 1024L * 1024
        private fun DataOutputStream.text(value: String) {
            val bytes = value.toByteArray(Charsets.UTF_8)
            require(bytes.size <= 8192)
            writeInt(bytes.size); write(bytes)
        }
        private fun DataInputStream.text(): String {
            val size = readInt()
            if (size !in 0..8192 || size > available()) throw IOException("Invalid checkpoint string")
            val bytes = ByteArray(size).also(::readFully)
            val value = bytes.toString(Charsets.UTF_8)
            if (!value.toByteArray(Charsets.UTF_8).contentEquals(bytes)) throw IOException("Invalid checkpoint UTF-8")
            return value
        }
        fun encode(value: TransferCheckpoint): ByteArray {
            validate(value)
            val bytes = ByteArrayOutputStream()
            DataOutputStream(bytes).use { out ->
                out.writeInt(1)
                for (s in listOf(value.localFingerprint, value.peerId, value.peerFingerprint,
                    value.batch.id, value.batch.peerName)) out.text(s)
                out.writeLong(value.batch.totalBytes); out.writeInt(value.batch.files.size)
                value.batch.files.forEach { file ->
                    out.text(file.id); out.text(file.name); out.writeLong(file.size); out.write(file.sha256)
                    out.text(file.sourceFile?.absolutePath ?: ""); out.text(file.sourceUri?.toString() ?: "")
                    out.writeBoolean(file.ownsReadGrant)
                }
                out.writeBoolean(value.receiving); out.writeInt(value.index); out.writeLong(value.offset)
                for (s in listOf(value.folder, value.tree, value.partial, value.document, value.transport)) out.text(s)
                out.writeLong(value.expiresAt)
                out.writeInt(value.stage)
                out.text(value.fileIdentity)
                out.writeInt(value.treeModes)
            }
            return bytes.toByteArray().also { require(it.size <= MAX_BYTES) }
        }
        fun decode(bytes: ByteArray): TransferCheckpoint {
            if (bytes.size.toLong() !in 1..MAX_BYTES) throw IOException("Invalid checkpoint size")
            return DataInputStream(ByteArrayInputStream(bytes)).use { input ->
                if (input.readInt() != 1) throw IOException("Unsupported checkpoint")
                val local = input.text(); val peer = input.text(); val fingerprint = input.text()
                val id = input.text(); val name = input.text(); val total = input.readLong()
                val count = input.readInt()
                if (count !in 1..128) throw IOException("Invalid checkpoint file count")
                val files = List(count) {
                    val fileId = input.text(); val fileName = input.text(); val size = input.readLong()
                    val hash = ByteArray(32).also(input::readFully)
                    val source = input.text(); val uri = input.text()
                    TransferFile(fileId, fileName, size, hash, source.takeIf { it.isNotEmpty() }?.let(::File),
                        uri.takeIf { it.isNotEmpty() }?.let(Uri::parse), input.readBoolean())
                }
                TransferCheckpoint(local, peer, fingerprint, TransferBatch(id, files, total, name),
                    input.readBoolean(), input.readInt(), input.readLong(), input.text(), input.text(),
                    input.text(), input.text(), input.text(), input.readLong(), input.readInt(), input.text(), input.readInt()).also {
                    if (input.available() != 0) throw IOException("Trailing checkpoint data")
                    validate(it)
                }
            }
        }
        private fun validate(value: TransferCheckpoint) {
            require(value.localFingerprint.matches(Regex("[0-9a-f]{64}")))
            require(value.peerFingerprint.matches(Regex("[0-9a-f]{64}")))
            require(UUID.fromString(value.peerId).toString() == value.peerId)
            require(UUID.fromString(value.batch.id).toString() == value.batch.id)
            require(value.batch.files.size in 1..128 && value.index in value.batch.files.indices)
            require(value.batch.files.map { it.id }.toSet().size == value.batch.files.size)
            var total = 0L
            value.batch.files.forEach {
                require(UUID.fromString(it.id).toString() == it.id && it.size >= 0 && it.sha256.size == 32)
                require(it.name.toByteArray(Charsets.UTF_8).size in 1..255 && it.name !in listOf(".", ".."))
                require(it.name.none { c -> c < ' ' || c == '/' || c == '\\' })
                total = Math.addExact(total, it.size)
            }
            require(total == value.batch.totalBytes && value.offset in 0..value.batch.files[value.index].size)
            require(value.transport in listOf("lan", "ble") && value.expiresAt > 0)
            require(value.stage in 0..4)
            require(value.stage != 1 || !value.receiving)
            require(value.stage != 2 || value.receiving)
            require(value.stage != 3 || value.receiving && value.index == value.batch.files.lastIndex && value.offset == value.batch.files.last().size)
            require(value.stage != 4 || value.receiving && value.offset == value.batch.files[value.index].size)
            require(value.treeModes in 0..3)
        }
    }
}
