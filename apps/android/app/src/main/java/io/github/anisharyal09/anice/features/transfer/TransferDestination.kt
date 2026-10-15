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

internal class TransferDestination(private val context: Context, private val tree: Uri, modes: Int) {
    private val resolver = context.contentResolver
    private val flags = modes and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
    private val previousModes = resolver.persistedUriPermissions.firstOrNull { it.uri == tree }?.let {
        (if (it.isReadPermission) Intent.FLAG_GRANT_READ_URI_PERMISSION else 0) or
            (if (it.isWritePermission) Intent.FLAG_GRANT_WRITE_URI_PERMISSION else 0)
    } ?: 0
    private val ownedModes = flags and previousModes.inv()
    private val root = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
    private var closed = false

    init {
        require(flags == (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)) {
            "The folder must grant read and write access."
        }
        require(tree.authority in setOf("com.android.externalstorage.documents", "com.android.providers.downloads.documents")) {
            "Choose a folder from local device storage; this provider is not supported."
        }
        resolver.takePersistableUriPermission(tree, flags)
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

    fun finish(uri: Uri, name: String): Uri {
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, DocumentsContract.getDocumentId(root))
        resolver.query(children, arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null)?.use { cursor ->
            while (cursor.moveToNext()) if (cursor.getString(0) == name) throw IOException("A file named $name already exists. Choose another folder.")
        } ?: throw IOException("Cannot check destination filenames.")
        return DocumentsContract.renameDocument(resolver, uri, name)
            ?: throw IOException("Cannot finalize the received file. The provider refused renaming.")
    }

    fun delete(uri: Uri) { if (!DocumentsContract.deleteDocument(resolver, uri)) throw IOException("Cannot remove partial document.") }

    fun close() {
        if (closed) return
        closed = true
        if (ownedModes != 0) resolver.releasePersistableUriPermission(tree, ownedModes)
    }
}
