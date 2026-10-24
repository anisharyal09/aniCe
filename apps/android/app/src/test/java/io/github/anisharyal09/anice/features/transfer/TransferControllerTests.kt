// SPDX-License-Identifier: GPL-3.0-or-later
// Verifies Android transfer controller lifecycle, cumulative flow control and adversarial chunk handling.
package io.github.anisharyal09.anice.features.transfer

import io.github.anisharyal09.anice.infrastructure.connections.ChannelDescriptor
import io.github.anisharyal09.anice.infrastructure.connections.SecuredChannel
import io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity
import io.github.anisharyal09.anice.infrastructure.session.Cbor
import io.github.anisharyal09.anice.infrastructure.session.SessionBackpressure
import io.github.anisharyal09.anice.infrastructure.session.SessionDataAdmission
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
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
    deviceName: String = "MacBook Pro",
    maximumDataBytes: Int = 4000,
    peerOverride: DeviceIdentity? = null
) : SecuredChannel {
    private val peer = peerOverride ?: DeviceIdentity(
        deviceId = "00000000-0000-4000-8000-000000000001",
        deviceName = deviceName,
        platform = "macos",
        publicKey = "mock-key",
        fingerprint = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    )
    override val descriptor = ChannelDescriptor(instance, transport, peer, maximumDataBytes)
    val sentData = java.util.concurrent.CopyOnWriteArrayList<ByteArray>()
    var onSendData: (suspend (ByteArray) -> Unit)? = null

    override suspend fun sendData(bytes: ByteArray) {
        sentData.add(bytes)
        onSendData?.invoke(bytes)
    }
}

class TransferControllerTests {
    @Test fun lateConfirmationStaysPendingWithoutCapacitySpinOrExtendingExpiry() = runBlocking {
        val now = java.util.concurrent.atomic.AtomicLong(0)
        val owner = TransferController(dispatcher = Dispatchers.Unconfined, clock = { now.get() },
            pauseTimeoutMillis = 2500, resumeTimeoutMillis = 25, confirmationTimeoutMillis = 25)
        val channel = MockAndroidSecuredChannel()
        owner.available(channel)
        try {
            owner.handle(channel.descriptor, TransferMessage.capability().encode())
            val source = File(tempDir, "late.bin").apply { writeBytes(ByteArray(4)) }
            owner.sendFiles(listOf(source))
            withTimeout(2000) { while (owner.state !is TransferState.WaitingForPeerApproval) delay(5) }
            val batch = (owner.state as TransferState.WaitingForPeerApproval).batch
            channel.onSendData = { bytes ->
                if (TransferMessage.decode(bytes)?.kind == 10L) owner.handle(channel.descriptor,
                    TransferMessage.status(batch.id, batch.files.single().id, 0, 3).encode())
            }
            owner.handle(channel.descriptor, TransferMessage.accept(batch.id, emptyList()).encode())
            fun resumes() = channel.sentData.count { TransferMessage.decode(it)?.kind == 10L }
            withTimeout(2000) { while (owner.state !is TransferState.Paused || resumes() < 1) delay(5) }
            delay(30)
            repeat(100) { owner.capacityAvailable(channel.descriptor) }
            assertEquals(1, resumes())
            now.set(2001)
            owner.capacityAvailable(channel.descriptor)
            withTimeout(2000) { while (resumes() < 2) delay(5) }
            assertTrue(owner.state is TransferState.Paused)
            now.set(2501)
            owner.capacityAvailable(channel.descriptor)
            assertTrue("Retries extended the original expiry", owner.state is TransferState.Failed)
            assertTrue(source.exists())
        } finally { owner.dismiss() }
    }
    @Test fun bleCreditLeavesRoomForControlsInTheEightMessageIngressQueue() = runBlocking {
        val owner = TransferController(dispatcher = Dispatchers.Unconfined)
        val channel = MockAndroidSecuredChannel(transport = "ble")
        owner.available(channel)
        try {
            withTimeout(2000) { while (channel.sentData.isEmpty()) delay(5) }
            assertEquals(4L, TransferMessage.decode(channel.sentData.first())!!.number(2))
            owner.handle(channel.descriptor, TransferMessage.capability().encode())
            val source = File(tempDir, "window.bin").apply { writeBytes(ByteArray(20000)) }
            owner.sendFiles(listOf(source))
            withTimeout(2000) { while (owner.state !is TransferState.WaitingForPeerApproval) delay(5) }
            val batch = (owner.state as TransferState.WaitingForPeerApproval).batch
            owner.handle(channel.descriptor, TransferMessage.accept(batch.id, emptyList()).encode())
            fun chunks() = channel.sentData.mapNotNull { TransferMessage.decode(it) }.filter { it.kind == 5L }
            withTimeout(2000) { while (chunks().size < 4) delay(5) }
            delay(30)
            assertEquals("BLE exceeded its credit before an ACK", 4, chunks().size)
            owner.handle(channel.descriptor, TransferMessage.ack(batch.id, batch.files.single().id, 12288).encode())
            withTimeout(2000) { while (chunks().size < 7) delay(5) }
            owner.handle(channel.descriptor, TransferMessage.fileResult(batch.id, batch.files.single().id, 0, batch.files.single().sha256).encode())
            withTimeout(2000) { while (owner.state !is TransferState.Completed) delay(5) }
        } finally { owner.dismiss() }
    }
    @Test fun largeChunksRequireExplicitLanBudgetAndCapability() = runBlocking {
        val owner = TransferController(dispatcher = Dispatchers.Unconfined)
        val batch = UUID.randomUUID().toString()
        val file = UUID.randomUUID().toString()
        val message = TransferMessage.chunk(batch, file, 0, ByteArray(131072) { (it % 251).toByte() })
        try { message.encode(); fail("BLE-sized encoder accepted large chunk") } catch (_: TransferWireException) {}
        val encoded = message.encode(131072)
        assertNull(io.github.anisharyal09.anice.infrastructure.session.SessionControl.application(encoded, 262144))
        assertEquals(131072, TransferMessage.decode(encoded, 131072)!!.bytes(3).size)
        try { TransferMessage.decode(encoded); fail("Standard decoder accepted large chunk") } catch (_: TransferWireException) {}
        try { TransferMessage.chunk(batch, file, 0, ByteArray(131073)).encode(131072); fail("Oversized chunk accepted") } catch (_: TransferWireException) {}
        val capability = TransferMessage.capability(2, 131072, 8).encode(131072)
        try { TransferMessage.decode(capability); fail("BLE accepted LAN capability") } catch (_: TransferWireException) {}
        val channel = MockAndroidSecuredChannel(maximumDataBytes = 262144)
        owner.available(channel)
        delay(30)
        assertEquals(2, TransferMessage.decode(channel.sentData.first(), 131072)!!.number(0).toInt())
        assertEquals(3, TransferMessage.decode(channel.sentData.last(), 262016)!!.number(0).toInt())
        owner.retired(channel.descriptor)
        val ble = MockAndroidSecuredChannel(transport = "ble")
        owner.available(ble)
        delay(30)
        assertEquals(1, TransferMessage.decode(ble.sentData.first())!!.number(0).toInt())
    }

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

    @Test fun lanWinsEitherConnectionOrderAndFallsBackOnlyOnItsRetirement() = runBlocking {
        for (lanFirst in listOf(false, true)) {
            val owner = TransferController(dispatcher = Dispatchers.Unconfined)
            val lan = MockAndroidSecuredChannel(instance = "lan", transport = "lan")
            val ble = MockAndroidSecuredChannel(instance = "ble", transport = "ble")
            val ordered = if (lanFirst) listOf(lan, ble) else listOf(ble, lan)
            ordered.forEach { owner.available(it); owner.handle(it.descriptor, TransferMessage.capability().encode()) }
            assertSame(lan, owner.activeChannel)
            assertTrue(owner.peerCompatible)
            assertEquals(io.github.anisharyal09.anice.infrastructure.connections.DataHandling.DISCARDED,
                owner.handle(ble.descriptor, TransferMessage.cancel(UUID.randomUUID().toString(), "", 0).encode()))
            owner.retired(lan.descriptor.copy(instance = "stale"))
            assertSame(lan, owner.activeChannel)
            owner.retired(lan.descriptor)
            assertSame(ble, owner.activeChannel)
            assertTrue(owner.peerCompatible)
            owner.retired(ble.descriptor)
            assertFalse(owner.peerConnected)
            assertFalse(owner.peerCompatible)
        }
    }

    @Test fun capabilityDoesNotLeakAcrossChannelsOrSessionReplacement() = runBlocking {
        val owner = TransferController(dispatcher = Dispatchers.Unconfined)
        val ble = MockAndroidSecuredChannel(instance = "ble", transport = "ble")
        val lan = MockAndroidSecuredChannel(instance = "lan")
        owner.available(ble)
        owner.handle(ble.descriptor, TransferMessage.capability().encode())
        owner.available(lan)
        assertSame(ble, owner.activeChannel)
        assertTrue(owner.peerCompatible)
        owner.retired(ble.descriptor)
        assertSame(lan, owner.activeChannel)
        assertFalse(owner.peerCompatible)
        owner.handle(lan.descriptor, TransferMessage.capability().encode())
        val successor = MockAndroidSecuredChannel(instance = "successor")
        owner.available(successor)
        assertFalse(owner.peerCompatible)
        owner.handle(lan.descriptor, TransferMessage.capability().encode())
        assertFalse(owner.peerCompatible)
        owner.dismiss()
    }

