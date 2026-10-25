// SPDX-License-Identifier: GPL-3.0-or-later
// Exercises checkpoint corruption, restart recovery, expiry and owned-partial isolation.
package io.github.anisharyal09.anice.features.transfer

import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.security.MessageDigest
import java.util.UUID

class TransferRecoveryTests {
    private val local = "a".repeat(64)
    private fun snapshot(folder: File, expires: Long = System.currentTimeMillis() + 60_000): TransferCheckpoint {
        val batchId = UUID.randomUUID().toString(); val fileId = UUID.randomUUID().toString()
        val file = TransferFile(fileId, "received.bin", 4, MessageDigest.getInstance("SHA-256").digest(ByteArray(4)))
        val part = File(folder, ".anice-$batchId-$fileId-${UUID.randomUUID()}.part").apply { writeBytes(ByteArray(3)) }
        val peer = MockAndroidSecuredChannel().descriptor.peer
        return TransferCheckpoint(local, peer.deviceId, peer.fingerprint,
            TransferBatch(batchId, listOf(file), 4, "Mac"), true, 0, 1, folder.absolutePath,
            "", part.absolutePath, "", "lan", expires)
    }

    @Test fun restartedReceiverVerifiesAndContinuesOnlyItsCheckpointedPrefix() = runBlocking {
        val folder = Files.createTempDirectory("anice-recovery-").toFile()
        val journal = File(folder, "private/checkpoint")
        val saved = snapshot(folder)
        TransferRecoveryStore(journal).save(saved)
        val owner = TransferController(dispatcher = Dispatchers.Unconfined, recoveryFile = journal, recoveryIdentity = { local })
        try {
            withTimeout(2000) { while (owner.state !is TransferState.Paused) delay(5) }
            assertEquals(1L, File(saved.partial).length())
            val wrong = MockAndroidSecuredChannel(peerOverride = MockAndroidSecuredChannel().descriptor.peer.copy(fingerprint = "b".repeat(64)))
            owner.available(wrong)
            assertNull(owner.activeChannel)
            val channel = MockAndroidSecuredChannel(instance = "fresh")
            owner.available(channel)
            owner.handle(channel.descriptor, TransferMessage.capability().encode())
            val file = saved.batch.files.single()
            owner.handle(channel.descriptor, TransferMessage.resume(saved.batch.id, file.id, 1,
                MessageDigest.getInstance("SHA-256").digest(byteArrayOf(0))).encode())
            owner.handle(channel.descriptor, TransferMessage.chunk(saved.batch.id, file.id, 1, ByteArray(3)).encode())
            withTimeout(2000) { while (owner.state !is TransferState.Completed || TransferRecoveryStore(journal).load()?.stage != 3) delay(5) }
            assertArrayEquals(ByteArray(4), File(folder, "received.bin").readBytes())
            assertFalse(File(saved.partial).exists())
        } finally { owner.dismiss(); folder.deleteRecursively() }
    }

    @Test fun expiredCheckpointDeletesOnlyItsOwnPartial() = runBlocking {
        val folder = Files.createTempDirectory("anice-expired-").toFile()
        val saved = snapshot(folder, System.currentTimeMillis() - 1)
        val unrelated = File(folder, ".anice-unrelated.part").apply { writeText("keep") }
        val journal = File(folder, "private/checkpoint")
        TransferRecoveryStore(journal).save(saved)
        val owner = TransferController(dispatcher = Dispatchers.Unconfined, recoveryFile = journal, recoveryIdentity = { local })
        try {
            withTimeout(2000) { while (owner.state !is TransferState.Failed) delay(5) }
            assertFalse(File(saved.partial).exists())
            assertEquals("keep", unrelated.readText())
            assertFalse(journal.exists())
        } finally { owner.dismiss(); folder.deleteRecursively() }
    }

    @Test fun malformedCheckpointsAndFailedReplacementPreserveTheSavedJob() {
        val folder = Files.createTempDirectory("anice-journal-").toFile()
        try {
            val saved = snapshot(folder)
            val bytes = TransferRecoveryStore.encode(saved)
            val decoded = TransferRecoveryStore.decode(bytes)
            assertEquals(saved, decoded)
            for (bad in listOf(bytes.copyOf(3), bytes + 0, ByteArray(1_048_577))) {
                try { TransferRecoveryStore.decode(bad); fail("Accepted malformed checkpoint") }
                catch (_: IOException) {}
            }
            val store = TransferRecoveryStore(File(folder, "checkpoint"))
            store.save(saved)
            try { store.save(saved.copy(offset = 5)); fail("Accepted offset past EOF") }
            catch (_: IllegalArgumentException) {}
            assertEquals(saved, store.load())
            val fault = TransferRecoveryStore(File(folder, "checkpoint")) { _, _ -> throw IOException("Injected rename failure") }
            try { fault.save(saved.copy(offset = 2)); fail("Ignored failed checkpoint replacement") }
            catch (_: IOException) {}
            assertEquals(saved, store.load())
            assertTrue(File(saved.partial).exists())
        } finally { folder.deleteRecursively() }
    }

