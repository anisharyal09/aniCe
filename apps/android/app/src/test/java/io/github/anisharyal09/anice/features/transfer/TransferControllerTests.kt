// SPDX-License-Identifier: GPL-3.0-or-later
// Verifies Android transfer controller lifecycle, cumulative flow control and adversarial chunk handling.
package io.github.anisharyal09.anice.features.transfer

import io.github.anisharyal09.anice.infrastructure.connections.ChannelDescriptor
import io.github.anisharyal09.anice.infrastructure.connections.SecuredChannel
import io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity
import io.github.anisharyal09.anice.infrastructure.session.Cbor
import io.github.anisharyal09.anice.infrastructure.session.SessionBackpressure
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import java.io.File
import java.security.MessageDigest
import java.util.UUID

class MockAndroidSecuredChannel(
    instance: String = "test-token",
    transport: String = "lan",
    deviceName: String = "MacBook Pro"
) : SecuredChannel {
    private val peer = DeviceIdentity(
        deviceId = "00000000-0000-4000-8000-000000000001",
        deviceName = deviceName,
        platform = "macos",
        publicKey = "mock-key",
        fingerprint = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    )
    override val descriptor = ChannelDescriptor(instance, transport, peer)
    val sentData = mutableListOf<ByteArray>()
    var onSendData: (suspend (ByteArray) -> Unit)? = null

    override suspend fun sendData(bytes: ByteArray) {
        sentData.add(bytes)
        onSendData?.invoke(bytes)
    }
}

class TransferControllerTests {
    private lateinit var tempDir: File

    @Before
    fun setUp() {
        tempDir = File(System.getProperty("java.io.tmpdir"), "anice_test_" + UUID.randomUUID())
        tempDir.mkdirs()
    }

    @After
    fun tearDown() {
        tempDir.deleteRecursively()
    }

    @Test
    fun testOfferAcceptStreamAndVerifyBatch() = runBlocking {
        val sender = TransferController(dispatcher = Dispatchers.Unconfined)
        val receiver = TransferController(dispatcher = Dispatchers.Unconfined)

        val senderChannel = MockAndroidSecuredChannel(deviceName = "Phone")
        val receiverChannel = MockAndroidSecuredChannel(deviceName = "MacBook")

        sender.available(senderChannel)
        receiver.available(receiverChannel)

        senderChannel.onSendData = { data ->
            receiver.handle(receiverChannel.descriptor, data)
        }
        receiverChannel.onSendData = { data ->
            sender.handle(senderChannel.descriptor, data)
        }

        // Create 10 KiB sample file
        val testFile = File(tempDir, "sample.bin")
        val testData = ByteArray(10240) { (it % 251).toByte() }
        testFile.writeBytes(testData)

        sender.sendFiles(listOf(testFile))

        for (i in 0 until 50) {
            if (receiver.state is TransferState.IncomingOffer) break
            delay(10)
        }

        val offerState = receiver.state as? TransferState.IncomingOffer
        assertNotNull("Expected IncomingOffer state on receiver", offerState)
        assertEquals(1, offerState!!.batch.files.size)
        assertEquals("sample.bin", offerState.batch.files[0].name)
        assertEquals(10240L, offerState.batch.files[0].size)

        val destFolder = File(tempDir, "downloads")
        destFolder.mkdirs()

        receiver.acceptIncomingOffer(destFolder)

        // Wait briefly for transfer job to finish
        var completed = false
        for (i in 0 until 50) {
            if (sender.state is TransferState.Completed && receiver.state is TransferState.Completed) {
                completed = true
                break
            }
            delay(20)
        }

        assertTrue("Transfer did not complete in time", completed)

        val receivedFile = File(destFolder, "sample.bin")
        assertTrue("Received file does not exist", receivedFile.exists())
        assertArrayEquals(testData, receivedFile.readBytes())

        val partFile = File(destFolder, "sample.bin.anice-part")
        assertFalse("Temporary part file was not removed", partFile.exists())
    }