    @Test fun lanLossPausesReceiverAndRetainsPartialUntilResume() = runBlocking {
        val owner = TransferController(dispatcher = Dispatchers.Unconfined)
        val lan = MockAndroidSecuredChannel(instance = "lan")
        val ble = MockAndroidSecuredChannel(instance = "ble", transport = "ble")
        listOf(lan, ble).forEach { owner.available(it); owner.handle(it.descriptor, TransferMessage.capability().encode()) }
        val (batch, file) = offered(owner, lan, 10)
        owner.acceptIncomingOffer(tempDir)
        owner.handle(lan.descriptor, TransferMessage.chunk(batch, file, 0, byteArrayOf(0)).encode())
        owner.retired(lan.descriptor)
        val paused = owner.state as? TransferState.Paused
        assertNotNull("LAN loss must pause, not fail", paused)
        assertEquals(1L, paused!!.fileBytes)
        assertSame(ble, owner.activeChannel)
        assertEquals(1, tempDir.listFiles()!!.count { it.name.startsWith(".anice-") })

        // Old-channel chunks are discarded; the retained prefix is untouched.
        owner.handle(lan.descriptor, TransferMessage.chunk(batch, file, 1, ByteArray(9)).encode())
        assertEquals(paused, owner.state)

        // The sender resumes over BLE at the receiver's retained length.
        val prefix = MessageDigest.getInstance("SHA-256").digest(byteArrayOf(0))
        owner.handle(ble.descriptor, TransferMessage.resume(batch, file, 1, prefix).encode())
        val status = ble.sentData.mapNotNull { TransferMessage.decode(it) }.last { it.kind == 11L }
        assertEquals(0L, status.number(3))
        assertEquals(1L, status.number(2))

        owner.handle(ble.descriptor, TransferMessage.chunk(batch, file, 1, ByteArray(9)).encode())
        kotlinx.coroutines.withTimeout(2000) { while (owner.state !is TransferState.Completed) delay(5) }
        assertArrayEquals(ByteArray(10), File(tempDir, "empty.bin").readBytes())
        assertTrue(tempDir.listFiles()!!.none { it.name.startsWith(".anice-") })
        owner.dismiss()
    }

    @Test fun pausedTimeoutRemovesPartialAndFails() = runBlocking {
        val owner = TransferController(dispatcher = Dispatchers.Unconfined, pauseTimeoutMillis = 25)
        val lan = MockAndroidSecuredChannel(instance = "lan")
        owner.available(lan)
        owner.handle(lan.descriptor, TransferMessage.capability().encode())
        val (batch, file) = offered(owner, lan, 10)
        owner.acceptIncomingOffer(tempDir)
        owner.handle(lan.descriptor, TransferMessage.chunk(batch, file, 0, byteArrayOf(0)).encode())
        owner.retired(lan.descriptor)
        assertTrue(owner.state is TransferState.Paused)
        kotlinx.coroutines.withTimeout(2000) { while (owner.state !is TransferState.Failed) delay(5) }
        kotlinx.coroutines.withTimeout(2000) { while (tempDir.listFiles()!!.isNotEmpty()) delay(5) }
        owner.dismiss()
    }

    @Test fun cancelWhilePausedDeletesPartial() = runBlocking {
        val owner = TransferController(dispatcher = Dispatchers.Unconfined)
        val channel = MockAndroidSecuredChannel()
        owner.available(channel)
        owner.handle(channel.descriptor, TransferMessage.capability().encode())
        val (batch, file) = offered(owner, channel, 10)
        owner.acceptIncomingOffer(tempDir)
        owner.handle(channel.descriptor, TransferMessage.chunk(batch, file, 0, byteArrayOf(0)).encode())
        owner.retired(channel.descriptor)
        assertTrue(owner.state is TransferState.Paused)
        owner.cancelTransfer()
        assertEquals(TransferState.Cancelled, owner.state)
        kotlinx.coroutines.withTimeout(2000) { while (tempDir.listFiles()!!.isNotEmpty()) delay(5) }
    }

    @Test fun resumeOffsetMismatchAndPrefixMismatchRecover() = runBlocking {
        val owner = TransferController(dispatcher = Dispatchers.Unconfined)
        val lan = MockAndroidSecuredChannel(instance = "lan")
        val ble = MockAndroidSecuredChannel(instance = "ble", transport = "ble")
        listOf(lan, ble).forEach { owner.available(it); owner.handle(it.descriptor, TransferMessage.capability().encode()) }
        val (batch, file) = offered(owner, lan, 10)
        owner.acceptIncomingOffer(tempDir)
        owner.handle(lan.descriptor, TransferMessage.chunk(batch, file, 0, ByteArray(4)).encode())
        owner.retired(lan.descriptor)
        assertTrue(owner.state is TransferState.Paused)

        fun latestStatus() = ble.sentData.mapNotNull { TransferMessage.decode(it) }.last { it.kind == 11L }

        // A requested offset beyond the retained length reports the real length.
        owner.handle(ble.descriptor,
            TransferMessage.resume(batch, file, 9, MessageDigest.getInstance("SHA-256").digest(ByteArray(9))).encode())
        assertEquals(1L, latestStatus().number(3))
        assertEquals(4L, latestStatus().number(2))

        // A prefix that does not match discards the retained bytes and restarts from zero.
        owner.handle(ble.descriptor, TransferMessage.resume(batch, file, 4, ByteArray(32)).encode())
        assertEquals(2L, latestStatus().number(3))
        val parts = tempDir.listFiles()!!.filter { it.name.startsWith(".anice-") }
        assertEquals(1, parts.size)
        assertEquals(0L, parts.single().length())

        owner.handle(ble.descriptor,
            TransferMessage.resume(batch, file, 0, MessageDigest.getInstance("SHA-256").digest()).encode())
        assertEquals(0L, latestStatus().number(3))
        owner.handle(ble.descriptor, TransferMessage.chunk(batch, file, 0, ByteArray(10)).encode())
        kotlinx.coroutines.withTimeout(2000) { while (owner.state !is TransferState.Completed) delay(5) }
        assertArrayEquals(ByteArray(10), File(tempDir, "empty.bin").readBytes())
        owner.dismiss()
    }

    @Test fun lastChunkPauseReplaysVerifiedFileResult() = runBlocking {
        val owner = TransferController(dispatcher = Dispatchers.Unconfined)
        val channel = MockAndroidSecuredChannel()
        owner.available(channel)
        owner.handle(channel.descriptor, TransferMessage.capability().encode())
        val (batch, file) = offered(owner, channel, 4)
        owner.acceptIncomingOffer(tempDir)
        owner.handle(channel.descriptor, TransferMessage.chunk(batch, file, 0, ByteArray(4)).encode())
        kotlinx.coroutines.withTimeout(2000) { while (owner.state !is TransferState.Completed) delay(5) }
        val resultsBefore = channel.sentData.mapNotNull { TransferMessage.decode(it) }.count { it.kind == 7L }

        val prefix = MessageDigest.getInstance("SHA-256").digest(ByteArray(4))
        owner.handle(channel.descriptor, TransferMessage.resume(batch, file, 4, prefix).encode())
        val sent = channel.sentData.mapNotNull { TransferMessage.decode(it) }
        val status = sent.last { it.kind == 11L }
        assertEquals(0L, status.number(3))
        assertEquals(4L, status.number(2))
        assertTrue(sent.count { it.kind == 7L } > resultsBefore)
        owner.dismiss()
    }

    @Test fun asymmetricReceiverAcceptsResumeWhileStillTransferring() = runBlocking {
        val owner = TransferController(dispatcher = Dispatchers.Unconfined)
        val lan = MockAndroidSecuredChannel(instance = "lan")
        val ble = MockAndroidSecuredChannel(instance = "ble", transport = "ble")
        listOf(lan, ble).forEach { owner.available(it); owner.handle(it.descriptor, TransferMessage.capability().encode()) }
        val (batch, file) = offered(owner, lan, 10)
        owner.acceptIncomingOffer(tempDir)
        owner.handle(lan.descriptor, TransferMessage.chunk(batch, file, 0, byteArrayOf(0)).encode())
        assertSame(lan, owner.activeChannel)
        assertTrue(owner.state is TransferState.Transferring)

        // Only the sender lost its channel; the receiver is still transferring but must accept the
        // sender's resume on the new channel and rebind to it.
        val prefix = MessageDigest.getInstance("SHA-256").digest(byteArrayOf(0))
        owner.handle(ble.descriptor, TransferMessage.resume(batch, file, 1, prefix).encode())
        val status = ble.sentData.mapNotNull { TransferMessage.decode(it) }.last { it.kind == 11L }
        assertEquals(0L, status.number(3))
        assertEquals(1L, status.number(2))
        assertSame(ble, owner.activeChannel)

        owner.handle(ble.descriptor, TransferMessage.chunk(batch, file, 1, ByteArray(9)).encode())
        kotlinx.coroutines.withTimeout(2000) { while (owner.state !is TransferState.Completed) delay(5) }
        assertArrayEquals(ByteArray(10), File(tempDir, "empty.bin").readBytes())
        owner.dismiss()
    }

    @Test fun lanPauseAutoResumesWhenLanReconnects() = runBlocking {
        val sender = TransferController(dispatcher = Dispatchers.Unconfined)
        val receiver = TransferController(dispatcher = Dispatchers.Unconfined)
        val senderLan = MockAndroidSecuredChannel(instance = "sender-lan", deviceName = "Phone")
        val receiverLan = MockAndroidSecuredChannel(instance = "receiver-lan", deviceName = "MacBook")
        val capability = TransferMessage.capability().encode()
        sender.available(senderLan); sender.handle(senderLan.descriptor, capability)
        receiver.available(receiverLan); receiver.handle(receiverLan.descriptor, capability)

        val gateReached = kotlinx.coroutines.CompletableDeferred<Unit>()
        val gate = kotlinx.coroutines.CompletableDeferred<Unit>()
        var blocked = false
        senderLan.onSendData = { bytes ->
            val message = TransferMessage.decode(bytes)
            if (!blocked && message?.kind == 5L && message.number(2) == 6144L) {
                blocked = true
                gateReached.complete(Unit)
                gate.await()
            }
            receiver.handle(receiverLan.descriptor, bytes)
        }
        receiverLan.onSendData = { sender.handle(senderLan.descriptor, it) }

        val data = ByteArray(20_000) { (it % 251).toByte() }
        val source = File(tempDir, "source.bin").apply { writeBytes(data) }
        val dest = File(tempDir, "dest").apply { mkdirs() }
        sender.sendFiles(listOf(source))
        kotlinx.coroutines.withTimeout(2000) { while (receiver.state !is TransferState.IncomingOffer) delay(5) }
        receiver.acceptIncomingOffer(dest)
        kotlinx.coroutines.withTimeout(2000) { gateReached.await() }

        sender.retired(senderLan.descriptor)
        val paused = sender.state as? TransferState.Paused
        assertNotNull(paused)
        assertTrue("The partial must survive the pause", receiver.state is TransferState.Transferring)

        // The same peer answers on a fresh LAN channel; the resumed sender adopts the receiver's length.
        val senderLan2 = MockAndroidSecuredChannel(instance = "sender-lan-2", deviceName = "Phone")
        senderLan2.onSendData = { receiver.handle(receiverLan.descriptor, it) }
        receiverLan.onSendData = { sender.handle(senderLan2.descriptor, it) }
        sender.available(senderLan2)
        sender.handle(senderLan2.descriptor, capability)

        kotlinx.coroutines.withTimeout(4000) {
            while (sender.state !is TransferState.Completed || receiver.state !is TransferState.Completed) delay(5)
        }
        assertArrayEquals(data, File(dest, "source.bin").readBytes())
        assertTrue(dest.listFiles()!!.none { it.name.startsWith(".anice-") })
        assertTrue(senderLan2.sentData.mapNotNull { TransferMessage.decode(it) }.any { it.kind == 10L })
        sender.dismiss(); receiver.dismiss()
    }

