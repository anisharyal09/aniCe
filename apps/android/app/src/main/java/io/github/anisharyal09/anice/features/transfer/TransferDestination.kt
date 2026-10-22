// SPDX-License-Identifier: GPL-3.0-or-later
// Owns an approved document-tree grant and validates provider operations before receiving files.
package io.github.anisharyal09.anice.features.transfer

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import java.io.IOException
import java.util.UUID

internal class TransferDestination(private val context: Context, val tree: Uri, modes: Int, restoredOwnedModes: Int? = null) {
    private val resolver = context.contentResolver
    private val flags = modes and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
    private val previousModes = resolver.persistedUriPermissions.firstOrNull { it.uri == tree }?.let {
        (if (it.isReadPermission) Intent.FLAG_GRANT_READ_URI_PERMISSION else 0) or
            (if (it.isWritePermission) Intent.FLAG_GRANT_WRITE_URI_PERMISSION else 0)
    } ?: 0
    val ownedModes = restoredOwnedModes ?: (flags and previousModes.inv())
    private val root = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
    private var closed = false

    init {
        require(ownedModes and flags.inv() == 0) { "Invalid retained folder grant." }
        require(flags == (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)) {
            "The folder must grant read and write access."
        }
        require(tree.authority in setOf("com.android.externalstorage.documents", "com.android.providers.downloads.documents")) {
            "Choose a folder from local device storage; this provider is not supported."
        }
        if (restoredOwnedModes == null) resolver.takePersistableUriPermission(tree, flags)
    }

    fun preflight(bytes: Long) {
        var probe = create(".anice-probe-${UUID.randomUUID()}")
        try {
            descriptor(probe).use { fd ->
                android.system.Os.write(fd.fileDescriptor, byteArrayOf(42), 0, 1)
                android.system.Os.fsync(fd.fileDescriptor)
                android.system.Os.lseek(fd.fileDescriptor, 0, android.system.OsConstants.SEEK_SET)
                val sample = ByteArray(1)
                if (android.system.Os.read(fd.fileDescriptor, sample, 0, 1) != 1 || sample[0] != 42.toByte()) {
                    throw IOException("This folder cannot read back received data.")
                }
                val space = android.system.Os.fstatvfs(fd.fileDescriptor)
                val available = space.f_bavail.toDouble() * space.f_frsize
                if (bytes.toDouble() + 64 * 1048576 > available) throw IOException("Not enough free space; 64 MiB must remain available.")
            }
            probe = DocumentsContract.renameDocument(resolver, probe, ".anice-probe-renamed-${UUID.randomUUID()}")
                ?: throw IOException("This folder cannot rename received files. Choose another local folder.")
        } finally {
            if (!DocumentsContract.deleteDocument(resolver, probe)) throw IOException("This folder cannot delete partial files.")
        }
    }

    fun create(name: String): Uri = DocumentsContract.createDocument(resolver, root, "application/octet-stream", name)
        ?: throw IOException("Cannot create a partial file in this folder.")

    fun descriptor(uri: Uri): ParcelFileDescriptor = resolver.openFileDescriptor(uri, "rw")
        ?: throw IOException("Cannot open the received document.")

    fun read(uri: Uri): java.io.InputStream = resolver.openInputStream(uri)
        ?: throw IOException("Cannot read the received document.")

    fun ownsPartial(uri: Uri, prefix: String): Boolean {
        if (uri.authority != tree.authority) return false
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, DocumentsContract.getDocumentId(root))
        resolver.query(children, arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null)?.use { rows ->
            while (rows.moveToNext()) {
                if (rows.getString(0) == DocumentsContract.getDocumentId(uri)) {
                    val name = rows.getString(1) ?: return false
                    return name.startsWith(prefix) && name.endsWith(".part")
                }
            }
        }
        return false
    }

    fun finish(uri: Uri, name: String): Uri {
        val taken = existingNames()
        var suffix = 0
        while (suffix < TransferNaming.MAXIMUM_SUFFIX) {
            val candidate = TransferNaming.suffixed(name, suffix)
            if (candidate !in taken) {
                // SAF has no exclusive rename-if-absent: the listing taken above *is* this file's
                // collision check, and a rename that fails for any other reason is reported as a
                // provider failure rather than retried as if it were a collision. A taken name
                // advances the suffix instead, so nothing here overwrites an existing document.
                return DocumentsContract.renameDocument(resolver, uri, candidate)
                    ?: throw IOException("Cannot finalize the received file. The provider refused renaming.")
            }
            suffix++
        }
        throw IOException("Cannot find an unused name for \"$name\".")
    }

    /**
     * Display names already present in the destination folder.
     * Receiving a file must not fail on a name that is already in use, so a collision is resolved by
     * suffixing here and never by overwriting the existing document or discarding a transfer that has
     * already been received and verified.
     */
    private fun existingNames(): Set<String> {
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, DocumentsContract.getDocumentId(root))
        val names = mutableSetOf<String>()
        resolver.query(children, arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null)?.use { cursor ->
            while (cursor.moveToNext()) cursor.getString(0)?.let(names::add)
        } ?: throw IOException("Cannot check destination filenames.")
        return names
    }

    fun delete(uri: Uri) { if (!DocumentsContract.deleteDocument(resolver, uri)) throw IOException("Cannot remove partial document.") }

    fun close() {
        if (closed) return
        closed = true
        if (ownedModes != 0) resolver.releasePersistableUriPermission(tree, ownedModes)
    }
}