    @Test
    fun testAdversarialHashMismatchFailsAndDeletesPartialFile() = runBlocking {
        val receiver = TransferController(dispatcher = Dispatchers.Unconfined)
        val receiverChannel = MockAndroidSecuredChannel(deviceName = "MacBook")
        receiver.available(receiverChannel)

        val batchId = UUID.randomUUID().toString()
        val fileId = UUID.randomUUID().toString()
        val correctHash = MessageDigest.getInstance("SHA-256").digest(byteArrayOf(1, 2, 3, 4))

        val offer = TransferMessage.offer(
            batch = batchId,
            sliceIndex = 0L,
            totalSlices = 1L,
            totalFiles = 1L,
            totalBytes = 4L,
            files = listOf(
                Cbor.Array(
                    listOf(
                        Cbor.Text(fileId),
                        Cbor.Text("corrupted.bin"),
                        Cbor.Integer(4L),
                        Cbor.Bytes(correctHash)
                    )
                )
            )
        )
        receiver.handle(receiverChannel.descriptor, offer.encode())

        val offerState = receiver.state as? TransferState.IncomingOffer
        assertNotNull(offerState)

        val destFolder = File(tempDir, "downloads")
        destFolder.mkdirs()
        receiver.acceptIncomingOffer(destFolder)

        // Corrupted chunk: [1, 2, 3, 99] instead of [1, 2, 3, 4]
        val corruptedChunk = TransferMessage.chunk(
            batch = batchId,
            file = fileId,
            offset = 0L,
            data = byteArrayOf(1, 2, 3, 99)
        )
        receiver.handle(receiverChannel.descriptor, corruptedChunk.encode())

        val failedState = receiver.state as? TransferState.Failed
        assertNotNull("Expected Failed state on corrupted chunk", failedState)
        assertTrue(failedState!!.reason.contains("Hash mismatch") || failedState.reason.contains("mismatch"))

        val targetFile = File(destFolder, "corrupted.bin")
        assertFalse("Corrupted file must not be committed", targetFile.exists())

        val partFile = File(destFolder, "corrupted.bin.anice-part")
        assertFalse("Part file must be deleted on mismatch", partFile.exists())
    }

    @Test
    fun testRejectOfferReturnsToIdle() = runBlocking {
        val receiver = TransferController(dispatcher = Dispatchers.Unconfined)
        val receiverChannel = MockAndroidSecuredChannel(deviceName = "MacBook")
        receiver.available(receiverChannel)

        val batchId = UUID.randomUUID().toString()
        val fileId = UUID.randomUUID().toString()

        val offer = TransferMessage.offer(
            batch = batchId,
            sliceIndex = 0L,
            totalSlices = 1L,
            totalFiles = 1L,
            totalBytes = 100L,
            files = listOf(
                Cbor.Array(
                    listOf(
                        Cbor.Text(fileId),
                        Cbor.Text("declined.bin"),
                        Cbor.Integer(100L),
                        Cbor.Bytes(ByteArray(32) { 0xaa.toByte() })
                    )
                )
            )
        )
        receiver.handle(receiverChannel.descriptor, offer.encode())
        assertTrue(receiver.state is TransferState.IncomingOffer)

        receiver.rejectIncomingOffer(reason = 0L)
        assertEquals(TransferState.Idle, receiver.state)
    }

    @Test
    fun testLocalCancellationCleansUp() = runBlocking {
        val receiver = TransferController(dispatcher = Dispatchers.Unconfined)
        val receiverChannel = MockAndroidSecuredChannel(deviceName = "MacBook")
        receiver.available(receiverChannel)

        val batchId = UUID.randomUUID().toString()
        val fileId = UUID.randomUUID().toString()

        val offer = TransferMessage.offer(
            batch = batchId,
            sliceIndex = 0L,
            totalSlices = 1L,
            totalFiles = 1L,
            totalBytes = 100L,
            files = listOf(
                Cbor.Array(
                    listOf(
                        Cbor.Text(fileId),
                        Cbor.Text("cancelled.bin"),
                        Cbor.Integer(100L),
                        Cbor.Bytes(ByteArray(32) { 0xaa.toByte() })
                    )
                )
            )
        )
        receiver.handle(receiverChannel.descriptor, offer.encode())

        val destFolder = File(tempDir, "downloads")
        destFolder.mkdirs()
        receiver.acceptIncomingOffer(destFolder)

        // Send partial chunk
        val chunk = TransferMessage.chunk(batch = batchId, file = fileId, offset = 0L, data = byteArrayOf(1, 2, 3))
        receiver.handle(receiverChannel.descriptor, chunk.encode())

        receiver.cancelTransfer(local = true)
        assertEquals(TransferState.Cancelled, receiver.state)

        val partFile = File(destFolder, "cancelled.bin.anice-part")
        assertFalse("Part file must be removed on cancel", partFile.exists())
    }