    @Test fun bleContinuationRequiresExplicitOptIn() = runBlocking {
        val sender = TransferController(dispatcher = Dispatchers.Unconfined)
        val receiver = TransferController(dispatcher = Dispatchers.Unconfined)
        val senderLan = MockAndroidSecuredChannel(instance = "sender-lan", deviceName = "Phone")
        val receiverLan = MockAndroidSecuredChannel(instance = "receiver-lan", deviceName = "MacBook")
        val senderBle = MockAndroidSecuredChannel(instance = "sender-ble", transport = "ble", deviceName = "Phone")
        val receiverBle = MockAndroidSecuredChannel(instance = "receiver-ble", transport = "ble", deviceName = "MacBook")
        val capability = TransferMessage.capability().encode()
        listOf(senderLan, senderBle).forEach { sender.available(it); sender.handle(it.descriptor, capability) }
        listOf(receiverLan, receiverBle).forEach { receiver.available(it); receiver.handle(it.descriptor, capability) }

        val gateReached = kotlinx.coroutines.CompletableDeferred<Unit>()
        val gate = kotlinx.coroutines.CompletableDeferred<Unit>()
        var blocked = false
        senderLan.onSendData = { bytes ->
            val message = TransferMessage.decode(bytes)
            if (!blocked && message?.kind == 5L && message.number(2) == 6144L) {
                blocked = true
                gateReached.complete(Unit)
                gate.await()
            }
            receiver.handle(receiverLan.descriptor, bytes)
        }
        senderBle.onSendData = { receiver.handle(receiverBle.descriptor, it) }
        receiverLan.onSendData = { sender.handle(senderLan.descriptor, it) }
        receiverBle.onSendData = { sender.handle(senderBle.descriptor, it) }

        val data = ByteArray(20_000) { (it % 251).toByte() }
        val source = File(tempDir, "source.bin").apply { writeBytes(data) }
        val dest = File(tempDir, "dest").apply { mkdirs() }
        sender.sendFiles(listOf(source))
        kotlinx.coroutines.withTimeout(2000) { while (receiver.state !is TransferState.IncomingOffer) delay(5) }
        receiver.acceptIncomingOffer(dest)
        kotlinx.coroutines.withTimeout(2000) { gateReached.await() }

        sender.retired(senderLan.descriptor)
        receiver.retired(receiverLan.descriptor)
        assertTrue(sender.state is TransferState.Paused)
        assertTrue(receiver.state is TransferState.Paused)
        delay(50)
        assertFalse("BLE must not resume a LAN pause before opt-in",
            senderBle.sentData.mapNotNull { TransferMessage.decode(it) }.any { it.kind == 10L })

        val chunksBefore = senderBle.sentData.size
        sender.resumeOverBluetooth()
        kotlinx.coroutines.withTimeout(4000) {
            while (sender.state !is TransferState.Completed || receiver.state !is TransferState.Completed) delay(5)
        }
        assertArrayEquals(data, File(dest, "source.bin").readBytes())
        val resumedChunks = senderBle.sentData.drop(chunksBefore).mapNotNull { TransferMessage.decode(it) }
            .filter { it.kind == 5L }
        assertTrue(resumedChunks.isNotEmpty())
        assertTrue("BLE continuation must use BLE-sized chunks", resumedChunks.all { it.bytes(3).size <= 3072 })
        sender.dismiss(); receiver.dismiss()
    }

    @Test fun receiverCanAskTheSenderToContinueOverBluetooth() = runBlocking {
        val sender = TransferController(dispatcher = Dispatchers.Unconfined)
        val receiver = TransferController(dispatcher = Dispatchers.Unconfined)
        val senderLan = MockAndroidSecuredChannel(instance = "sender-lan", deviceName = "Phone")
        val receiverLan = MockAndroidSecuredChannel(instance = "receiver-lan", deviceName = "MacBook")
        val senderBle = MockAndroidSecuredChannel(instance = "sender-ble", transport = "ble", deviceName = "Phone")
        val receiverBle = MockAndroidSecuredChannel(instance = "receiver-ble", transport = "ble", deviceName = "MacBook")
        val capability = TransferMessage.capability().encode()
        listOf(senderLan, senderBle).forEach { sender.available(it); sender.handle(it.descriptor, capability) }
        listOf(receiverLan, receiverBle).forEach { receiver.available(it); receiver.handle(it.descriptor, capability) }

        val gateReached = kotlinx.coroutines.CompletableDeferred<Unit>()
        val gate = kotlinx.coroutines.CompletableDeferred<Unit>()
        var blocked = false
        senderLan.onSendData = { bytes ->
            val message = TransferMessage.decode(bytes)
            if (!blocked && message?.kind == 5L && message.number(2) == 6144L) {
                blocked = true
                gateReached.complete(Unit)
                gate.await()
            }
            receiver.handle(receiverLan.descriptor, bytes)
        }
        senderBle.onSendData = { receiver.handle(receiverBle.descriptor, it) }
        receiverLan.onSendData = { sender.handle(senderLan.descriptor, it) }
        receiverBle.onSendData = { sender.handle(senderBle.descriptor, it) }

        val data = ByteArray(20_000) { (it % 251).toByte() }
        val source = File(tempDir, "source.bin").apply { writeBytes(data) }
        val dest = File(tempDir, "dest").apply { mkdirs() }
        sender.sendFiles(listOf(source))
        kotlinx.coroutines.withTimeout(2000) { while (receiver.state !is TransferState.IncomingOffer) delay(5) }
        receiver.acceptIncomingOffer(dest)
        kotlinx.coroutines.withTimeout(2000) { gateReached.await() }

        sender.retired(senderLan.descriptor)
        receiver.retired(receiverLan.descriptor)
        val paused = receiver.state as? TransferState.Paused
        assertNotNull(paused)
        assertTrue("The receiver with a capable BLE channel must offer continuation", paused!!.canResumeOverBle)
        delay(30)
        assertFalse("No continuation happens before the explicit opt-in",
            receiverBle.sentData.mapNotNull { TransferMessage.decode(it) }.any { it.kind == 10L })

        // The receiving device, not the sender, initiates the resume over Bluetooth.
        receiver.resumeOverBluetooth()
        kotlinx.coroutines.withTimeout(4000) {
            while (sender.state !is TransferState.Completed || receiver.state !is TransferState.Completed) delay(5)
        }
        assertTrue("The receiver must send the resume request",
            receiverBle.sentData.mapNotNull { TransferMessage.decode(it) }.any { it.kind == 10L })
        assertTrue("The sender must answer over the same channel",
            senderBle.sentData.mapNotNull { TransferMessage.decode(it) }.any { it.kind == 11L })
        assertArrayEquals(data, File(dest, "source.bin").readBytes())
        assertTrue(dest.listFiles()!!.none { it.name.startsWith(".anice-") })
        sender.dismiss(); receiver.dismiss()
    }

    @Test fun lanReconnectUpgradesAnActiveBluetoothStream() = runBlocking {
        val sender = TransferController(dispatcher = Dispatchers.Unconfined)
        val receiver = TransferController(dispatcher = Dispatchers.Unconfined)
        val senderBle = MockAndroidSecuredChannel(instance = "sender-ble", transport = "ble", deviceName = "Phone")
        val receiverBle = MockAndroidSecuredChannel(instance = "receiver-ble", transport = "ble", deviceName = "MacBook")
        val capability = TransferMessage.capability().encode()
        listOf(senderBle).forEach { sender.available(it); sender.handle(it.descriptor, capability) }
        listOf(receiverBle).forEach { receiver.available(it); receiver.handle(it.descriptor, capability) }

        val gateReached = kotlinx.coroutines.CompletableDeferred<Unit>()
        val gate = kotlinx.coroutines.CompletableDeferred<Unit>()
        var blocked = false
        senderBle.onSendData = { bytes ->
            val message = TransferMessage.decode(bytes)
            if (!blocked && message?.kind == 5L && message.number(2) == 6144L) {
                blocked = true
                gateReached.complete(Unit)
                gate.await()
            }
            receiver.handle(receiverBle.descriptor, bytes)
        }
        receiverBle.onSendData = { sender.handle(senderBle.descriptor, it) }

        val data = ByteArray(20_000) { (it % 251).toByte() }
        val source = File(tempDir, "source.bin").apply { writeBytes(data) }
        val dest = File(tempDir, "dest").apply { mkdirs() }
        sender.sendFiles(listOf(source))
        kotlinx.coroutines.withTimeout(2000) { while (receiver.state !is TransferState.IncomingOffer) delay(5) }
        receiver.acceptIncomingOffer(dest)
        kotlinx.coroutines.withTimeout(2000) { gateReached.await() }

        // A live LAN appears while the Bluetooth stream is still in flight.
        val senderLan = MockAndroidSecuredChannel(instance = "sender-lan", deviceName = "Phone")
        val receiverLan = MockAndroidSecuredChannel(instance = "receiver-lan", deviceName = "MacBook")
        senderLan.onSendData = { receiver.handle(receiverLan.descriptor, it) }
        receiverLan.onSendData = { sender.handle(senderLan.descriptor, it) }
        receiver.available(receiverLan); receiver.handle(receiverLan.descriptor, capability)
        sender.available(senderLan); sender.handle(senderLan.descriptor, capability)

        kotlinx.coroutines.withTimeout(4000) {
            while (sender.state !is TransferState.Completed || receiver.state !is TransferState.Completed) delay(5)
        }
        val lanMessages = senderLan.sentData.mapNotNull { TransferMessage.decode(it) }
        assertTrue("The sender must hand the stream over through the resume handshake",
            lanMessages.any { it.kind == 10L })
        assertTrue("The remainder must continue over LAN, not Bluetooth",
            lanMessages.any { it.kind == 5L })
        assertArrayEquals(data, File(dest, "source.bin").readBytes())
        assertTrue(dest.listFiles()!!.none { it.name.startsWith(".anice-") })
        sender.dismiss(); receiver.dismiss()
    }

