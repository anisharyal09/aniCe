// SPDX-License-Identifier: GPL-3.0-or-later
// Verifies pending Downloads publication and non-overwriting receive names on Android storage.
package io.github.anisharyal09.anice.features.transfer

import android.content.ContentValues
import android.content.Context
import android.provider.MediaStore
import androidx.test.core.app.ApplicationProvider
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.security.MessageDigest
import java.util.UUID

class MediaStoreReceiveDestinationTest {
    @Test fun publishesVerifiedBytesAfterPendingAndPreservesExistingNames() = runBlocking {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val resolver = context.contentResolver
        val name = "aniCe-phase2-${UUID.randomUUID()}.txt"
        val existing = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, name)
            put(MediaStore.MediaColumns.MIME_TYPE, "text/plain")
            put(MediaStore.MediaColumns.RELATIVE_PATH, "${android.os.Environment.DIRECTORY_DOWNLOADS}/aniCe/")
            put(MediaStore.MediaColumns.IS_PENDING, 0)
        }) ?: throw AssertionError("Could not prepare a filename collision")
        val payload = "verified transfer".toByteArray()
        val file = TransferFile(UUID.randomUUID().toString(), name, payload.size.toLong(),
            MessageDigest.getInstance("SHA-256").digest(payload))
        val destination = MediaStoreTransferDestination(context)
        val storage = TransferReceiveStorage(File(context.filesDir, "unused-destination"), destination, Dispatchers.IO)
        var partial: android.net.Uri? = null
        try {
            destination.preflight(payload.size.toLong())
            partial = storage.create(UUID.randomUUID().toString(), file.id).second
                ?: throw AssertionError("MediaStore did not return a pending row")
            val pending = resolver.query(partial, arrayOf(MediaStore.MediaColumns.IS_PENDING), null, null, null)?.use {
                it.moveToFirst() && it.getInt(0) == 1
            } == true
            assertTrue("The incomplete file must remain pending", pending)

            storage.write(payload)
            storage.finish(file.name, file.sha256)

            val visibleName = resolver.query(partial, arrayOf(MediaStore.MediaColumns.DISPLAY_NAME,
                MediaStore.MediaColumns.IS_PENDING), null, null, null)?.use {
                if (it.moveToFirst()) it.getString(0) to it.getInt(1) else null
            }
            assertNotEquals(existing, partial)
            assertEquals(TransferNaming.suffixed(name, 1), visibleName?.first)
            assertEquals(0, visibleName?.second)
            assertTrue(destination.isPublished(partial, file))
        } finally {
            storage.discard()
            partial?.let { runCatching { resolver.delete(it, null, null) } }
            resolver.delete(existing, null, null)
            destination.close()
        }
    }
}
