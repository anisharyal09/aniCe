// SPDX-License-Identifier: GPL-3.0-or-later
// Serializes received-file writes, hashing, publication and cleanup away from presentation threads.
package io.github.anisharyal09.anice.features.transfer

import android.net.Uri
import android.os.ParcelFileDescriptor
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.nio.file.AccessDeniedException
import java.nio.file.FileAlreadyExistsException
import java.nio.file.Files
import java.security.MessageDigest
import java.util.UUID
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

internal class TransferReceiveStorage(
    private val folder: File,
    private val destination: TransferDestination?,
    /** The link primitive, so a destination that cannot hold hard links is verifiable without one. */
    private val link: (target: File, owned: File) -> Unit = { target, owned -> Files.createLink(target.toPath(), owned.toPath()) },
) {
    private val mutex = Mutex()
    private var stream: FileOutputStream? = null
    private var partial: File? = null
    private var document: Uri? = null
    private val digest by lazy { MessageDigest.getInstance("SHA-256") }
    private var preservePartial = false

    suspend fun create(batch: String, file: String): Pair<File?, Uri?> = withContext(Dispatchers.IO) {
        mutex.withLock {
            check(stream == null)
            val name = ".anice-$batch-$file-${UUID.randomUUID()}.part"
            if (destination != null) {
                val uri = destination.create(name)
                document = uri
                stream = ParcelFileDescriptor.AutoCloseOutputStream(destination.descriptor(uri))
            } else {
                if (!folder.isDirectory && !folder.mkdirs()) throw IOException("Cannot create destination folder")
                val owned = File(folder, name)
                if (!owned.createNewFile()) throw IOException("Partial file already exists")
                partial = owned
                stream = FileOutputStream(owned)
            }
            Pair(partial, document)
        }
    }

    suspend fun write(bytes: ByteArray) = withContext(Dispatchers.IO) {
        mutex.withLock {
            val output = stream ?: throw IOException("Received file is closed")
            output.write(bytes)
            digest.update(bytes)
        }
    }

    /** Pushes retained bytes to the provider before they are read back for resume verification. */
    suspend fun flush() = withContext(Dispatchers.IO) {
        mutex.withLock { stream?.fd?.sync() }
    }

    /**
     * Hashes exactly [length] bytes of the retained partial after flushing it. The partial is read
     * back rather than trusted from memory so a provider that lost or reordered bytes cannot be
     * resumed from a corrupt offset. A receiver-initiated continuation sends this digest so the
     * sender can prove its own source prefix before switching transports.
     */
    suspend fun prefixDigest(length: Long): ByteArray = withContext(Dispatchers.IO) {
        mutex.withLock {
            val output = stream ?: throw IOException("Received file is closed")
            output.fd.sync()
            val input = partial?.let { FileInputStream(it) }
                ?: document?.let { destination!!.read(it) }
                ?: throw IOException("Received file is closed")
            val actual = MessageDigest.getInstance("SHA-256")
            input.use { source ->
                var remaining = length
                val buffer = ByteArray(131072)
                while (remaining > 0) {
                    val count = source.read(buffer, 0, minOf(buffer.size.toLong(), remaining).toInt())
                    if (count < 0) throw IOException("Partial ended before the retained offset")
                    if (count == 0) throw IOException("Partial file made no progress")
                    actual.update(buffer, 0, count)
                    remaining -= count
                }
            }
            actual.digest()
        }
    }

    /** Verifies that the retained partial still begins with the sender's [length]-byte prefix. */
    suspend fun matchesPrefix(length: Long, expected: ByteArray): Boolean =
        try { prefixDigest(length).contentEquals(expected) }
        catch (_: IOException) { false }

    suspend fun finish(name: String, expected: ByteArray): ByteArray = withContext(Dispatchers.IO) {
        mutex.withLock {
            val actual = digest.digest()
            if (!actual.contentEquals(expected)) throw IOException("Hash mismatch")
            // Valid complete partials survive a failed flush or publication for recovery.
            preservePartial = true
            val output = stream ?: throw IOException("Received file is closed")
            output.fd.sync()
            output.close()
            stream = null
            document?.let { destination!!.finish(it, name); document = null }
            partial?.let { owned ->
                publish(folder, name, owned)
                partial = null
            }
            actual
        }
    }

    /**
     * Publishes the verified partial under a name that does not overwrite an existing file.
     * The link is what decides the name, so two publications cannot both win the same one and there
     * is no check-then-act window. A destination that cannot hold hard links publishes by copying
     * instead: the digest is verified before this method runs, so a copy cannot publish unverified
     * bytes, and publication is non-overwriting in both modes.
     */
    private fun publish(folder: File, name: String, owned: File) {
        var suffix = 0
        var copying = false
        while (suffix < TransferNaming.MAXIMUM_SUFFIX) {
            val target = File(folder, TransferNaming.suffixed(name, suffix))
            try {
                if (copying) Files.copy(owned.toPath(), target.toPath())
                else link(target, owned)
                Files.delete(owned.toPath())
                return
            } catch (_: FileAlreadyExistsException) {
                suffix++
            } catch (error: AccessDeniedException) {
                throw IOException("Destination cannot publish files exclusively", error)
            } catch (error: Exception) {
                // A hard link is an implementation detail of this folder, not a requirement of the
                // transfer, so an unsupported link falls back to one copy. Whatever the copy also
                // rejects is reported rather than swallowed.
                if (copying) throw IOException("Cannot publish the received file.", error)
                copying = true
                suffix = 0
            }
        }
        throw IOException("Cannot find an unused name for \"$name\".")
    }

    suspend fun discard() = withContext(Dispatchers.IO) {
        mutex.withLock {
            try { stream?.close() } finally { stream = null }
            if (!preservePartial) {
                partial?.let { if (it.exists() && !it.delete()) throw IOException("Cannot remove partial file") }
                document?.let { destination!!.delete(it) }
            }
        }
    }
}