    @Test fun activeBleBatchKeepsItsGenerationUntilCleanupThenPrefersLan() = runBlocking {
        val owner = TransferController(dispatcher = Dispatchers.Unconfined)
        val ble = MockAndroidSecuredChannel(instance = "ble", transport = "ble")
        val lan = MockAndroidSecuredChannel(instance = "lan")
        owner.available(ble)
        owner.handle(ble.descriptor, TransferMessage.capability().encode())
        offered(owner, ble, 1)
        owner.available(lan)
        owner.handle(lan.descriptor, TransferMessage.capability().encode())
        assertSame(ble, owner.activeChannel)
        owner.cancelTransfer(local = false)
        assertSame(lan, owner.activeChannel)
        assertTrue(owner.peerCompatible)
    }

    @Test fun fallbackRejectsAnotherPeerAndLeavesOtherFeatureDataUnrecognized() = runBlocking {
        val owner = TransferController(dispatcher = Dispatchers.Unconfined)
        val lan = MockAndroidSecuredChannel(instance = "lan")
        val other = MockAndroidSecuredChannel(instance = "other", transport = "ble",
            peerOverride = lan.descriptor.peer.copy(deviceId = "00000000-0000-4000-8000-000000000002"))
        owner.available(lan)
        owner.available(other)
        val unrelated = io.github.anisharyal09.anice.infrastructure.session.SessionCbor.encode(Cbor.Array(listOf(Cbor.Text("another feature"))))
        assertEquals(io.github.anisharyal09.anice.infrastructure.connections.DataHandling.UNRECOGNIZED,
            owner.handle(other.descriptor, unrelated))
        owner.retired(lan.descriptor)
        assertFalse(owner.peerConnected)
    }

    @Test fun cancellingBleBatchStillNotifiesItsPeerWhenLanBecomesPreferred() = runBlocking {
        val owner = TransferController(dispatcher = Dispatchers.Unconfined)
        val ble = MockAndroidSecuredChannel(instance = "ble", transport = "ble")
        val lan = MockAndroidSecuredChannel(instance = "lan")
        owner.available(ble)
        offered(owner, ble, 1)
        owner.available(lan)
        owner.cancelTransfer()
        assertSame(lan, owner.activeChannel)
        assertTrue(ble.sentData.mapNotNull { TransferMessage.decode(it) }.any { it.kind == 9L })
        assertFalse(lan.sentData.mapNotNull { TransferMessage.decode(it) }.any { it.kind == 9L })
    }

    @Test fun capacityNotificationDoesNotDrainWaitersAddedByItsOwnCallbacks() = runBlocking {
        val owner = TransferController(dispatcher = Dispatchers.Unconfined)
        val ble = MockAndroidSecuredChannel(instance = "ble", transport = "ble")
        var attempts = 0
        var blocked = true
        ble.onSendData = {
            attempts++
            // Cap the broken implementation so this regression fails instead of hanging the suite.
            if (blocked && attempts < 8) throw SessionBackpressure()
        }
        owner.available(ble)
        assertEquals(1, attempts)
        owner.capacityAvailable(ble.descriptor)
        assertEquals("One capacity event must wake the pending sender only once", 2, attempts)
        owner.capacityAvailable(ble.descriptor)
        assertEquals(3, attempts)
        blocked = false
        owner.capacityAvailable(ble.descriptor)
        assertEquals(4, attempts)
        owner.retired(ble.descriptor)
    }

    @Test fun standbyCapabilityWaitSurvivesJobCleanupAndUsesStandbyCapacity() = runBlocking {
        val owner = TransferController(dispatcher = Dispatchers.Unconfined)
        val lan = MockAndroidSecuredChannel(instance = "lan")
        val ble = MockAndroidSecuredChannel(instance = "ble", transport = "ble")
        var attempts = 0
        ble.onSendData = { if (++attempts == 1) throw SessionBackpressure() }
        owner.available(lan)
        offered(owner, lan, 1)
        owner.available(ble)
        assertEquals(1, attempts)
        owner.cancelTransfer(local = false)
        owner.capacityAvailable(ble.descriptor)
        assertEquals(2, attempts)
        assertSame(lan, owner.activeChannel)
    }

    @Test fun partiallyAssembledBleOfferKeepsItsChannelWhenLanArrives() = runBlocking {
        val owner = TransferController(dispatcher = Dispatchers.Unconfined)
        val ble = MockAndroidSecuredChannel(instance = "ble", transport = "ble")
        val lan = MockAndroidSecuredChannel(instance = "lan")
        owner.available(ble)
        val batch = UUID.randomUUID().toString()
        val rows = (0..1).map { index -> Cbor.Array(listOf(Cbor.Text(UUID.randomUUID().toString()),
            Cbor.Text("$index.bin"), Cbor.Integer(0), Cbor.Bytes(MessageDigest.getInstance("SHA-256").digest()))) }
        owner.handle(ble.descriptor, TransferMessage.offer(batch, 0, 2, 2, 0, listOf(rows[0])).encode())
        owner.available(lan)
        assertSame(ble, owner.activeChannel)
        owner.handle(ble.descriptor, TransferMessage.offer(batch, 1, 2, 2, 0, listOf(rows[1])).encode())
        assertTrue(owner.state is TransferState.IncomingOffer)
        assertSame(ble, owner.activeChannel)
        owner.rejectIncomingOffer()
        assertSame(lan, owner.activeChannel)
    }

    @Test fun capabilityArrivingAfterOfferRemainsUsableAfterCleanup() = runBlocking {
        val owner = TransferController(dispatcher = Dispatchers.Unconfined)
        val channel = MockAndroidSecuredChannel()
        owner.available(channel)
        offered(owner, channel, 1)
        owner.handle(channel.descriptor, TransferMessage.capability().encode())
        owner.rejectIncomingOffer()
        assertTrue(owner.peerCompatible)
        owner.retired(channel.descriptor)
        assertFalse(owner.peerCompatible)
    }

    private class QueuedDispatcher : kotlinx.coroutines.CoroutineDispatcher() {
        private val pending = java.util.concurrent.ConcurrentLinkedQueue<Runnable>()
        override fun dispatch(context: kotlin.coroutines.CoroutineContext, block: Runnable) { pending.add(block) }
        fun drain() { while (true) (pending.poll() ?: return).run() }
    }

    @Test fun deferredRejectTargetsBleAfterCleanupSelectsLan() = runBlocking {
        val dispatcher = QueuedDispatcher()
        val owner = TransferController(dispatcher = dispatcher)
        val ble = MockAndroidSecuredChannel(instance = "ble", transport = "ble")
        val lan = MockAndroidSecuredChannel(instance = "lan")
        owner.available(ble)
        offered(owner, ble, 1)
        owner.available(lan)
        owner.rejectIncomingOffer()
        assertSame(lan, owner.activeChannel)
        dispatcher.drain()
        assertTrue(ble.sentData.mapNotNull { TransferMessage.decode(it) }.any { it.kind == 4L })
        assertFalse(lan.sentData.mapNotNull { TransferMessage.decode(it) }.any { it.kind == 4L })
    }

    @Test fun queuedAcceptAndAckCannotCrossIntoNextChannelOrBatch() = runBlocking {
        val dispatcher = QueuedDispatcher()
        val owner = TransferController(dispatcher = dispatcher)
        val ble = MockAndroidSecuredChannel(instance = "ble", transport = "ble")
        val lan = MockAndroidSecuredChannel(instance = "lan")
        owner.available(ble)
        val (batch, file) = offered(owner, ble, 100_000)
        owner.acceptIncomingOffer(tempDir)
        owner.available(lan)
        repeat(8) { index -> owner.handle(ble.descriptor,
            TransferMessage.chunk(batch, file, index * 3072L, ByteArray(3072)).encode()) }
        owner.cancelTransfer(local = false)
        offered(owner, lan, 1)
        val next = owner.state
        dispatcher.drain()
        assertEquals(next, owner.state)
        assertTrue(next is TransferState.IncomingOffer)
        for (channel in listOf(ble, lan)) assertFalse(channel.sentData.mapNotNull { TransferMessage.decode(it) }
            .any { it.kind == 3L || it.kind == 6L })
        owner.dismiss()
    }

    @Test fun delayedBatchCompletionCannotCleanUpReplacementOffer() = runBlocking {
        val owner = TransferController(dispatcher = coroutineContext[kotlin.coroutines.ContinuationInterceptor] as kotlinx.coroutines.CoroutineDispatcher)
        val channel = MockAndroidSecuredChannel()
        val entered = kotlinx.coroutines.CompletableDeferred<Unit>()
        val release = kotlinx.coroutines.CompletableDeferred<Unit>()
        owner.available(channel)
        owner.handle(channel.descriptor, TransferMessage.capability().encode())
        channel.onSendData = { bytes ->
            val message = TransferMessage.decode(bytes)
            if (message?.kind == 8L) { entered.complete(Unit); release.await() }
        }
        try {
            owner.sendFiles(listOf(File(tempDir, "empty.bin").apply { writeBytes(byteArrayOf()) }))
            withTimeout(2000) { while (owner.state !is TransferState.WaitingForPeerApproval) delay(5) }
            val batch = (owner.state as TransferState.WaitingForPeerApproval).batch
            owner.handle(channel.descriptor, TransferMessage.accept(batch.id).encode())
            withTimeout(2000) { while (owner.state !is TransferState.Transferring) delay(5) }
            val file = batch.files.single()
            owner.handle(channel.descriptor, TransferMessage.fileResult(batch.id, file.id, 0, file.sha256).encode())
            withTimeout(2000) { entered.await() }
            owner.cancelTransfer(local = false)
            offered(owner, channel, 1)
            val replacement = owner.state
            release.complete(Unit)
            delay(60)
            assertEquals(replacement, owner.state)
            assertTrue(owner.state is TransferState.IncomingOffer)
        } finally { release.complete(Unit); owner.dismiss() }
    }

