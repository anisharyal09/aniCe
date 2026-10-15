// SPDX-License-Identifier: GPL-3.0-or-later
// Probes receive publication: non-overwriting names, exclusivity, the copy fallback and partial retention.
package io.github.anisharyal09.anice.features.transfer

import java.io.File
import java.io.IOException
import java.nio.file.AccessDeniedException
import java.security.MessageDigest
import java.util.UUID
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test

class TransferReceiveStorageTests {
    private lateinit var tempDir: File

    @Before fun setUp() {
        tempDir = File(System.getProperty("java.io.tmpdir"), "anice_publish_" + UUID.randomUUID())
        tempDir.mkdirs()
    }

    @After fun tearDown() { tempDir.deleteRecursively() }

    private val payload = ByteArray(4096) { (it % 251).toByte() }
    private val digest = MessageDigest.getInstance("SHA-256").digest(payload)

    private fun partials(folder: File): List<File> = folder.listFiles()!!.filter { it.name.endsWith(".part") }

    /** Renders [error]'s cause chain, so a failure reports the reason and not only the outermost type. */
    private fun chain(error: Throwable): String {
        val rendered = StringBuilder("${error.javaClass.name}: ${error.message}")
        var current = error.cause
        while (current != null) {
            rendered.append(" <- ${current.javaClass.name}: ${current.message}")
            current = current.cause
        }
        return rendered.toString()
    }

    /** Receives [payload] into the storage's folder, publishes it as [name] and returns its digest. */
    private suspend fun receive(storage: TransferReceiveStorage, name: String): ByteArray {
        storage.create(UUID.randomUUID().toString(), UUID.randomUUID().toString())
        storage.write(payload)
        return storage.finish(name, digest)
    }

    /**
     * Publishes [payload] as [name] and returns the typed failure. Only an [IOException] is caught, so
     * a failure raised anywhere inside this transfer still reaches the test rather than being absorbed
     * as if it were the expected refusal.
     */
    private suspend fun refusal(storage: TransferReceiveStorage, name: String): IOException =
        try {
            receive(storage, name)
            throw AssertionError("Publication must fail rather than report success")
        } catch (error: IOException) {
            error
        }

    @Test
    fun aTakenNameIsNeverOverwrittenAndTheTransferStillPublishes() = runBlocking {
        val folder = File(tempDir, "downloads").apply { mkdirs() }
        val existing = File(folder, "sample.bin").apply { writeBytes(byteArrayOf(9, 9, 9)) }
        assertArrayEquals(digest, receive(TransferReceiveStorage(folder, null), "sample.bin"))
        // Receiving a name that is already in use must not destroy the existing file, and must not
        // discard a transfer that has already been received and verified.
        assertArrayEquals(byteArrayOf(9, 9, 9), existing.readBytes())
        assertArrayEquals(payload, File(folder, "sample (1).bin").readBytes())
        assertEquals(2, folder.listFiles()!!.size)
        assertTrue(partials(folder).isEmpty())
    }

    @Test
    fun publicationWalksPastEveryTakenSuffix() = runBlocking {
        val folder = File(tempDir, "downloads").apply { mkdirs() }
        val taken = listOf("sample.bin", "sample (1).bin", "sample (2).bin")
        taken.forEach { File(folder, it).writeBytes(byteArrayOf(9)) }
        assertArrayEquals(digest, receive(TransferReceiveStorage(folder, null), "sample.bin"))
        assertArrayEquals(payload, File(folder, "sample (3).bin").readBytes())
        for (name in taken) assertArrayEquals(byteArrayOf(9), File(folder, name).readBytes())
    }

    @Test
    fun aDestinationWithoutHardLinksPublishesByCopying() = runBlocking {
        val folder = File(tempDir, "online-drive").apply { mkdirs() }
        val storage = TransferReceiveStorage(folder, null) { _, _ ->
            throw UnsupportedOperationException("This file system does not support hard links.")
        }
        assertArrayEquals(digest, receive(storage, "sample.bin"))
        assertArrayEquals(payload, File(folder, "sample.bin").readBytes())
        assertTrue("The staging partial must not survive publication", partials(folder).isEmpty())
    }

    @Test
    fun theCopyFallbackAlsoRefusesToOverwrite() = runBlocking {
        val folder = File(tempDir, "downloads").apply { mkdirs() }
        val existing = File(folder, "sample.bin").apply { writeBytes(byteArrayOf(9, 9, 9)) }
        val storage = TransferReceiveStorage(folder, null) { _, _ ->
            throw UnsupportedOperationException("This file system does not support hard links.")
        }
        assertArrayEquals(digest, receive(storage, "sample.bin"))
        assertArrayEquals(byteArrayOf(9, 9, 9), existing.readBytes())
        assertArrayEquals(payload, File(folder, "sample (1).bin").readBytes())
    }

    @Test
    fun aDestinationThatCannotPublishExclusivelyIsReportedAndKeepsTheVerifiedPartial() = runBlocking {
        val folder = File(tempDir, "downloads").apply { mkdirs() }
        val named = File(folder, "sample.bin")
        val storage = TransferReceiveStorage(folder, null) { target, _ -> throw AccessDeniedException(target.path) }
        val error = refusal(storage, "sample.bin")
        assertEquals("Destination cannot publish files exclusively", error.message)
        // The destination's own denial is carried rather than replaced, because that denial is what
        // names the file and the access problem. It can sit one or two levels down: coroutine stack
        // trace recovery, which is active in this JVM, hands back a copy of the failure whose cause
        // is the original, so the denial lies below that copy rather than being an immediate cause.
        val cause = (error.cause as? AccessDeniedException) ?: (error.cause?.cause as? AccessDeniedException)
        assertTrue("Expected the destination's denial, got ${chain(error)}", cause is AccessDeniedException)
        assertEquals(named.path, cause?.file)
        assertFalse(named.exists())
        // The digest was verified before publication, so the complete partial is retained for recovery.
        assertArrayEquals(payload, partials(folder).single().readBytes())
    }

    @Test
    fun aFailureInsideTheCopyFallbackIsNotSwallowed() = runBlocking {
        val folder = File(tempDir, "downloads").apply { mkdirs() }
        var links = 0
        val storage = TransferReceiveStorage(folder, null) { _, owned ->
            links++
            // The link is refused, and the staging partial vanishes before the copy can read it.
            assertTrue(owned.delete())
            throw UnsupportedOperationException("This file system does not support hard links.")
        }
        val error = refusal(storage, "sample.bin")
        assertEquals(1, links)
        assertEquals("Cannot publish the received file.", error.message)
        assertNotNull(error.cause)
        assertFalse(File(folder, "sample.bin").exists())
    }

    @Test
    fun aDigestMismatchPublishesNothing() = runBlocking {
        val folder = File(tempDir, "downloads").apply { mkdirs() }
        val storage = TransferReceiveStorage(folder, null)
        storage.create(UUID.randomUUID().toString(), UUID.randomUUID().toString())
        storage.write(payload)
        try {
            storage.finish("sample.bin", ByteArray(32))
            fail("A mismatching digest must not publish")
        } catch (error: IOException) {
            assertEquals("Hash mismatch", error.message)
        }
        assertFalse(File(folder, "sample.bin").exists())
        assertArrayEquals(payload, partials(folder).single().readBytes())
    }
}
