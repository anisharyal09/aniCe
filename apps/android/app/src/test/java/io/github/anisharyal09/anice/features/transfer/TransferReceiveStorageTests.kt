// SPDX-License-Identifier: GPL-3.0-or-later
// Probes receive publication: non-overwriting names, exclusivity, the copy fallback and partial retention.
package io.github.anisharyal09.anice.features.transfer

import java.io.File
import java.io.IOException
import java.nio.file.AccessDeniedException
import java.security.MessageDigest
import java.util.UUID
import kotlinx.coroutines.*
import io.github.anisharyal09.anice.infrastructure.session.SessionTiming
import kotlin.coroutines.CoroutineContext
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test

internal class QueuedTransferStorageDispatcher : CoroutineDispatcher() {
    private val queued = java.util.concurrent.ConcurrentLinkedQueue<Runnable>()
    val pending: Int get() = queued.size
    override fun dispatch(context: CoroutineContext, block: Runnable) { queued.add(block) }
    fun runNext() { checkNotNull(queued.poll()) { "No storage operation queued" }.run() }
}

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

    @Test fun injectedStorageLaneCannotBeBypassedAndCancelledWritesDoNotChangeBytes() = runBlocking {
        val lane = QueuedTransferStorageDispatcher()
        val folder = File(tempDir, "lane").apply { mkdirs() }
        val storage = TransferReceiveStorage(folder, null, ioDispatcher = lane)
        val events = mutableListOf<String>()
        val previous = SessionTiming.sink
        suspend fun <T> execute(action: suspend () -> T): T {
            val task = async(start = CoroutineStart.UNDISPATCHED) { action() }
            assertFalse("Storage escaped the injected lane", task.isCompleted)
            assertEquals(1, lane.pending)
            lane.runNext()
            return task.await()
        }
        try {
            SessionTiming.sink = { events.add(it) }
            val partial = execute { storage.create(UUID.randomUUID().toString(), UUID.randomUUID().toString()) }.first!!
            val cancelled = async(start = CoroutineStart.UNDISPATCHED) { storage.write(byteArrayOf(99)) }
            assertEquals(1, lane.pending)
            assertEquals(0L, partial.length())
            cancelled.cancel(); lane.runNext(); cancelled.join()
            assertTrue(cancelled.isCancelled)
            assertEquals(0L, partial.length())
            assertFalse(events.any { it.contains("event=storage_write ") })
            execute { storage.write(payload) }
            execute { storage.flush() }
            assertTrue(execute { storage.fileIdentity() }.isNotEmpty())
            assertArrayEquals(digest, execute { storage.prefixDigest(payload.size.toLong()) })
            assertArrayEquals(digest, execute { storage.finish("complete.bin", digest) })
            execute { storage.discard() }
            execute {
                try { storage.write(byteArrayOf(1)); fail("Closed storage accepted bytes") }
                catch (_: IOException) {}
            }
            assertArrayEquals(payload, File(folder, "complete.bin").readBytes())
            for (event in listOf("create", "write", "flush", "fileIdentity", "prefixDigest", "finish", "discard")) {
                assertTrue("Missing storage wait: $event", events.any { it.contains("event=storage_wait_$event ") })
                assertTrue("Missing storage duration: $event", events.any { it.contains("event=storage_$event ") })
            }
            assertEquals("Failed writes must retain their timing", 2, events.count { it.contains("event=storage_write ") })
            assertTrue(events.all { it.contains("owner=${System.identityHashCode(storage)} ") })
            assertFalse(events.any { it.contains(folder.path) })
        } finally {
            SessionTiming.sink = previous
            val cleanup = launch(NonCancellable, start = CoroutineStart.UNDISPATCHED) { storage.discard() }
            while (lane.pending > 0) lane.runNext()
            withTimeout(1000) { cleanup.join() }
        }
    }

    @Test fun restoringAndHashingRetainedBytesUseTheInjectedLane() = runBlocking {
        val lane = QueuedTransferStorageDispatcher()
        val batch = UUID.randomUUID().toString(); val file = UUID.randomUUID().toString()
        val partial = File(tempDir, ".anice-$batch-$file-${UUID.randomUUID()}.part").apply { writeBytes(payload) }
        val storage = TransferReceiveStorage(tempDir, null, ioDispatcher = lane)
        val restore = async(start = CoroutineStart.UNDISPATCHED) {
            storage.restore(batch, file, partial.path, "", 1024)
        }
        assertEquals(1, lane.pending)
        assertEquals(payload.size.toLong(), partial.length())
        lane.runNext(); restore.await()
        assertEquals(1024L, partial.length())
        val expected = MessageDigest.getInstance("SHA-256").digest(payload.copyOf(1024))
        val finish = async(start = CoroutineStart.UNDISPATCHED) { storage.finish("restored.bin", expected) }
        assertEquals(1, lane.pending); lane.runNext()
        assertArrayEquals(expected, finish.await())
        assertArrayEquals(payload.copyOf(1024), File(tempDir, "restored.bin").readBytes())
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