    @Test fun cancelledSourceOpenCannotStealReplacementFileConfirmation() = runBlocking {
        val opened = kotlinx.coroutines.CompletableDeferred<Unit>()
        val release = java.util.concurrent.CountDownLatch(1)
        val closed = kotlinx.coroutines.CompletableDeferred<Unit>()
        var first = true
        val owner = TransferController(
            dispatcher = coroutineContext[kotlin.coroutines.ContinuationInterceptor] as kotlinx.coroutines.CoroutineDispatcher,
            openSource = { file ->
                if (first) {
                    first = false
                    opened.complete(Unit)
                    check(release.await(5, java.util.concurrent.TimeUnit.SECONDS))
                    object : java.io.ByteArrayInputStream(byteArrayOf()) {
                        override fun close() { super.close(); closed.complete(Unit) }
                    }
                } else java.io.FileInputStream(file.sourceFile!!)
            })
        val channel = MockAndroidSecuredChannel()
        owner.available(channel)
        owner.handle(channel.descriptor, TransferMessage.capability().encode())
        suspend fun start(name: String): TransferBatch {
            owner.sendFiles(listOf(File(tempDir, name).apply { writeBytes(byteArrayOf()) }))
            withTimeout(2000) { while (owner.state !is TransferState.WaitingForPeerApproval) delay(5) }
            val batch = (owner.state as TransferState.WaitingForPeerApproval).batch
            owner.handle(channel.descriptor, TransferMessage.accept(batch.id).encode())
            return batch
        }
        try {
            start("old.bin")
            withTimeout(2000) { opened.await() }
            owner.cancelTransfer(local = false)
            val next = start("new.bin")
            withTimeout(2000) { while (owner.state !is TransferState.Transferring) delay(5) }
            delay(30)
            release.countDown()
            withTimeout(2000) { closed.await() }
            delay(30)
            val file = next.files.single()
            owner.handle(channel.descriptor, TransferMessage.fileResult(next.id, file.id, 0, file.sha256).encode())
            withTimeout(2000) { while (owner.state !is TransferState.Completed) delay(5) }
            assertEquals(next.id, (owner.state as TransferState.Completed).batchId)
            assertTrue(File(tempDir, "old.bin").exists())
            assertTrue(File(tempDir, "new.bin").exists())
        } finally { release.countDown(); owner.dismiss() }
    }

    @Test fun explicitSendAcquiresOwnershipBeforeHashingAndReleasesItOnCancel() = runBlocking {
        val owner = TransferController(dispatcher = coroutineContext[kotlin.coroutines.ContinuationInterceptor] as kotlinx.coroutines.CoroutineDispatcher)
        val channel = MockAndroidSecuredChannel()
        owner.available(channel)
        owner.handle(channel.descriptor, TransferMessage.capability().encode())
        val leases = mutableListOf<Pair<Boolean, Boolean>>()
        owner.onLeaseChanged = { approved -> leases.add(approved to owner.preparing) }
        val source = File(tempDir, "source.bin").apply { writeBytes(ByteArray(65536)) }
        owner.sendFiles(listOf(source))
        assertEquals(true to true, leases.first())
        kotlinx.coroutines.withTimeout(2000) { while (owner.preparing) delay(5) }
        owner.cancelTransfer(local = false)
        assertEquals(false, leases.last().first)
    }

    @Test fun pendingLanConnectionOwnsUserApprovedWorkUntilCancellation() = runBlocking {
        val owner = TransferController(dispatcher = Dispatchers.Unconfined)
        owner.onDemandLanConnection = { true }
        val leases = mutableListOf<Boolean>()
        owner.onLeaseChanged = { leases.add(it) }
        owner.sendFiles(listOf(File(tempDir, "source.bin")))
        assertTrue(owner.state is TransferState.Connecting)
        assertEquals(listOf(true), leases)
        owner.cancelTransfer(local = false)
        assertEquals(listOf(true, false), leases)
    }

    @Test fun lanFailureDoesNotDisturbASendAlreadyUsingSecuredBle() = runBlocking {
        val owner = TransferController(dispatcher = Dispatchers.Unconfined)
        val ble = MockAndroidSecuredChannel(instance = "ble", transport = "ble")
        owner.available(ble)
        owner.handle(ble.descriptor, TransferMessage.capability().encode())
        val source = File(tempDir, "source.bin").apply { writeBytes(ByteArray(4096)) }
        owner.sendFiles(listOf(source))
        owner.onLanUnavailable("Local-network connection failed.")
        kotlinx.coroutines.withTimeout(2000) {
            while (owner.state !is TransferState.WaitingForPeerApproval && owner.state !is TransferState.Failed) delay(5)
        }
        assertTrue(owner.state is TransferState.WaitingForPeerApproval)
        owner.dismiss()
    }

    @Test fun incapableLanDoesNotSuppressBluetoothFallback() = runBlocking {
        val owner = TransferController(dispatcher = Dispatchers.Unconfined)
        val ble = MockAndroidSecuredChannel(instance = "ble", transport = "ble")
        val lan = MockAndroidSecuredChannel(instance = "lan", transport = "lan")
        owner.available(ble)
        owner.handle(ble.descriptor, TransferMessage.capability().encode())
        owner.available(lan)
        owner.onDemandLanConnection = { true }
        val source = File(tempDir, "fallback.bin").apply { writeBytes(byteArrayOf(1)) }
        try {
            owner.sendFiles(listOf(source))
            assertTrue(owner.state is TransferState.Connecting)
            owner.onLanUnavailable("LAN capability unavailable")
            withTimeout(2000) { while (ble.sentData.none { TransferMessage.decode(it)?.kind == 2L }) delay(5) }
            assertTrue(owner.state is TransferState.WaitingForPeerApproval)
            assertFalse(lan.sentData.any { TransferMessage.decode(it)?.kind == 2L })
        } finally { owner.dismiss() }
    }

    @Test fun readyBluetoothWaitsForRequestedLanBeforeOffering() = runBlocking {
        val owner = TransferController(dispatcher = Dispatchers.Unconfined)
        val ble = MockAndroidSecuredChannel(instance = "ble", transport = "ble")
        owner.available(ble)
        owner.handle(ble.descriptor, TransferMessage.capability().encode())
        var demands = 0
        owner.onDemandLanConnection = { demands++; true }
        val source = File(tempDir, "source.bin").apply { writeBytes(ByteArray(1024)) }
        try {
            owner.sendFiles(listOf(source))
            assertEquals(1, demands)
            assertTrue(owner.state is TransferState.Connecting)
            delay(60)
            assertTrue("BLE must not take the offer while requested LAN is pending",
                ble.sentData.none { TransferMessage.decode(it)?.kind == 2L })
            val lan = MockAndroidSecuredChannel(instance = "lan", transport = "lan", maximumDataBytes = 262144)
            owner.available(lan)
            owner.handle(lan.descriptor, TransferMessage.capability(3, 262016, 8).encode(262016))
            withTimeout(2000) { while (lan.sentData.none { TransferMessage.decode(it, 262016)?.kind == 2L }) delay(5) }
            assertTrue(owner.state is TransferState.WaitingForPeerApproval)
            assertEquals("lan", owner.activeChannel?.descriptor?.transport)
            assertTrue(ble.sentData.none { TransferMessage.decode(it)?.kind == 2L })
        } finally { owner.dismiss() }
    }

    @Test fun bluetoothCapabilityDoesNotPreemptRequestedLanRendezvous() = runBlocking {
        val owner = TransferController(dispatcher = Dispatchers.Unconfined)
        val ble = MockAndroidSecuredChannel(instance = "ble", transport = "ble")
        owner.available(ble)
        owner.onDemandLanConnection = { true }
        val source = File(tempDir, "source.bin").apply { writeBytes(ByteArray(1024)) }
        try {
            owner.sendFiles(listOf(source))
            assertTrue(owner.state is TransferState.Connecting)
            owner.handle(ble.descriptor, TransferMessage.capability().encode())
            delay(60)
            assertTrue(owner.state is TransferState.Connecting)
            assertFalse(ble.sentData.any { TransferMessage.decode(it)?.kind == 2L })
            owner.onLanUnavailable("Local network unavailable")
            withTimeout(2000) { while (ble.sentData.none { TransferMessage.decode(it)?.kind == 2L }) delay(5) }
            assertTrue(owner.state is TransferState.WaitingForPeerApproval)
        } finally { owner.dismiss() }
    }

    @Test fun senderProgressWaitsForReceiverAcknowledgements() = runBlocking {
        val owner = TransferController(dispatcher = Dispatchers.Unconfined)
        val channel = MockAndroidSecuredChannel(transport = "ble")
        owner.available(channel)
        owner.handle(channel.descriptor, TransferMessage.capability().encode())
        val source = File(tempDir, "source.bin").apply { writeBytes(ByteArray(12288)) }
        owner.sendFiles(listOf(source))
        withTimeout(2000) { while (owner.state !is TransferState.WaitingForPeerApproval) delay(5) }
        val batch = (owner.state as TransferState.WaitingForPeerApproval).batch
        owner.handle(channel.descriptor, TransferMessage.accept(batch.id).encode())
        withTimeout(2000) { while (channel.sentData.count { TransferMessage.decode(it)?.kind == 5L } < 4) delay(5) }
        assertEquals(0L, (owner.state as TransferState.Transferring).totalBytes)
        owner.handle(channel.descriptor, TransferMessage.ack(batch.id, batch.files[0].id, 3072).encode())
        withTimeout(2000) { while ((owner.state as TransferState.Transferring).fileBytes != 3072L) delay(10) }
        assertEquals(3072L, (owner.state as TransferState.Transferring).totalBytes)
        withTimeout(1000) { while ((owner.state as TransferState.Transferring).speedBps <= 0) delay(10) }
        withTimeout(6500) { while ((owner.state as TransferState.Transferring).speedBps > 0) delay(10) }
        assertEquals(3072L, (owner.state as TransferState.Transferring).totalBytes)
        owner.dismiss()
    }

