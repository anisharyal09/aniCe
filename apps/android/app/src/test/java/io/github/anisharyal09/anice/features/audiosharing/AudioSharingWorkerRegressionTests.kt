// SPDX-License-Identifier: GPL-3.0-or-later
// Exercises channel fencing and bounded audio admission while the presentation scheduler is blocked.
package io.github.anisharyal09.anice.features.audiosharing

import io.github.anisharyal09.anice.infrastructure.connections.*
import io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test

class AudioSharingWorkerRegressionTests {
    @Test fun aBlockedUiDoesNotBlockCurrentPcmOrReviveItAfterStop() = runBlocking {
        val executor = java.util.concurrent.Executors.newSingleThreadExecutor().asCoroutineDispatcher()
        val gate = java.util.concurrent.CountDownLatch(1)
        val entered = CompletableDeferred<Unit>()
        val scope = CoroutineScope(SupervisorJob() + executor)
        val id = "01234567-89ab-4cde-8fab-0123456789ab"
        var clock = 1000L
        val controller = AudioSharingController(now = { clock }, dispatcher = executor, automaticTicks = false)
        val channel = object : SecuredChannel {
            override val descriptor = ChannelDescriptor("active", "lan", DeviceIdentity(
                "mac", "Mac", "macos", "key", "fingerprint"))
            override suspend fun sendData(bytes: ByteArray) {}
        }
        val offers = java.util.concurrent.atomic.AtomicInteger()
        val output = object : AudioSharingOutput {
            override fun offer(message: AudioSharingMessage): Boolean { offers.incrementAndGet(); return true }
            override fun pause() {}
            override suspend fun resume() {}
            override fun close() {}
        }
        try {
            withContext(executor) {
                controller.loadLocalFingerprint = { "local" }
                controller.startupAllowed = { true }
                controller.startService = {
                    controller.serviceAttached(it, this, output)
                    controller.ready(it)
                }
                controller.available(channel)
            }
            withContext(executor) {
                controller.setConsent(true)
                controller.handle(channel.descriptor, AudioSharingMessage.start(id).encode())
                assertTrue(controller.active)
            }
            val blocked = scope.launch { entered.complete(Unit); gate.await() }
            entered.await()
            withContext(Dispatchers.Default) {
                for (sequence in 1L..50) {
                    clock += 20
                    assertEquals(DataHandling.HANDLED, controller.handleOnWorker(channel.descriptor,
                        AudioSharingMessage.audio(id, sequence, ByteArray(3840)).encode()))
                }
            }
            assertEquals(50, offers.get())
            gate.countDown(); blocked.join()
            withContext(executor) { controller.stop() }
            assertEquals(DataHandling.DISCARDED, controller.handleOnWorker(channel.descriptor,
                AudioSharingMessage.audio(id, 51, ByteArray(3840)).encode()))
            assertEquals(50, offers.get())
        } finally { gate.countDown(); scope.cancel(); executor.close() }
    }
}
