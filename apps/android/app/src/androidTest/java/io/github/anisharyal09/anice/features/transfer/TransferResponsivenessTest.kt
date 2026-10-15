// SPDX-License-Identifier: GPL-3.0-or-later
// Verifies real file storage avoids Android's main thread while preserving bytes and completion ordering.
package io.github.anisharyal09.anice.features.transfer

import android.os.StrictMode
import androidx.test.platform.app.InstrumentationRegistry
import io.github.anisharyal09.anice.infrastructure.connections.*
import io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity
import io.github.anisharyal09.anice.infrastructure.session.Cbor
import java.io.File
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test

class TransferResponsivenessTest {
    @Test fun nativeStorageNeverReportsSuccessOnPublicationDenial() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val folder = File(context.cacheDir, "transfer-storage-${UUID.randomUUID()}").apply { mkdirs() }
        val storage = TransferReceiveStorage(folder, null)
        try {
            val partial = storage.create(UUID.randomUUID().toString(), UUID.randomUUID().toString()).first!!
            storage.write(byteArrayOf(1, 2, 3))
            try {
                storage.finish("received.bin", MessageDigest.getInstance("SHA-256").digest(byteArrayOf(1, 2, 3)))
                assertArrayEquals(byteArrayOf(1, 2, 3), File(folder, "received.bin").readBytes())
            } catch (error: java.io.IOException) {
                assertTrue(error.cause is java.nio.file.AccessDeniedException)
                storage.discard()
                assertArrayEquals(byteArrayOf(1, 2, 3), partial.readBytes())
                assertFalse(File(folder, "received.bin").exists())
            }
        } finally { storage.discard(); folder.deleteRecursively() }
    }

    @Test fun receiveStorageDoesNotPerformMainThreadDiskIo() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val folder = File(context.cacheDir, "transfer-responsive-${UUID.randomUUID()}").apply { mkdirs() }
        val data = ByteArray(2 * 1048576 + 17) { (it % 251).toByte() }
        val hash = MessageDigest.getInstance("SHA-256").digest(data)
        val batch = UUID.randomUUID().toString(); val file = UUID.randomUUID().toString()
        val peer = DeviceIdentity("00000000-0000-4000-8000-000000000001", "Test Mac", "macos", "mock", "mock")
        val replies = CopyOnWriteArrayList<TransferMessage>()
        val violations = CopyOnWriteArrayList<String>()
        val listener = Executors.newSingleThreadExecutor()
        val owner = TransferController(dispatcher = Dispatchers.Main.immediate)
        val channel = object : SecuredChannel {
            override val descriptor = ChannelDescriptor("responsive", "lan", peer, 262144)
            override suspend fun sendData(bytes: ByteArray) { TransferMessage.decode(bytes, 131072)?.let(replies::add) }
        }
        var previous: StrictMode.ThreadPolicy? = null
        try {
            withContext(Dispatchers.Main) {
                previous = StrictMode.getThreadPolicy()
                StrictMode.setThreadPolicy(StrictMode.ThreadPolicy.Builder().detectDiskReads().detectDiskWrites()
                    .penaltyListener(listener) { violations.add(it.javaClass.simpleName) }.build())
                owner.available(channel)
                owner.handle(channel.descriptor, TransferMessage.capability(2, 131072, 8).encode(131072))
                owner.handle(channel.descriptor, TransferMessage.offer(batch, 0, 1, 1, data.size.toLong(), listOf(
                    Cbor.Array(listOf(Cbor.Text(file), Cbor.Text("received.bin"), Cbor.Integer(data.size.toLong()), Cbor.Bytes(hash)))
                )).encode())
                owner.acceptIncomingOffer(folder)
                assertTrue("Acceptance failed: ${owner.state}", owner.state is TransferState.Transferring)
            }
            var offset = 0
            while (offset < data.size) {
                val end = minOf(offset + 131072, data.size)
                val message = TransferMessage.chunk(batch, file, offset.toLong(), data.copyOfRange(offset, end)).encode(131072)
                withContext(Dispatchers.Main) {
                    owner.handle(channel.descriptor, message)
                    (owner.state as? TransferState.Failed)?.let {
                        assertTrue(it.reason, it.reason.contains("Destination cannot publish files exclusively"))
                    }
                }
                offset = end
            }
            withTimeout(10000) {
                while (withContext(Dispatchers.Main) {
                    owner.state !is TransferState.Completed && owner.state !is TransferState.Failed
                }) delay(10)
            }
            val state = withContext(Dispatchers.Main) { owner.state }
            if (state is TransferState.Completed) {
                assertArrayEquals(data, File(folder, "received.bin").readBytes())
                assertTrue(replies.any { it.kind == 7L && it.number(2) == 0L && it.bytes(3).contentEquals(hash) })
            } else {
                assertTrue(state.toString(), state is TransferState.Failed && state.reason.contains("Destination cannot publish files exclusively"))
                assertArrayEquals(data, folder.listFiles()!!.single { it.name.endsWith(".part") }.readBytes())
                assertFalse(replies.any { it.kind == 7L && it.number(2) == 0L })
            }
            // Drain StrictMode's listener before evaluating its independently collected violations.
            listener.submit {}.get()
            assertEquals(emptyList<String>(), violations.toList())
        } finally {
            withContext(Dispatchers.Main) { previous?.let(StrictMode::setThreadPolicy); owner.dismiss() }
            listener.shutdown()
            folder.deleteRecursively()
        }
    }
}