    @Test fun lanFailureWithoutAnotherChannelFailsThePendingSendImmediately() = runBlocking {
        val owner = TransferController(dispatcher = Dispatchers.Unconfined)
        owner.onDemandLanConnection = { true }
        val source = File(tempDir, "source.bin").apply { writeBytes(ByteArray(16)) }
        owner.sendFiles(listOf(source))
        assertTrue(owner.state is TransferState.Connecting)
        owner.onLanUnavailable("No local network.")
        assertEquals("No local network.", (owner.state as TransferState.Failed).reason)
        owner.dismiss()
    }

    @Test fun lanFailureFallsBackToSecuredBleChannelWhenPendingSendWaits() = runBlocking {
        val owner = TransferController(dispatcher = Dispatchers.Unconfined)
        owner.onDemandLanConnection = { true }
        val source = File(tempDir, "source.bin").apply { writeBytes(ByteArray(1024)) }
        owner.sendFiles(listOf(source))
        assertTrue(owner.state is TransferState.Connecting)
        val ble = MockAndroidSecuredChannel(instance = "ble", transport = "ble")
        owner.available(ble)
        owner.handle(ble.descriptor, TransferMessage.capability().encode())
        owner.onLanUnavailable("Wi-Fi unavailable.")
        kotlinx.coroutines.withTimeout(2000) {
            while (owner.state !is TransferState.WaitingForPeerApproval && owner.state !is TransferState.Failed) delay(5)
        }
        assertTrue(owner.state is TransferState.WaitingForPeerApproval)
        owner.dismiss()
    }

    @Test fun retiringStandbyChannelReleasesItsCapacityWaitImmediately() = runBlocking {
        val owner = TransferController(dispatcher = Dispatchers.Unconfined)
        val lan = MockAndroidSecuredChannel(instance = "lan")
        val ble = MockAndroidSecuredChannel(instance = "ble", transport = "ble")
        ble.onSendData = { throw SessionBackpressure() }
        owner.available(lan)
        owner.available(ble)
        val waiters = TransferController::class.java.getDeclaredField("capacityWaiters")
            .apply { isAccessible = true }.get(owner) as java.util.Queue<*>
        assertEquals(1, waiters.size)
        owner.retired(ble.descriptor)
        assertTrue(waiters.isEmpty())
        assertSame(lan, owner.activeChannel)
        owner.dismiss()
    }

    @Test fun offerAssemblyPreservesOrderingAndRejectsConflictingDuplicates() = runBlocking {
        val owner = TransferController(dispatcher = Dispatchers.Unconfined)
        val channel = MockAndroidSecuredChannel()
        owner.available(channel)
        val batch = UUID.randomUUID().toString()
        val rows = (0..1).map { index -> Cbor.Array(listOf(Cbor.Text(UUID.randomUUID().toString()),
            Cbor.Text("$index.bin"), Cbor.Integer(0), Cbor.Bytes(MessageDigest.getInstance("SHA-256").digest()))) }
        fun slice(index: Long, row: Cbor.Array = rows[index.toInt()]) =
            TransferMessage.offer(batch, index, 2, 2, 0, listOf(row)).encode()
        owner.handle(channel.descriptor, slice(1))
        owner.handle(channel.descriptor, slice(1))
        assertEquals(TransferState.Idle, owner.state)
        val other = MockAndroidSecuredChannel(instance = "other")
        owner.handle(other.descriptor, slice(0))
        assertEquals(TransferState.Idle, owner.state)
        owner.handle(channel.descriptor, slice(0, rows[1]))
        assertEquals(TransferState.Idle, owner.state) // Duplicate file identity across slices.
        owner.handle(channel.descriptor, slice(1))
        owner.handle(channel.descriptor, slice(1, rows[0])) // Conflicting duplicate clears the assembly.
        owner.handle(channel.descriptor, slice(0))
        assertEquals(TransferState.Idle, owner.state)
        owner.handle(channel.descriptor, slice(1))
        val offer = owner.state as TransferState.IncomingOffer
        assertEquals(listOf("0.bin", "1.bin"), offer.batch.files.map { it.name })
        owner.dismiss()
    }

    @Test fun failedPreparationPublishesNoOfferAndCanPrepareAgain() = runBlocking {
        val owner = TransferController(dispatcher = Dispatchers.Unconfined)
        val channel = MockAndroidSecuredChannel()
        owner.available(channel)
        owner.handle(channel.descriptor, TransferMessage.capability().encode())
        val changing = File(tempDir, "changing.bin").apply { writeBytes(byteArrayOf(1)) }
        val invalid = File(tempDir, "invalid\\name.bin").apply { writeBytes(byteArrayOf(1)) }
        val sources = listOf(File(tempDir, "missing.bin"), invalid,
            object : File(changing.path) { override fun length() = 0L },
            object : File(changing.path) { override fun length() = 2L })
        for (source in sources) {
            owner.sendFiles(listOf(source))
            kotlinx.coroutines.withTimeout(2000) { while (owner.preparing) delay(5) }
            assertTrue(owner.state is TransferState.Failed)
            assertFalse(channel.sentData.any { TransferMessage.decode(it)?.kind == 2L })
        }
        val empty = File(tempDir, "empty.bin").apply { writeBytes(ByteArray(0)) }
        owner.sendFiles(listOf(empty))
        kotlinx.coroutines.withTimeout(2000) { while (owner.preparing) delay(5) }
        val batch = (owner.state as TransferState.WaitingForPeerApproval).batch
        assertEquals(0L, batch.totalBytes)
        assertArrayEquals(MessageDigest.getInstance("SHA-256").digest(), batch.files.single().sha256)
        owner.dismiss()
    }

    private suspend fun offered(receiver: TransferController, channel: MockAndroidSecuredChannel, size: Long = 0L): Pair<String, String> {
        val batch = UUID.randomUUID().toString()
        val file = UUID.randomUUID().toString()
        val digest = MessageDigest.getInstance("SHA-256").digest(ByteArray(size.toInt()))
        receiver.handle(channel.descriptor, TransferMessage.offer(batch, 0, 1, 1, size,
            listOf(Cbor.Array(listOf(Cbor.Text(file), Cbor.Text("empty.bin"), Cbor.Integer(size), Cbor.Bytes(digest))))).encode())
        return batch to file
    }

    @Test fun failedAckWaitsForExternalCapacityInsteadOfRetryingItself() = runBlocking {
        val owner = TransferController(dispatcher = coroutineContext[kotlin.coroutines.ContinuationInterceptor] as kotlinx.coroutines.CoroutineDispatcher)
        val channel = MockAndroidSecuredChannel()
        val release = kotlinx.coroutines.CompletableDeferred<Unit>()
        var attempts = 0
        var failed = true
        owner.available(channel)
        owner.handle(channel.descriptor, TransferMessage.capability().encode())
        val (batch, file) = offered(owner, channel, 100_000)
        channel.onSendData = { bytes ->
            if (TransferMessage.decode(bytes)?.kind == 6L) {
                attempts++
                release.await()
                // Bound the broken retry loop so a regression fails instead of hanging.
                if (failed && attempts < 8) throw java.io.IOException("Injected ACK failure")
            }
        }
        try {
            owner.acceptIncomingOffer(tempDir)
            withTimeout(2000) { while (owner.state !is TransferState.Transferring) delay(5) }
            repeat(8) { index -> owner.handle(channel.descriptor,
                TransferMessage.chunk(batch, file, index * 3072L, ByteArray(3072)).encode()) }
            withTimeout(2000) { while (attempts == 0) delay(5) }
            delay(30) // Let the previously scheduled ACK deadline fire while submission is held.
            release.complete(Unit)
            delay(60)
            assertEquals(1, attempts)
            failed = false
            owner.capacityAvailable(channel.descriptor)
            withTimeout(2000) { while (attempts < 2) delay(5) }
            assertEquals(2, attempts)
        } finally { release.complete(Unit); owner.dismiss() }
    }

    @Test fun cancellationRemovesUnsealedAckWithoutDamagingNextOffer() = runBlocking {
        val owner = TransferController(dispatcher = Dispatchers.Unconfined)
        val channel = MockAndroidSecuredChannel()
        val admission = SessionDataAdmission()
        val entered = kotlinx.coroutines.CompletableDeferred<Unit>()
        val release = kotlinx.coroutines.CompletableDeferred<Unit>()
        val active = launch {
            admission.run(true) { entered.complete(Unit); release.await() }
        }
        var submitted = false
        try {
            withTimeout(1000) { entered.await() }
            owner.available(channel)
            owner.handle(channel.descriptor, TransferMessage.capability().encode())
            val (batch, file) = offered(owner, channel, 100_000)
            channel.onSendData = { bytes ->
                if (TransferMessage.decode(bytes)?.kind == 6L) admission.run(false) { submitted = true }
            }
            owner.acceptIncomingOffer(tempDir)
            repeat(8) { index -> owner.handle(channel.descriptor,
                TransferMessage.chunk(batch, file, index * 3072L, ByteArray(3072)).encode()) }
            withTimeout(1000) { while (admission.pendingCount != 1) delay(1) }
            owner.cancelTransfer(local = false)
            withTimeout(1000) { while (admission.pendingCount != 0) delay(1) }
            assertEquals(TransferState.Cancelled, owner.state)
            offered(owner, channel, 1L)
            val next = owner.state
            release.complete(Unit); withTimeout(1000) { active.join() }
            assertFalse("Cancelled transfer ACK must not acquire a nonce later", submitted)
            assertEquals(next, owner.state)
            assertTrue(next is TransferState.IncomingOffer)
        } finally { release.complete(Unit); owner.dismiss(); active.cancel() }
    }

    @Test fun failedFinalizationCannotSendSuccess() = runBlocking {
        val owner = TransferController(dispatcher = Dispatchers.Unconfined)
        val channel = MockAndroidSecuredChannel()
        owner.available(channel)
        owner.handle(channel.descriptor, TransferMessage.capability().encode())
        val (batch, file) = offered(owner, channel, 1L)
        owner.acceptIncomingOffer(tempDir)
        val partial = tempDir.listFiles()!!.single { it.name.startsWith(".anice-") }
        assertTrue(partial.delete())
        owner.handle(channel.descriptor, TransferMessage.chunk(batch, file, 0, byteArrayOf(0)).encode())
        assertTrue(owner.state is TransferState.Failed)
        assertFalse(File(tempDir, "empty.bin").exists())
        assertFalse(channel.sentData.mapNotNull { TransferMessage.decode(it) }.any { it.kind == 7L && it.number(2) == 0L })
    }