    @Test fun publishedFileSurvivesCrashBeforeItsReceiptWithoutDuplicatePublication() = runBlocking {
        val folder = Files.createTempDirectory("anice-publication-").toFile()
        val base = snapshot(folder)
        val part = File(base.partial).apply { writeBytes(ByteArray(4)) }
        val key = Files.readAttributes(part.toPath(), java.nio.file.attribute.BasicFileAttributes::class.java).fileKey().toString()
        val target = File(folder, "received.bin")
        Files.createLink(target.toPath(), part.toPath()); Files.delete(part.toPath())
        val saved = base.copy(stage = 4, offset = 4, fileIdentity = key)
        val journal = File(folder, "private/checkpoint")
        TransferRecoveryStore(journal).save(saved)
        val owner = TransferController(dispatcher = Dispatchers.Unconfined, recoveryFile = journal, recoveryIdentity = { local })
        try {
            withTimeout(2000) { while (owner.state !is TransferState.Completed) delay(5) }
            assertEquals(3, TransferRecoveryStore(journal).load()!!.stage)
            assertEquals(listOf("received.bin"), folder.listFiles()!!.filter { it.isFile }.map { it.name })
            val channel = MockAndroidSecuredChannel()
            owner.available(channel)
            val file = saved.batch.files.single()
            owner.handle(channel.descriptor, TransferMessage.resume(saved.batch.id, file.id, 4, file.sha256).encode())
            assertTrue(channel.sentData.mapNotNull { TransferMessage.decode(it) }.any { it.kind == 7L && it.number(2) == 0L })
            assertArrayEquals(ByteArray(4), target.readBytes())
        } finally { owner.dismiss(); folder.deleteRecursively() }
    }

    @Test fun expiryUnlinksAPartialWithoutTruncatingItsPublishedHardLink() = runBlocking {
        val folder = Files.createTempDirectory("anice-expired-link-").toFile()
        val saved = snapshot(folder, System.currentTimeMillis() - 1).copy(stage = 4, offset = 4)
        File(saved.partial).writeBytes(ByteArray(4))
        val target = File(folder, "received.bin")
        Files.createLink(target.toPath(), File(saved.partial).toPath())
        val journal = File(folder, "private/checkpoint")
        TransferRecoveryStore(journal).save(saved)
        val owner = TransferController(dispatcher = Dispatchers.Unconfined, recoveryFile = journal, recoveryIdentity = { local })
        try {
            withTimeout(2000) { while (owner.state !is TransferState.Failed) delay(5) }
            assertArrayEquals(ByteArray(4), target.readBytes())
            assertFalse(File(saved.partial).exists())
        } finally { owner.dismiss(); folder.deleteRecursively() }
    }

    @Test fun unansweredAndBusyResumeStayPendingAndANewChannelCanFinish() = runBlocking {
        val folder = Files.createTempDirectory("anice-resume-").toFile()
        val base = snapshot(folder)
        val source = File(folder, "source.bin").apply { writeBytes(ByteArray(4)) }
        val saved = base.copy(receiving = false, folder = "", partial = "", offset = 0,
            batch = base.batch.copy(files = listOf(base.batch.files.single().copy(sourceFile = source))))
        val journal = File(folder, "private/checkpoint")
        TransferRecoveryStore(journal).save(saved)
        val owner = TransferController(dispatcher = Dispatchers.Unconfined, recoveryFile = journal,
            recoveryIdentity = { local }, resumeTimeoutMillis = 25)
        try {
            withTimeout(2000) { while (owner.state !is TransferState.Paused) delay(5) }
            repeat(3) { attempt ->
                val channel = MockAndroidSecuredChannel(instance = "attempt-$attempt")
                channel.onSendData = { bytes ->
                    val message = TransferMessage.decode(bytes)!!
                    if (message.kind == 10L && attempt > 0) owner.handle(channel.descriptor,
                        TransferMessage.status(saved.batch.id, saved.batch.files.single().id, 0, if (attempt == 1) 3 else 0).encode())
                    if (message.kind == 5L && attempt == 2) owner.handle(channel.descriptor,
                        TransferMessage.fileResult(saved.batch.id, saved.batch.files.single().id, 0,
                            saved.batch.files.single().sha256).encode())
                }
                owner.available(channel); owner.handle(channel.descriptor, TransferMessage.capability().encode())
                withTimeout(2000) { while (channel.sentData.none { TransferMessage.decode(it)?.kind == 10L }) delay(5) }
                if (attempt < 2) {
                    delay(70)
                    assertTrue("Transient resume attempt $attempt discarded work", owner.state is TransferState.Paused)
                    owner.retired(channel.descriptor)
                }
            }
            withTimeout(2000) { while (owner.state !is TransferState.Completed) delay(5) }
        } finally { owner.dismiss(); folder.deleteRecursively() }
    }