    @Test
    fun testCumulativeCreditFlowControlWindow() = runBlocking {
        val sender = TransferController(dispatcher = Dispatchers.Unconfined)
        val senderChannel = MockAndroidSecuredChannel(deviceName = "MacBook")
        sender.available(senderChannel)

        val totalSize = 250_000
        val testData = ByteArray(totalSize) { (it % 241).toByte() }
        val testFile = File(tempDir, "large.bin")
        testFile.writeBytes(testData)

        var sentChunkCount = 0
        var batchIdStr = ""
        var fileIdStr = ""

        senderChannel.onSendData = { data ->
            val msg = TransferMessage.decode(data)
            if (msg != null) {
                if (msg.kind == 2L) {
                    batchIdStr = msg.string(0)
                    val files = (msg.fields.getOrNull(5) as? Cbor.Array)?.value
                    val first = (files?.firstOrNull() as? Cbor.Array)?.value
                    fileIdStr = (first?.firstOrNull() as? Cbor.Text)?.value.orEmpty()
                } else if (msg.kind == 5L) {
                    sentChunkCount++
                }
            }
        }

        sender.sendFiles(listOf(testFile))
        for (i in 0 until 50) {
            if (batchIdStr.isNotEmpty()) break
            delay(10)
        }
        assertTrue(batchIdStr.isNotEmpty())

        // Peer accepts
        val acceptMsg = TransferMessage.accept(batch = batchIdStr, files = emptyList())
        sender.handle(senderChannel.descriptor, acceptMsg.encode())

        // Wait until sender pauses at 64 chunks (196,608 bytes)
        for (i in 0 until 50) {
            if (sentChunkCount >= 64) break
            delay(10)
        }

        assertEquals("Sender should pause at 64 chunks before ack", 64, sentChunkCount)

        // Peer sends ack for 64 chunks
        val ackMsg = TransferMessage.ack(batch = batchIdStr, file = fileIdStr, written = 64 * 3072L)
        sender.handle(senderChannel.descriptor, ackMsg.encode())

        // Sender resumes
        for (i in 0 until 50) {
            if (sentChunkCount > 64) break
            delay(10)
        }

        assertTrue("Sender should have resumed after ack", sentChunkCount > 64)

        // Complete the transfer
        val fileRes = TransferMessage.fileResult(
            batch = batchIdStr,
            file = fileIdStr,
            result = 0L,
            hash = MessageDigest.getInstance("SHA-256").digest(testData)
        )
        sender.handle(senderChannel.descriptor, fileRes.encode())
        val batchRes = TransferMessage.batchResult(batch = batchIdStr, result = 0L)
        sender.handle(senderChannel.descriptor, batchRes.encode())

        val completedState = sender.state as? TransferState.Completed
        assertNotNull(completedState)
        assertEquals(batchIdStr, completedState!!.batchId)
        assertEquals(1, completedState.fileCount)
        assertEquals(totalSize.toLong(), completedState.totalBytes)
    }

    @Test
    fun testMultiWindowTransferWithBackpressure() = runBlocking {
        val sender = TransferController(dispatcher = Dispatchers.Unconfined)
        val receiver = TransferController(dispatcher = Dispatchers.Unconfined)

        val senderChannel = MockAndroidSecuredChannel(deviceName = "Phone")
        val receiverChannel = MockAndroidSecuredChannel(deviceName = "MacBook")

        sender.available(senderChannel)
        receiver.available(receiverChannel)

        var senderAttempts = 0
        senderChannel.onSendData = { data ->
            senderAttempts++
            if (senderAttempts % 17 == 3) {
                CoroutineScope(Dispatchers.Default).launch {
                    delay(5)
                    sender.capacityAvailable(senderChannel.descriptor)
                }
                throw SessionBackpressure()
            }
            receiver.handle(receiverChannel.descriptor, data)
        }

        var receiverAttempts = 0
        receiverChannel.onSendData = { data ->
            receiverAttempts++
            if (receiverAttempts % 5 == 2) {
                CoroutineScope(Dispatchers.Default).launch {
                    delay(5)
                    receiver.capacityAvailable(receiverChannel.descriptor)
                }
                throw SessionBackpressure()
            }
            sender.handle(senderChannel.descriptor, data)
        }

        val totalSize = 307_200 // 100 chunks of 3072 bytes (exceeds 64 chunk limit)
        val testData = ByteArray(totalSize) { (it % 251).toByte() }
        val testFile = File(tempDir, "multiwindow.bin")
        testFile.writeBytes(testData)

        sender.sendFiles(listOf(testFile))

        for (i in 0 until 100) {
            if (receiver.state is TransferState.IncomingOffer) break
            delay(10)
        }

        val offerState = receiver.state as? TransferState.IncomingOffer
        assertNotNull("Expected IncomingOffer state on receiver", offerState)
        assertEquals(totalSize.toLong(), offerState!!.batch.totalBytes)

        val destFolder = File(tempDir, "downloads")
        destFolder.mkdirs()

        receiver.acceptIncomingOffer(destFolder)

        var completed = false
        for (i in 0 until 200) {
            if (sender.state is TransferState.Completed && receiver.state is TransferState.Completed) {
                completed = true
                break
            }
            delay(20)
        }

        assertTrue("Transfer did not complete across sliding window: sender=${sender.state}, receiver=${receiver.state}", completed)

        val receivedFile = File(destFolder, "multiwindow.bin")
        assertTrue(receivedFile.exists())
        assertArrayEquals(testData, receivedFile.readBytes())
    }
}
