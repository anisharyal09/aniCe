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
    val sentData = mutableListOf<ByteArray>()
    var onSendData: (suspend (ByteArray) -> Unit)? = null

    override suspend fun sendData(bytes: ByteArray) {
        sentData.add(bytes)
        onSendData?.invoke(bytes)
    }
}

class TransferControllerTests {
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
        assertSame(lan, owner.activeChannel)
        assertFalse(owner.peerCompatible)
        owner.retired(ble.descriptor)
        assertSame(lan, owner.activeChannel)
        owner.handle(lan.descriptor, TransferMessage.capability().encode())
        val successor = MockAndroidSecuredChannel(instance = "successor")
        owner.available(successor)
        assertFalse(owner.peerCompatible)
        owner.handle(lan.descriptor, TransferMessage.capability().encode())
        assertFalse(owner.peerCompatible)
        owner.dismiss()
    }

    @Test fun lanLossRetiresPartialAndRejectsOldChunksBeforeBleRetry() = runBlocking {
        val owner = TransferController(dispatcher = Dispatchers.Unconfined)
        val lan = MockAndroidSecuredChannel(instance = "lan")
        val ble = MockAndroidSecuredChannel(instance = "ble", transport = "ble")
        listOf(lan, ble).forEach { owner.available(it); owner.handle(it.descriptor, TransferMessage.capability().encode()) }
        val (batch, file) = offered(owner, lan, 10)
        owner.acceptIncomingOffer(tempDir)
        owner.handle(lan.descriptor, TransferMessage.chunk(batch, file, 0, byteArrayOf(0)).encode())
        owner.retired(lan.descriptor)
        assertTrue(owner.state is TransferState.Failed)
        assertSame(ble, owner.activeChannel)
        assertTrue(owner.peerCompatible)
        kotlinx.coroutines.withTimeout(2000) { while (tempDir.listFiles()!!.isNotEmpty()) delay(5) }
        assertTrue(tempDir.listFiles()!!.isEmpty())
        owner.handle(lan.descriptor, TransferMessage.chunk(batch, file, 1, ByteArray(9)).encode())
        assertTrue(owner.state is TransferState.Failed)
        offered(owner, ble)
        assertTrue(owner.state is TransferState.IncomingOffer)
        owner.dismiss()
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

    @Test fun explicitSendAcquiresOwnershipBeforeHashingAndReleasesItOnCancel() = runBlocking {
        val owner = TransferController(dispatcher = Dispatchers.Unconfined)
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

    @Test fun cancellationDoesNotCancelSubmittedAckOrDamageNextOffer() = runBlocking {
        val owner = TransferController(dispatcher = Dispatchers.Unconfined)
        val channel = MockAndroidSecuredChannel()
        owner.available(channel)
        owner.handle(channel.descriptor, TransferMessage.capability().encode())
        val (batch, file) = offered(owner, channel, 100_000)
        val release = kotlinx.coroutines.CompletableDeferred<Unit>()
        val started = kotlinx.coroutines.CompletableDeferred<Unit>()
        var cancelled = false
        channel.onSendData = { bytes ->
            if (TransferMessage.decode(bytes)?.kind == 6L) {
                started.complete(Unit)
                try { release.await() } catch (error: kotlinx.coroutines.CancellationException) { cancelled = true; throw error }
            }
        }
        owner.acceptIncomingOffer(tempDir)
        repeat(8) { index -> owner.handle(channel.descriptor, TransferMessage.chunk(batch, file, index * 3072L, ByteArray(3072)).encode()) }
        kotlinx.coroutines.withTimeout(1000) { started.await() }
        owner.cancelTransfer(local = false)
        owner.handle(channel.descriptor, TransferMessage.chunk(batch, file, 8 * 3072L, ByteArray(3072)).encode())
        assertEquals(TransferState.Cancelled, owner.state)
        offered(owner, channel, 1L)
        val next = owner.state
        release.complete(Unit)
        delay(20)
        assertFalse("Logical cancellation must not cancel an already-submitted record", cancelled)
        assertEquals(next, owner.state)
        assertTrue(next is TransferState.IncomingOffer)
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
        assertTrue(owner.state is TransferState.Failed)
        assertFalse(channel.sentData.mapNotNull { TransferMessage.decode(it) }.any { it.kind == 2L })
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


    @Test fun largerLanChunksStreamAcrossCreditWindows() = verifyBatch("lan", 131072)

    private fun verifyBatch(transport: String, maximumChunkBytes: Int = 3072) = runBlocking {
        val maximumDataBytes = if (maximumChunkBytes > 3072) 262144 else 4000
        val capability = TransferMessage.capability(if (maximumChunkBytes > 3072) 2 else 1, maximumChunkBytes.toLong(), if (maximumChunkBytes > 3072) 8 else 64).encode(maximumChunkBytes)
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

        if (maximumChunkBytes > 3072) assertTrue(senderChannel.sentData.mapNotNull { TransferMessage.decode(it, maximumChunkBytes) }.any { it.kind == 5L && it.bytes(3).size == 131072 })

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
                assertTrue(state.speedBps > 0)
            }
            else -> fail("Unexpected receiver state: ${receiver.state}")
        }

        val receivedFile = File(destFolder, "rapid.bin")
        assertTrue(receivedFile.exists())
        assertArrayEquals(fileBytes, receivedFile.readBytes())
    }
}
