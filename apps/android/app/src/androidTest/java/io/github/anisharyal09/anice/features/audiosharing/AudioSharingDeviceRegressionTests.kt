// SPDX-License-Identifier: GPL-3.0-or-later
// Checks native scheduling and installed service boundaries with non-playback queries and isolated controller fakes.
package io.github.anisharyal09.anice.features.audiosharing

import io.github.anisharyal09.anice.features.privatelistening.PrivateListeningService
import android.content.ComponentName
import android.content.pm.ServiceInfo
import android.media.AudioFormat
import android.media.AudioTrack
import android.os.Looper
import android.os.Process
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.github.anisharyal09.anice.infrastructure.connections.ChannelDescriptor
import io.github.anisharyal09.anice.infrastructure.connections.DataHandling
import io.github.anisharyal09.anice.infrastructure.connections.SecuredChannel
import io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AudioSharingDeviceRegressionTests {
    private fun previewContext() = InstrumentationRegistry.getInstrumentation().targetContext.also {
        assumeTrue("Requires the explicitly selected isolated Transfer Preview",
            it.packageName == "io.github.anisharyal09.anice.preview.transfer")
    }

    @Suppress("DEPRECATION")
    @Test fun installedListeningServiceIsPrivateAndMediaPlaybackScoped() {
        val context = previewContext()
        val service = context.packageManager.getServiceInfo(
            ComponentName(context, PrivateListeningService::class.java), 0)
        assertFalse("External callers must not open headphone playback", service.exported)
        assertEquals(ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK, service.foregroundServiceType)
    }

    @Test fun audioWorkerUsesOneNativeAudioPriorityThreadAndReleasesIt() = runBlocking {
        previewContext()
        val worker = AudioSharingAudioWorker()
        var thread: Thread? = null
        var tid: Int? = null
        try {
            withTimeout(5000) {
                repeat(16) {
                    withContext(worker.dispatcher) {
                        val current = Thread.currentThread()
                        assertNotSame(Looper.getMainLooper().thread, current)
                        if (thread == null) { thread = current; tid = Process.myTid() }
                        assertSame(thread, current)
                        assertEquals(tid, Process.myTid())
                        assertEquals("Verify the accepted native scheduling hint, not only the thread name",
                            Process.THREAD_PRIORITY_AUDIO, Process.getThreadPriority(Process.myTid()))
                    }
                }
            }
        } finally {
            worker.close()
            thread?.join(5000)
        }
        assertNotNull(thread)
        assertFalse("Closing a service worker must release its native thread", requireNotNull(thread).isAlive)
    }

    @Test fun platformPcmBufferQueryFitsTheBudgetWithoutOpeningAnAudioTrack() {
        previewContext()
        // This static platform query creates no track, requests no focus and plays no audio.
        val bytes = AudioTrack.getMinBufferSize(48000, AudioFormat.CHANNEL_OUT_STEREO,
            AudioFormat.ENCODING_PCM_16BIT)
        assertTrue("The actual platform must support the wire PCM format", bytes > 0)
        assertEquals(0, bytes % 4)
        assertTrue(bytes / 4 <= AudioSharingNativeBufferPolicy.MAXIMUM_NATIVE_FRAMES)
        // This is format/startup feasibility, not the effective Bluetooth buffer or output latency.
    }

    @Test fun credentialConsentAndStopFenceWorkerAdmissionWithoutNativePlayback() = runBlocking {
        previewContext()
        val runner = InstrumentationRegistry.getInstrumentation()
        val channel = object : SecuredChannel {
            override val descriptor = ChannelDescriptor("device-regression", "lan", DeviceIdentity(
                "01234567-89ab-4cde-8fab-0123456789ab", "Fixture Mac", "macos", "fixture-key", "a".repeat(64)))
            override suspend fun sendData(bytes: ByteArray) { AudioSharingMessage.decode(bytes) }
        }
        val outputOffers = AtomicInteger()
        val outputCloses = AtomicInteger()
        val output = object : AudioSharingOutput {
            override fun offer(message: AudioSharingMessage): Boolean {
                outputOffers.incrementAndGet()
                return true
            }
            override fun pause() {}
            override suspend fun resume() {}
            override fun close() { outputCloses.incrementAndGet() }
        }
        val owner = Any()
        lateinit var controller: AudioSharingController
        var ticket: AudioSharingRequest? = null
        var starts = 0
        val refusedId = "01234567-89ab-4cde-8fab-0123456789ac"
        val activeId = "01234567-89ab-4cde-8fab-0123456789ad"
        runner.runOnMainSync {
            controller = AudioSharingController(automaticTicks = false)
            controller.loadLocalFingerprint = { "b".repeat(64) }
            controller.startupAllowed = { true }
            // The fake owns no Android service, device, persisted preference or authenticated channel.
            controller.startService = {
                starts++
                ticket = it
                assertTrue(controller.serviceAttached(it, owner, output))
                controller.ready(it)
            }
            controller.available(channel)
        }
        try {
            withContext(Dispatchers.Main) {
                assertTrue(controller.consentEnabled)
                controller.setConsent(false)
                assertFalse(controller.consentEnabled)
                controller.handle(channel.descriptor, AudioSharingMessage.start(refusedId).encode())
                assertEquals(0, starts)
                val differentMac = channel.descriptor.copy(peer = channel.descriptor.peer.copy(publicKey = "changed-key"))
                controller.handle(differentMac, AudioSharingMessage.start(activeId).encode())
                assertEquals(0, starts)
                controller.setConsent(true) // In-memory fixture preferences only.
                controller.handle(channel.descriptor, AudioSharingMessage.start(refusedId).encode())
                assertEquals(0, starts)
                controller.handle(channel.descriptor, AudioSharingMessage.start(activeId).encode())
                assertEquals(1, starts)
                assertTrue(controller.active)
            }
            val packet = AudioSharingMessage.audio(activeId, 1, ByteArray(3840)).encode()
            withContext(Dispatchers.Default) {
                assertEquals(DataHandling.DISCARDED,
                    controller.handleOnWorker(channel.descriptor.copy(instance = "retired"), packet))
                assertEquals(DataHandling.HANDLED, controller.handleOnWorker(channel.descriptor, packet))
                assertEquals(DataHandling.DISCARDED, controller.handleOnWorker(channel.descriptor, packet))
            }
            withContext(Dispatchers.Main) {
                controller.stop(notify = false)
                controller.ready(requireNotNull(ticket))
                assertFalse(controller.active)
                controller.serviceDestroyed(requireNotNull(ticket), owner)
            }
            withContext(Dispatchers.Default) {
                assertEquals(DataHandling.DISCARDED, controller.handleOnWorker(channel.descriptor,
                    AudioSharingMessage.audio(activeId, 2, ByteArray(3840)).encode()))
            }
            assertEquals(1, outputOffers.get())
            assertEquals(1, outputCloses.get())
        } finally {
            withContext(Dispatchers.Main) {
                controller.retired(channel.descriptor)
                ticket?.let { controller.serviceDestroyed(it, owner) }
            }
        }
    }
}