    @Test fun restoredOfferRequiresApprovalAndKeepsItsBatchIdentity() = runBlocking {
        val folder = Files.createTempDirectory("anice-offer-").toFile()
        try {
            for (stage in listOf(1, 2)) {
                val base = snapshot(folder)
                val saved = base.copy(stage = stage, receiving = stage == 2, offset = 0, folder = "", partial = "")
                val journal = File(folder, "private/checkpoint-$stage")
                TransferRecoveryStore(journal).save(saved)
                val owner = TransferController(dispatcher = Dispatchers.Unconfined, recoveryFile = journal, recoveryIdentity = { local })
                try {
                    withTimeout(2000) { while (owner.state !is TransferState.Paused) delay(5) }
                    val channel = MockAndroidSecuredChannel()
                    owner.available(channel); owner.handle(channel.descriptor, TransferMessage.capability().encode())
                    if (stage == 1) {
                        assertEquals(saved.batch.id, (owner.state as TransferState.WaitingForPeerApproval).batch.id)
                        withTimeout(2000) { while (channel.sentData.none { TransferMessage.decode(it)?.kind == 2L }) delay(5) }
                    } else assertEquals(saved.batch.id, (owner.state as TransferState.IncomingOffer).batch.id)
                    assertFalse(channel.sentData.any { TransferMessage.decode(it)?.kind == 3L })
                } finally { owner.dismiss() }
            }
        } finally { folder.deleteRecursively() }
    }

    @Test fun bothRestartedOwnersRecoverALostApprovalAndAllPublishedFileReceipts() = runBlocking {
        val folder = Files.createTempDirectory("anice-two-restarts-").toFile()
        val base = snapshot(folder)
        val files = listOf(0, 4, 0).mapIndexed { index, length ->
            val source = File(folder, "source-$index.bin").apply { writeBytes(ByteArray(length)) }
            TransferFile(UUID.randomUUID().toString(), source.name, length.toLong(),
                MessageDigest.getInstance("SHA-256").digest(ByteArray(length)), sourceFile = source)
        }
        val batch = base.batch.copy(files = files, totalBytes = 4)
        val sourceJournal = File(folder, "sender/checkpoint")
        val receiverJournal = File(folder, "receiver/checkpoint")
        TransferRecoveryStore(sourceJournal).save(base.copy(batch = batch, receiving = false, index = 0, offset = 0,
            folder = "", partial = "", stage = 1))
        TransferRecoveryStore(receiverJournal).save(base.copy(batch = batch.copy(files = files.map { it.copy(sourceFile = null) }),
            receiving = true, index = 2, offset = 0, folder = "", partial = "", stage = 3))
        // Restore both owners on one serial dispatcher; Unconfined resumes them on competing IO threads.
        val dispatcher = coroutineContext[kotlin.coroutines.ContinuationInterceptor] as kotlinx.coroutines.CoroutineDispatcher
        val sender = TransferController(dispatcher = dispatcher, recoveryFile = sourceJournal, recoveryIdentity = { local })
        val receiver = TransferController(dispatcher = dispatcher, recoveryFile = receiverJournal, recoveryIdentity = { local })
        try {
            withTimeout(2000) { while (sender.state !is TransferState.Paused || receiver.state !is TransferState.Completed) delay(5) }
            val outgoing = MockAndroidSecuredChannel(instance = "sender-new")
            val incoming = MockAndroidSecuredChannel(instance = "receiver-new")
            outgoing.onSendData = { receiver.handle(incoming.descriptor, it) }
            incoming.onSendData = { sender.handle(outgoing.descriptor, it) }
            sender.available(outgoing); receiver.available(incoming)
            sender.handle(outgoing.descriptor, TransferMessage.capability().encode())
            receiver.handle(incoming.descriptor, TransferMessage.capability().encode())
            try { withTimeout(4000) { while (sender.state !is TransferState.Completed) delay(5) } }
            catch (_: TimeoutCancellationException) {
                val current = sender.state
                val position = if (current is TransferState.Transferring) "file ${current.fileIndex}: ${current.fileBytes}/${current.fileSize}" else current.javaClass.simpleName
                fail("Restart stalled at $position; sent=${outgoing.sentData.mapNotNull { TransferMessage.decode(it) }.map { it.kind }}; replies=${incoming.sentData.mapNotNull { TransferMessage.decode(it) }.map { it.kind }}")
            }
            assertEquals(3, (sender.state as TransferState.Completed).fileCount)
            assertFalse("Already published files were retransmitted", outgoing.sentData.any { TransferMessage.decode(it)?.kind == 5L })
            assertTrue(receiver.state is TransferState.Completed)
        } finally { sender.dismiss(); receiver.dismiss(); folder.deleteRecursively() }
    }
}