    @Test fun inconsistentOfferTotalsAreDiscardedBeforeApproval() = runBlocking {
        val owner = TransferController(dispatcher = Dispatchers.Unconfined)
        val channel = MockAndroidSecuredChannel()
        owner.available(channel)
        val batch = UUID.randomUUID().toString()
        val row = Cbor.Array(listOf(Cbor.Text(UUID.randomUUID().toString()), Cbor.Text("a"), Cbor.Integer(1), Cbor.Bytes(ByteArray(32))))
        owner.handle(channel.descriptor, TransferMessage.offer(batch, 0, 1, 1, 2, listOf(row)).encode())
        assertEquals(TransferState.Idle, owner.state)
        val wrong = MockAndroidSecuredChannel(instance = "retired")
        assertEquals(io.github.anisharyal09.anice.infrastructure.connections.DataHandling.DISCARDED,
            owner.handle(wrong.descriptor, TransferMessage.offer(batch, 0, 1, 1, 1, listOf(row)).encode()))
        assertEquals(TransferState.Idle, owner.state)
    }

    @Test fun legacyPeerCannotStartTransferWithoutCapability() = runBlocking {
        val owner = TransferController(dispatcher = Dispatchers.Unconfined)
        val channel = MockAndroidSecuredChannel()
        owner.available(channel)
        val source = File(tempDir, "a").apply { writeText("a") }
        owner.sendFiles(listOf(source))
        assertTrue(owner.state is TransferState.Connecting)
        assertFalse(channel.sentData.mapNotNull { TransferMessage.decode(it) }.any { it.kind == 2L })
        owner.onLanUnavailable("This peer has not advertised file transfer support")
        assertTrue(owner.state is TransferState.Failed)
        owner.dismiss()
    }

    @Test fun emptyFileCompletesAndKeepsUnrelatedPartial() = runBlocking {
        val owner = TransferController(dispatcher = Dispatchers.Unconfined)
        val channel = MockAndroidSecuredChannel()
        owner.available(channel)
        owner.handle(channel.descriptor, TransferMessage.capability().encode())
        offered(owner, channel)
        val unrelated = File(tempDir, "empty.bin.anice-part").apply { writeText("keep") }
        owner.acceptIncomingOffer(tempDir)
        repeat(50) { if (owner.state !is TransferState.Completed) delay(10) }
        assertTrue(owner.state is TransferState.Completed)
        assertEquals(0L, File(tempDir, "empty.bin").length())
        assertEquals("keep", unrelated.readText())
    }

    @Test fun failedDestinationNeverAcceptsOrReportsSuccess() = runBlocking {
        val owner = TransferController(dispatcher = Dispatchers.Unconfined)
        val channel = MockAndroidSecuredChannel()
        owner.available(channel)
        owner.handle(channel.descriptor, TransferMessage.capability().encode())
        offered(owner, channel)
        val blocked = File(tempDir, "not-a-folder").apply { writeText("keep") }
        owner.acceptIncomingOffer(blocked)
        assertTrue(owner.state is TransferState.Failed)
        assertFalse(channel.sentData.mapNotNull { TransferMessage.decode(it) }.any { it.kind == 3L || it.kind == 7L && it.number(2) == 0L })
        assertEquals("keep", blocked.readText())
    }

    @Test fun unrelatedBatchResultAndCancelDoNotChangeCurrentOffer() = runBlocking {
        val owner = TransferController(dispatcher = Dispatchers.Unconfined)
        val channel = MockAndroidSecuredChannel()
        owner.available(channel)
        owner.handle(channel.descriptor, TransferMessage.capability().encode())
        offered(owner, channel, 1L)
        val before = owner.state
        owner.handle(channel.descriptor, TransferMessage.batchResult(UUID.randomUUID().toString(), 0).encode())
        owner.handle(channel.descriptor, TransferMessage.cancel(UUID.randomUUID().toString()).encode())
        assertEquals(before, owner.state)
    }

    @Test
    fun testOfferAcceptStreamAndVerifyBatch() = verifyBatch("lan")

    @Test fun bleFallbackStreamsAndVerifiesBatch() = verifyBatch("ble")


    @Test fun largeLanCreditBoundsBacklogWithoutShrinkingRecords() = runBlocking {
        val owner = TransferController(dispatcher = coroutineContext[kotlin.coroutines.ContinuationInterceptor] as kotlinx.coroutines.CoroutineDispatcher)
        val channel = MockAndroidSecuredChannel(maximumDataBytes = 262144)
        owner.available(channel)
        owner.handle(channel.descriptor, TransferMessage.capability(3, 262016, 8).encode(262016))
        val source = File(tempDir, "credit.bin").apply { writeBytes(ByteArray(8 * 262016 + 7)) }
        fun chunks() = channel.sentData.mapNotNull { TransferMessage.decode(it, 262016) }.filter { it.kind == 5L }
        try {
            owner.sendFiles(listOf(source))
            withTimeout(3000) { while (owner.state !is TransferState.WaitingForPeerApproval) delay(5) }
            val batch = (owner.state as TransferState.WaitingForPeerApproval).batch
            owner.handle(channel.descriptor, TransferMessage.accept(batch.id).encode())
            withTimeout(3000) { while (chunks().size < 8) delay(5) }
            delay(60)
            assertEquals("The sender must use the full negotiated eight-chunk window", 8, chunks().size)
            assertTrue(chunks().all { it.bytes(3).size == 262016 })
            owner.handle(channel.descriptor, TransferMessage.ack(batch.id, batch.files[0].id, 1).encode())
            delay(60)
            assertEquals("Partial ACK cannot admit a whole chunk beyond the byte budget", 8, chunks().size)
            owner.handle(channel.descriptor, TransferMessage.ack(batch.id, batch.files[0].id, 9L * 262016 + 1).encode())
            delay(60)
            assertEquals("Unsubmitted bytes cannot grant credit", 8, chunks().size)
            owner.handle(channel.descriptor, TransferMessage.ack(batch.id, batch.files[0].id, 2L * 262016).encode())
            withTimeout(3000) { while (chunks().size < 9) delay(5) }
            delay(60)
            assertEquals(9, chunks().size)
            assertEquals((0L until 9L).map { it * 262016 }, chunks().map { it.number(2) })
            assertTrue(source.exists())
        } finally { owner.dismiss() }
    }

    @Test fun largerLanChunksStreamAcrossCreditWindows() = verifyBatch("lan", 262016)

    private fun verifyBatch(transport: String, maximumChunkBytes: Int = 3072) = runBlocking {
        val maximumDataBytes = if (maximumChunkBytes > 3072) 262144 else 4000
        val version = when { maximumChunkBytes > 131072 -> 3; maximumChunkBytes > 3072 -> 2; else -> 1 }
        val capability = TransferMessage.capability(version.toLong(), maximumChunkBytes.toLong(), if (maximumChunkBytes > 3072) 8 else 64).encode(maximumChunkBytes)
        val sender = TransferController(dispatcher = Dispatchers.Unconfined)
        val receiver = TransferController(dispatcher = Dispatchers.Unconfined)

        val senderChannel = MockAndroidSecuredChannel(maximumDataBytes = maximumDataBytes, transport = transport, deviceName = "Phone")
        val receiverChannel = MockAndroidSecuredChannel(maximumDataBytes = maximumDataBytes, transport = transport, deviceName = "MacBook")

        sender.available(senderChannel)

        sender.handle(senderChannel.descriptor, capability)
        receiver.available(receiverChannel)
        receiver.handle(receiverChannel.descriptor, capability)

        senderChannel.onSendData = { data ->
            receiver.handle(receiverChannel.descriptor, data)
        }
        receiverChannel.onSendData = { data ->
            sender.handle(senderChannel.descriptor, data)
        }

        // Create 10 KiB sample file
        val testFile = File(tempDir, "sample.bin")
        val testData = ByteArray(if (maximumChunkBytes > 3072) 2097169 else 10240) { (it % 251).toByte() }
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
        assertEquals(testData.size.toLong(), offerState.batch.files[0].size)

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

        if (maximumChunkBytes > 3072) {
            val chunks = senderChannel.sentData.mapNotNull { TransferMessage.decode(it, maximumChunkBytes) }.filter { it.kind == 5L }
            assertFalse(chunks.isEmpty())
            assertEquals(maximumChunkBytes, chunks.first().bytes(3).size)
            assertTrue(chunks.all { it.bytes(3).size in 1..maximumChunkBytes })
        }

        val partFile = File(destFolder, "sample.bin.anice-part")
        assertFalse("Temporary part file was not removed", partFile.exists())
    }

