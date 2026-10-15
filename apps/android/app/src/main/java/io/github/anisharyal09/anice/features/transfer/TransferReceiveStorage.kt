// SPDX-License-Identifier: GPL-3.0-or-later
// Serializes received-file writes, hashing, publication and cleanup away from presentation threads.
package io.github.anisharyal09.anice.features.transfer

import android.net.Uri
import android.os.ParcelFileDescriptor
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.nio.file.Files
import java.security.MessageDigest
import java.util.UUID
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

internal class TransferReceiveStorage(private val folder: File, private val destination: TransferDestination?) {
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
                var target = File(folder, name)
                val dot = name.lastIndexOf('.')
                val base = if (dot > 0) name.substring(0, dot) else name
                val ext = if (dot > 0) name.substring(dot) else ""
                var suffix = 1
                while (target.exists()) target = File(folder, "$base (${suffix++})$ext")
                try { Files.createLink(target.toPath(), owned.toPath()) }
                catch (error: java.nio.file.AccessDeniedException) {
                    throw IOException("Destination cannot publish files exclusively", error)
                }
                Files.delete(owned.toPath())
                partial = null
            }
            actual
        }
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
