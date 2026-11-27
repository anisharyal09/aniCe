// SPDX-License-Identifier: GPL-3.0-or-later
// Verifies pending Downloads publication and non-overwriting receive names on Android storage.
package io.github.anisharyal09.anice.features.transfer

import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Environment
import android.os.ParcelFileDescriptor
import android.provider.MediaStore
import androidx.test.core.app.ApplicationProvider
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.security.MessageDigest
import java.util.UUID

class MediaStoreReceiveDestinationTest {
    @Test fun publishesResumedJpegInDownloadsAndImagesWithoutChangingBytes(): Unit = runBlocking {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val resolver = context.contentResolver
        val name = "aniCe-photo-${UUID.randomUUID()}.JPG"
        val bitmap = Bitmap.createBitmap(32, 32, Bitmap.Config.ARGB_8888)
        val payload = ByteArrayOutputStream().use {
            check(bitmap.compress(Bitmap.CompressFormat.JPEG, 90, it))
            it.toByteArray()
        }
        bitmap.recycle()
        val file = TransferFile(UUID.randomUUID().toString(), name, payload.size.toLong(),
            MessageDigest.getInstance("SHA-256").digest(payload))
        val batch = UUID.randomUUID().toString()
        val destination = MediaStoreTransferDestination(context)
        val uri = destination.create(".anice-$batch-${file.id}-${UUID.randomUUID()}.part")
        val storage = TransferReceiveStorage(context.filesDir, destination, Dispatchers.IO)
        try {
            val offset = payload.size / 2
            ParcelFileDescriptor.AutoCloseOutputStream(destination.descriptor(uri)).use {
                it.write(payload, 0, offset)
                it.write(byteArrayOf(0, 0)) // Uncheckpointed bytes left by the previous process.
            }
            storage.restore(batch, file.id, "", uri.toString(), offset.toLong())
            storage.write(payload.copyOfRange(offset, payload.size))
            storage.finish(file)

            val saved = destination.read(uri).use { it.readBytes() }
            assertArrayEquals(payload, saved)
            val decoded = BitmapFactory.decodeByteArray(saved, 0, saved.size)
            assertNotNull(decoded)
            decoded?.recycle()
            assertEquals("image/jpeg", resolver.getType(uri))
            assertTrue("The published filename should retain its JPEG extension", destination.isPublished(uri, file))
            val image = MediaStore.Images.Media.getContentUri(
                MediaStore.getVolumeName(uri), ContentUris.parseId(uri)
            )
            val indexed = resolver.query(image, arrayOf(MediaStore.MediaColumns.DISPLAY_NAME), null, null, null)?.use {
                it.moveToFirst() && it.getString(0) == name
            }
            assertTrue("The JPEG should be indexed in Android's Images collection", indexed == true)
        } finally {
            storage.discard()
            resolver.delete(uri, null, null)
        }
    }

    @Test fun changedBytesInPendingStorageAreNeverPublished(): Unit = runBlocking {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val destination = MediaStoreTransferDestination(context)
        val payload = byteArrayOf(1, 2, 3, 4)
        val file = TransferFile(UUID.randomUUID().toString(), "changed.jpg", payload.size.toLong(),
            MessageDigest.getInstance("SHA-256").digest(payload))
        val batch = UUID.randomUUID().toString()
        val storage = TransferReceiveStorage(context.filesDir, destination, Dispatchers.IO)
        val uri = checkNotNull(storage.create(batch, file.id).second)
        try {
            storage.write(payload)
            storage.flush()
            ParcelFileDescriptor.AutoCloseOutputStream(destination.descriptor(uri)).use { it.write(0) }
            try {
                storage.finish(file)
                throw AssertionError("Finalization must reject modified on-disk bytes")
            } catch (error: IOException) {
                assertEquals("The saved data does not match the transfer. Send the original file again.", error.message)
            }
            assertTrue("Only the pending copy should exist", destination.ownsPartial(uri, ".anice-$batch-${file.id}-"))
            assertFalse(storage.hasVerifiedPartial())
        } finally {
            storage.discard()
            destination.delete(uri)
        }
    }

    @Test fun publishesVerifiedBytesAfterPendingAndPreservesExistingNames(): Unit = runBlocking {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val resolver = context.contentResolver
        val name = "aniCe-phase2-${UUID.randomUUID()}.txt"
        val existing = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, name)
            put(MediaStore.MediaColumns.MIME_TYPE, "text/plain")
            put(MediaStore.MediaColumns.RELATIVE_PATH, "${Environment.DIRECTORY_DOWNLOADS}/aniCe/")
            put(MediaStore.MediaColumns.IS_PENDING, 0)
        }) ?: throw AssertionError("Could not prepare a filename collision")
        val payload = "verified transfer".toByteArray()
        val file = TransferFile(UUID.randomUUID().toString(), name, payload.size.toLong(),
            MessageDigest.getInstance("SHA-256").digest(payload))
        val destination = MediaStoreTransferDestination(context)
        val storage = TransferReceiveStorage(context.filesDir, destination, Dispatchers.IO)
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
            storage.finish(file)

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