    @Test
    fun testAdversarialHashMismatchFailsAndDeletesPartialFile() = runBlocking {
        val receiver = TransferController(dispatcher = Dispatchers.Unconfined)
        val receiverChannel = MockAndroidSecuredChannel(deviceName = "MacBook")
        receiver.available(receiverChannel)
        receiver.handle(receiverChannel.descriptor, TransferMessage.capability().encode())

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
        receiver.handle(receiverChannel.descriptor, TransferMessage.capability().encode())

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
        receiver.handle(receiverChannel.descriptor, TransferMessage.capability().encode())

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
        sender.handle(senderChannel.descriptor, TransferMessage.capability().encode())

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

        sender.handle(senderChannel.descriptor, TransferMessage.ack(UUID.randomUUID().toString(), fileIdStr, Long.MAX_VALUE).encode())
        sender.handle(senderChannel.descriptor, TransferMessage.ack(batchIdStr, fileIdStr, totalSize.toLong() + 1).encode())
        sender.handle(senderChannel.descriptor, TransferMessage.batchResult(batchIdStr, 0).encode())
        delay(30)
        assertEquals("Wrong/future ACK must not release credit", 64, sentChunkCount)
        assertFalse(sender.state is TransferState.Completed)

        // Peer sends ack for 64 chunks
        val ackMsg = TransferMessage.ack(batch = batchIdStr, file = fileIdStr, written = 64 * 3072L)
        sender.handle(senderChannel.descriptor, ackMsg.encode())

        // Sender resumes
        for (i in 0 until 50) {
            if (sentChunkCount > 64) break
            delay(10)
        }

        assertTrue("Sender should have resumed after ack", sentChunkCount > 64)

        // Results are valid only after the final chunk has been submitted.
        for (i in 0 until 100) {
            if (sentChunkCount == (totalSize + 3071) / 3072) break
            delay(10)
        }
        assertEquals((totalSize + 3071) / 3072, sentChunkCount)
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

        sender.handle(senderChannel.descriptor, TransferMessage.capability().encode())
        receiver.available(receiverChannel)
        receiver.handle(receiverChannel.descriptor, TransferMessage.capability().encode())

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

    @Test
    fun testReceiverAccurateCumulativeProgressAcrossThrottleBoundaries() = runBlocking {
        val receiver = TransferController(dispatcher = Dispatchers.Unconfined)
        val receiverChannel = MockAndroidSecuredChannel(deviceName = "MacBook")
        receiver.available(receiverChannel)
        receiver.handle(receiverChannel.descriptor, TransferMessage.capability().encode())

        val batchId = UUID.randomUUID().toString()
        val fileId = UUID.randomUUID().toString()
        val chunkSize = 3072
        val chunkCount = 4
        val totalBytes = chunkSize * chunkCount
        val fileBytes = ByteArray(totalBytes) { (it % 251).toByte() }
        val fileHash = MessageDigest.getInstance("SHA-256").digest(fileBytes)

        val offer = TransferMessage.offer(
            batch = batchId,
            sliceIndex = 0L,
            totalSlices = 1L,
            totalFiles = 1L,
            totalBytes = totalBytes.toLong(),
            files = listOf(
                Cbor.Array(
                    listOf(
                        Cbor.Text(fileId),
                        Cbor.Text("rapid.bin"),
                        Cbor.Integer(totalBytes.toLong()),
                        Cbor.Bytes(fileHash)
                    )
                )
            )
        )
        receiver.handle(receiverChannel.descriptor, offer.encode())

        val destFolder = File(tempDir, "downloads")
        destFolder.mkdirs()
        receiver.acceptIncomingOffer(destFolder)

        for (i in 0 until chunkCount) {
            val offset = (i * chunkSize).toLong()
            val chunkData = fileBytes.copyOfRange(i * chunkSize, (i + 1) * chunkSize)
            val chunkMsg = TransferMessage.chunk(
                batch = batchId,
                file = fileId,
                offset = offset,
                data = chunkData
            )
            receiver.handle(receiverChannel.descriptor, chunkMsg.encode())
        }

        when (val state = receiver.state) {
            is TransferState.Completed -> {
                assertEquals(1, state.fileCount)
                assertEquals(totalBytes.toLong(), state.totalBytes)
            }
            is TransferState.Transferring -> {
                assertEquals(totalBytes.toLong(), state.totalBytes)
                // A rate needs two observations separated in time. This burst completes inside one
                // 100 ms UI interval, so there is genuinely no rate to report, and reporting a
                // lifetime average here is exactly the drift the rolling window replaced.
                assertEquals(0.0, state.speedBps, 0.0)
            }
            else -> fail("Unexpected receiver state: ${receiver.state}")
        }

        val receivedFile = File(destFolder, "rapid.bin")
        assertTrue(receivedFile.exists())
        assertArrayEquals(fileBytes, receivedFile.readBytes())
    }

    @Test
    fun aTakenDestinationNameStreamsToASuffixedNameWithoutFailingTheBatch() = runBlocking {
        val sender = TransferController(dispatcher = Dispatchers.Unconfined)
        val receiver = TransferController(dispatcher = Dispatchers.Unconfined)
        val senderChannel = MockAndroidSecuredChannel(transport = "lan", deviceName = "Phone")
        val receiverChannel = MockAndroidSecuredChannel(transport = "lan", deviceName = "MacBook")
        val capability = TransferMessage.capability().encode()

        sender.available(senderChannel)
        sender.handle(senderChannel.descriptor, capability)
        receiver.available(receiverChannel)
        receiver.handle(receiverChannel.descriptor, capability)
        senderChannel.onSendData = { receiver.handle(receiverChannel.descriptor, it) }
        receiverChannel.onSendData = { sender.handle(senderChannel.descriptor, it) }

        val testFile = File(tempDir, "sample.bin")
        val testData = ByteArray(10240) { (it % 251).toByte() }
        testFile.writeBytes(testData)

        val destFolder = File(tempDir, "downloads")
        destFolder.mkdirs()
        // The destination already holds the advertised name and the first suffixed name.
        File(destFolder, "sample.bin").writeBytes(byteArrayOf(9, 9, 9))
        File(destFolder, "sample (1).bin").writeBytes(byteArrayOf(8, 8))

        sender.sendFiles(listOf(testFile))
        for (i in 0 until 50) {
            if (receiver.state is TransferState.IncomingOffer) break
            delay(10)
        }
        receiver.acceptIncomingOffer(destFolder)

        var completed = false
        for (i in 0 until 100) {
            if (sender.state is TransferState.Completed && receiver.state is TransferState.Completed) {
                completed = true
                break
            }
            delay(20)
        }
        assertTrue("Batch failed on a taken name: sender=${sender.state}, receiver=${receiver.state}", completed)
        assertArrayEquals(
            "An existing file was overwritten",
            byteArrayOf(9, 9, 9),
            File(destFolder, "sample.bin").readBytes(),
        )
        assertArrayEquals(byteArrayOf(8, 8), File(destFolder, "sample (1).bin").readBytes())
        assertArrayEquals(testData, File(destFolder, "sample (2).bin").readBytes())
    }

    @Test
    fun transferDirectionIsObservableAndSurvivesCompletion() = runBlocking {
        val sender = TransferController(dispatcher = Dispatchers.Unconfined)
        val receiver = TransferController(dispatcher = Dispatchers.Unconfined)
        val senderChannel = MockAndroidSecuredChannel(transport = "lan", deviceName = "MacBook Pro")
        val receiverChannel = MockAndroidSecuredChannel(transport = "lan", deviceName = "Phone")
        val capability = TransferMessage.capability().encode()

        sender.available(senderChannel)
        sender.handle(senderChannel.descriptor, capability)
        receiver.available(receiverChannel)
        receiver.handle(receiverChannel.descriptor, capability)
        senderChannel.onSendData = { receiver.handle(receiverChannel.descriptor, it) }
        receiverChannel.onSendData = { sender.handle(senderChannel.descriptor, it) }

        // No batch exists yet, so neither side may claim a direction.
        assertFalse(sender.receiving)
        assertFalse(receiver.receiving)

        val testFile = File(tempDir, "direction.bin")
        testFile.writeBytes(ByteArray(12288) { (it % 251).toByte() })

        sender.sendFiles(listOf(testFile))
        for (i in 0 until 50) {
            if (receiver.state is TransferState.IncomingOffer) break
            delay(10)
        }
        assertTrue("Expected IncomingOffer: ${receiver.state}", receiver.state is TransferState.IncomingOffer)
        assertFalse("An unapproved offer must not claim the receiving direction", receiver.receiving)

        val destFolder = File(tempDir, "downloads")
        destFolder.mkdirs()
        receiver.acceptIncomingOffer(destFolder)

        var completed = false
        for (i in 0 until 100) {
            if (sender.state is TransferState.Completed && receiver.state is TransferState.Completed) {
                completed = true
                break
            }
            delay(20)
        }
        assertTrue("Batch did not complete: sender=${sender.state}, receiver=${receiver.state}", completed)

        // The completed panel still reports which way the files moved, so the direction has to
        // outlive the cleanup that runs immediately after the completed state is published.
        assertTrue("Receiver lost its direction at completion", receiver.receiving)
        assertFalse("Sender claimed the receiving direction", sender.receiving)
        assertFalse(receiver.finalizing)
        assertFalse(sender.finalizing)

        receiver.dismiss()
        assertFalse("Dismiss must clear the recorded direction", receiver.receiving)
    }

    @Test
    fun finalizationIsReportedOnlyWhileAFullyReceivedFilePublishes() = runBlocking {
        val sender = TransferController(dispatcher = Dispatchers.Unconfined)
        val receiver = TransferController(dispatcher = Dispatchers.Unconfined)
        val senderChannel = MockAndroidSecuredChannel(transport = "lan", deviceName = "MacBook Pro")
        val receiverChannel = MockAndroidSecuredChannel(transport = "lan", deviceName = "Phone")
        val capability = TransferMessage.capability().encode()

        sender.available(senderChannel)
        sender.handle(senderChannel.descriptor, capability)
        receiver.available(receiverChannel)
        receiver.handle(receiverChannel.descriptor, capability)
        senderChannel.onSendData = { receiver.handle(receiverChannel.descriptor, it) }
        receiverChannel.onSendData = { sender.handle(senderChannel.descriptor, it) }

        // Every published state must agree with the finalization flag: a panel that claims to be
        // verifying and saving is only truthful once the whole file has landed.
        var reported = 0
        val disagreements = mutableListOf<String>()
        receiver.onStateChanged = { published ->
            if (receiver.finalizing) {
                reported++
                val transferring = published as? TransferState.Transferring
                if (transferring == null || transferring.fileBytes < transferring.fileSize) {
                    disagreements.add(published.toString())
                }
            }
        }

        val testFile = File(tempDir, "publishing.bin")
        testFile.writeBytes(ByteArray(6144) { (it % 251).toByte() })

        sender.sendFiles(listOf(testFile))
        for (i in 0 until 50) {
            if (receiver.state is TransferState.IncomingOffer) break
            delay(10)
        }
        val destFolder = File(tempDir, "downloads")
        destFolder.mkdirs()
        receiver.acceptIncomingOffer(destFolder)

        var completed = false
        for (i in 0 until 100) {
            if (receiver.state is TransferState.Completed) {
                completed = true
                break
            }
            delay(20)
        }
        assertTrue("Batch did not complete: receiver=${receiver.state}", completed)
        assertTrue("Finalization was never observable", reported > 0)
        assertTrue("Finalization reported without a fully received file: $disagreements", disagreements.isEmpty())
        assertFalse("Finalization outlived the batch", receiver.finalizing)
    }
}
