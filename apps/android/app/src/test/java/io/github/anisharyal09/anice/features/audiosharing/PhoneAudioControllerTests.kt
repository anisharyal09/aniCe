// SPDX-License-Identifier: GPL-3.0-or-later
// Verifies reverse start admission, bounded current audio and local-first teardown without native capture.
package io.github.anisharyal09.anice.features.audiosharing

import io.github.anisharyal09.anice.infrastructure.connections.ChannelDescriptor
import io.github.anisharyal09.anice.infrastructure.connections.ChannelMaintenance
import io.github.anisharyal09.anice.infrastructure.connections.DataHandling
import io.github.anisharyal09.anice.infrastructure.connections.FeatureDispatch
import io.github.anisharyal09.anice.infrastructure.connections.SecuredChannel
import io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity
import io.github.anisharyal09.anice.infrastructure.session.Cbor
import io.github.anisharyal09.anice.infrastructure.session.SessionBackpressure
import io.github.anisharyal09.anice.infrastructure.session.SessionCbor
import io.github.anisharyal09.anice.infrastructure.session.SessionMaintenanceSnapshot
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import kotlin.coroutines.CoroutineContext

class PhoneAudioControllerTests {
    @Test fun passiveDiagnosticsIdentifySenderStallAndNeverCarryAudioOrPeerMetadata() = runBlocking {
        val dispatcher = QueuedDispatcher()
        val h = Harness(dispatcher)
        var nanos = 0L
        val reports = mutableListOf<PhoneAudioDiagnosticReport>()
        h.owner.diagnosticsEnabled = true
        h.owner.diagnosticNanoTime = { nanos }
        h.owner.diagnosticSink = { reports.add(it) }
        h.enable()
        h.begin()
        dispatcher.drain()
        val ticket = requireNotNull(h.request)
        h.owner.serviceAttached(ticket, h, Control())
        h.owner.handle(h.channel.descriptor, result(ticket.id, 0))
        h.owner.capturePrepared(ticket)
        for (sequence in 1L..10L) {
            nanos = sequence * 20_000_000
            h.owner.capturePacket(ticket, sequence, ByteArray(3840))
        }
        nanos = 300_000_000
        dispatcher.drain()
        h.owner.tick()
        val row = reports.single().fields
        assertEquals(10L, row["captured_packets"])
        assertEquals(7L, row["queue_replaced_packets"])
        assertEquals(280_000L, row["presentation_wait_max_us"])
        assertEquals(20_000L, row["capture_interval_max_us"])
        assertEquals(3L, row["submitted_packets"])
        assertEquals(140_000L, row["queue_age_max_us"])
        h.owner.stop()
        dispatcher.drain()
        assertEquals(2, reports.size)
        assertEquals(true, reports.last().fields["terminal"])
        assertFalse(reports.toString().contains("Fixture Mac"))
        assertFalse(reports.toString().contains(ticket.id))
    }

    @Test fun diagnosticSinkFailureCannotRetireOrReviveCapture() = runBlocking {
        val h = Harness()
        h.owner.diagnosticsEnabled = true
        h.owner.diagnosticSink = { error("diagnostic failure") }
        h.enable()
        h.begin()
        val ticket = requireNotNull(h.request)
        h.owner.serviceAttached(ticket, h, Control())
        h.owner.handle(h.channel.descriptor, result(ticket.id, 0))
        h.owner.capturePrepared(ticket)
        h.owner.tick()
        assertTrue(h.owner.active)
        h.owner.stop()
        assertFalse(h.owner.active)
    }

    @Test fun sendWindowKeepsThreeUnsentAndDropsTheOldest() {
        val window = PhoneAudioSendWindow()
        for (sequence in 1L..5L) window.offer(PhoneAudioPacket(sequence, ByteArray(4)))
        assertEquals(2L, window.dropped)
        assertEquals(listOf(3L, 4L, 5L), generateSequence { window.take() }.map { it.sequence }.toList())
    }

    @Test fun startWaitsForMacResultAndStopsLocallyFirst() = runBlocking {
        val h = Harness()
        h.enable()
        h.begin()
        assertEquals(listOf(1L), h.channel.sent.map { it.kind })
        val ticket = requireNotNull(h.request)
        val control = Control()
        assertTrue(h.owner.serviceAttached(ticket, h, control))
        assertEquals(0, control.started)
        h.owner.handle(h.channel.descriptor, result(ticket.id, 0))
        assertEquals(1, control.started)
        assertEquals(1L, h.owner.state)
        h.owner.capturePrepared(ticket)
        assertEquals(2L, h.owner.state)
        h.owner.capturePacket(ticket, 1, ByteArray(3840))
        assertEquals(listOf(1L, 3L), h.channel.sent.map { it.kind })
        assertEquals(1L, h.channel.sent.last().number(1))
        h.owner.stop()
        assertFalse(h.owner.active)
        assertEquals(1, control.closed)
        assertEquals(4L, h.channel.sent.last().kind)
        assertEquals(0L, h.channel.sent.last().number(1))
    }

    @Test fun duplicateCaptureSequenceIsIgnoredAndStaleResultCannotEndAReadyStream() = runBlocking {
        val h = Harness()
        h.enable()
        h.begin()
        val ticket = requireNotNull(h.request)
        val control = Control()
        h.owner.serviceAttached(ticket, h, control)
        h.owner.handle(h.channel.descriptor, result(ticket.id, 0))
        h.owner.capturePacket(ticket, 4, ByteArray(3840))
        h.owner.capturePacket(ticket, 4, ByteArray(3840))
        assertEquals(1, h.channel.sent.count { it.kind == 3L })
        h.owner.handle(h.channel.descriptor, result(ticket.id, 6))
        assertTrue(h.owner.active)
        h.owner.stop()
        assertEquals(1, control.closed)
        assertEquals(4L, h.channel.sent.last().kind)
        assertEquals(0L, h.channel.sent.last().number(1))
    }

    @Test fun refusalBeforeReadyEndsLocallyWithoutARedundantStop() = runBlocking {
        val h = Harness()
        h.enable()
        h.begin()
        val ticket = requireNotNull(h.request)
        val control = Control()
        h.owner.serviceAttached(ticket, h, control)
        h.owner.handle(h.channel.descriptor, result(ticket.id, 6))
        assertFalse(h.owner.active)
        assertEquals(1, control.closed)
        // The Mac already refused this stream, so no redundant Stop is addressed to it.
        assertEquals(1L, h.channel.sent.last().kind)
    }

    @Test fun capabilityAndForwardTagStayIsolatedFromTheReverseOwner() = runBlocking {
        val h = Harness()
        assertEquals(DataHandling.UNRECOGNIZED,
            h.owner.handle(h.channel.descriptor, AudioSharingMessage.capability(true).encode()))
        h.owner.handle(h.channel.descriptor,
            PhoneAudioMessage.from(AudioSharingMessage.capability(false)).encode())
        assertFalse(h.owner.macReceiving)
        assertFalse(h.owner.active)
    }

    @Test fun forwardListeningBlocksReverseStart() = runBlocking {
        val h = Harness()
        h.enable()
        h.owner.forwardActive = { true }
        h.begin()
        assertFalse(h.owner.active)
        assertTrue(h.channel.sent.isEmpty())
        assertEquals("Stop listening to this Mac before sending phone audio.", h.owner.status)
    }

    @Test fun captureRevocationStopsAndNotifiesTheMac() = runBlocking {
        val h = Harness()
        h.enable()
        h.begin()
        val ticket = requireNotNull(h.request)
        h.owner.serviceAttached(ticket, h, Control())
        h.owner.captureStopped(ticket, PhoneAudioStopCause.REVOKED)
        assertFalse(h.owner.active)
        assertEquals(4L, h.channel.sent.last().kind)
        assertEquals(0L, h.channel.sent.last().number(1))
    }

    @Test fun stopDuringAnInFlightSendLetsTheNextStartReachTheMac() = runBlocking {
        val h = Harness()
        h.enable()
        h.channel.gated = true
        h.begin()
        val first = requireNotNull(h.request).id
        assertTrue(h.owner.active)
        h.owner.stop()
        assertFalse(h.owner.active)
        h.begin()
        val second = requireNotNull(h.request).id
        assertNotEquals(first, second)
        assertEquals(1L, h.channel.sent.last().kind)
        assertEquals(second, h.channel.sent.last().text(0))
    }

    @Test fun resultBeforeServiceAttachmentStartsCaptureExactlyOnce() = runBlocking {
        val h = Harness()
        h.enable()
        h.begin()
        val ticket = requireNotNull(h.request)
        h.owner.handle(h.channel.descriptor, result(ticket.id, 0))
        assertFalse(ticket.captureStarted)
        assertEquals(1L, h.owner.state)
        val control = Control()
        assertTrue(h.owner.serviceAttached(ticket, h, control))
        h.owner.handle(h.channel.descriptor, result(ticket.id, 0))
        assertEquals(1, control.started)
        h.owner.capturePrepared(ticket)
        assertEquals(2L, h.owner.state)
        h.owner.stop()
    }

    @Test fun startAndStopAreRetainedUnderBackpressureWithoutSpinning() = runBlocking {
        val h = Harness()
        h.enable()
        h.channel.backpressured = true
        h.begin()
        val ticket = requireNotNull(h.request)
        repeat(20) { h.owner.tick() }
        assertEquals(1, h.channel.attempts)
        assertTrue(h.channel.sent.isEmpty())
        h.channel.backpressured = false
        h.owner.capacityAvailable(h.channel.descriptor)
        assertEquals(ticket.id, h.channel.sent.single().text(0))
        h.channel.backpressured = true
        h.owner.stop()
        assertFalse(h.owner.active)
        assertTrue(h.owner.controlPending)
        val before = h.channel.attempts
        h.begin()
        assertEquals(before, h.channel.attempts)
        h.channel.backpressured = false
        h.owner.capacityAvailable(h.channel.descriptor)
        assertEquals(listOf(1L, 4L), h.channel.sent.map { it.kind })
        assertFalse(h.owner.controlPending)
    }

    @Test fun suspendedAudioKeepsOnlyThreeNewPacketsAndNeverReplaysBackpressuredPcm() = runBlocking {
        val h = Harness()
        h.enable()
        h.begin()
        val ticket = requireNotNull(h.request)
        h.owner.serviceAttached(ticket, h, Control())
        h.owner.handle(h.channel.descriptor, result(ticket.id, 0))
        h.channel.gated = true
        for (sequence in 1L..6L) h.owner.capturePacket(ticket, sequence, ByteArray(3840))
        assertEquals(2L, h.owner.droppedPackets)
        h.channel.release()
        assertEquals(listOf(1L, 4L, 5L, 6L),
            h.channel.sent.filter { it.kind == 3L }.map { it.number(1) })
        h.channel.backpressured = true
        h.owner.capturePacket(ticket, 7, ByteArray(3840))
        h.owner.capturePacket(ticket, 8, ByteArray(3840))
        h.channel.backpressured = false
        h.owner.capacityAvailable(h.channel.descriptor)
        assertEquals(listOf(1L, 4L, 5L, 6L, 8L),
            h.channel.sent.filter { it.kind == 3L }.map { it.number(1) })
        assertEquals(3L, h.owner.droppedPackets)
        h.owner.stop()
    }

    @Test fun backgroundHoldsSixUnsentPacketsAndReturningKeepsOnlyTheNewestThree() = runBlocking {
        val h = Harness()
        h.enable()
        h.begin()
        val ticket = requireNotNull(h.request)
        h.owner.serviceAttached(ticket, h, Control())
        h.owner.handle(h.channel.descriptor, result(ticket.id, 0))
        h.owner.foregroundChanged(false)
        h.channel.gated = true
        for (sequence in 1L..7L) h.owner.capturePacket(ticket, sequence, ByteArray(3840))
        assertEquals(0L, h.owner.droppedPackets)
        h.owner.capturePacket(ticket, 8L, ByteArray(3840))
        assertEquals(1L, h.owner.droppedPackets)
        h.channel.release()
        assertEquals(listOf(1L) + (3L..8L),
            h.channel.sent.filter { it.kind == 3L }.map { it.number(1) })

        h.channel.sent.clear()
        h.channel.gated = true
        for (sequence in 9L..15L) h.owner.capturePacket(ticket, sequence, ByteArray(3840))
        h.owner.foregroundChanged(true)
        assertEquals(4L, h.owner.droppedPackets)
        h.channel.release()
        assertEquals(listOf(9L, 13L, 14L, 15L),
            h.channel.sent.filter { it.kind == 3L }.map { it.number(1) })
        h.owner.stop()
    }

    @Test fun captureWorkerQueuesAtMostOneSenderWake() = runBlocking {
        val dispatcher = QueuedDispatcher()
        val h = Harness(dispatcher)
        h.enable()
        h.begin()
        dispatcher.drain()
        val ticket = requireNotNull(h.request)
        h.owner.serviceAttached(ticket, h, Control())
        h.owner.handle(h.channel.descriptor, result(ticket.id, 0))
        for (sequence in 1L..100L) h.owner.capturePacket(ticket, sequence, ByteArray(3840))
        assertEquals(1, dispatcher.pending)
        dispatcher.drain()
        assertEquals(97L, h.owner.droppedPackets)
        assertEquals(listOf(98L, 99L, 100L),
            h.channel.sent.filter { it.kind == 3L }.map { it.number(1) })
        h.owner.stop()
        dispatcher.drain()
    }

    @Test fun workerCannotDrainStaleAudioBeforeMainObservesRenewalCompletion() = runBlocking {
        val h = Harness()
        h.enable()
        h.begin()
        val ticket = requireNotNull(h.request)
        h.owner.serviceAttached(ticket, h, Control())
        h.owner.handle(h.channel.descriptor, result(ticket.id, 0))
        h.channel.gated = true
        h.owner.capturePacket(ticket, 1, ByteArray(3840))
        h.owner.capturePacket(ticket, 2, ByteArray(3840))
        h.channel.maintenance.update(SessionMaintenanceSnapshot(elapsedMillis = 100, revision = 2))
        h.channel.release()
        h.owner.capturePacket(ticket, 3, ByteArray(3840))
        assertEquals(listOf(1L), h.channel.sent.filter { it.kind == 3L }.map { it.number(1) })
        h.owner.capacityAvailable(h.channel.descriptor)
        h.owner.capturePacket(ticket, 4, ByteArray(3840))
        assertEquals(listOf(1L, 4L), h.channel.sent.filter { it.kind == 3L }.map { it.number(1) })
        h.owner.stop()
    }

    @Test fun localProjectionConsentCannotMoveToAReplacementChannelOrBeUsedTwice() = runBlocking {
        val h = Harness()
        h.enable()
        val pending = requireNotNull(h.owner.requestConsent())
        assertNull(h.owner.requestConsent())
        h.owner.available(Channel(h.clock, "replacement"))
        val grant = PhoneAudioGrant(-1, Any())
        h.owner.completeConsent(pending, grant)
        assertFalse(grant.unused)
        assertFalse(h.owner.active)
        assertNull(h.request)
        val another = PhoneAudioGrant(-1, Any())
        h.owner.begin(another) // Capability was withdrawn on replacement.
        assertFalse(another.unused)
        assertFalse(h.owner.active)

        val enabled = Harness()
        enabled.enable()
        val oneUse = PhoneAudioGrant(-1, Any())
        enabled.owner.begin(oneUse)
        assertFalse(oneUse.unused)
        enabled.owner.stop()
        val starts = enabled.channel.sent.count { it.kind == 1L }
        enabled.owner.begin(oneUse)
        assertEquals(starts, enabled.channel.sent.count { it.kind == 1L })
        assertFalse(enabled.owner.active)
    }

    @Test fun revokedCapabilityAndNativeDestructionFenceConsentAndNewStarts() = runBlocking {
        val h = Harness()
        h.enable()
        val pending = requireNotNull(h.owner.requestConsent())
        h.owner.handle(h.channel.descriptor,
            PhoneAudioMessage.from(AudioSharingMessage.capability(false)).encode())
        h.owner.completeConsent(pending, PhoneAudioGrant(-1, Any()))
        assertFalse(h.owner.active)
        h.enable()
        h.begin()
        val ticket = requireNotNull(h.request)
        val control = Control()
        h.owner.serviceAttached(ticket, h, control)
        h.autoDestroy = false
        h.owner.stop()
        assertFalse(h.owner.active)
        assertTrue(h.owner.busy)
        assertEquals(listOf(true, false), h.leases)
        h.begin()
        assertSame(ticket, h.request)
        h.owner.serviceDestroyed(ticket, h)
        assertFalse(h.owner.busy)
        h.begin()
        assertNotSame(ticket, h.request)
        h.owner.captureStopped(ticket, PhoneAudioStopCause.REVOKED)
        assertTrue(h.owner.active)
        h.owner.stop()
    }

    @Test fun expiredResultOrServiceCannotStartCapture() = runBlocking {
        val h = Harness()
        h.enable()
        h.begin()
        val ticket = requireNotNull(h.request)
        val control = Control()
        h.owner.serviceAttached(ticket, h, control)
        h.clock.now = 5000
        h.owner.handle(h.channel.descriptor, result(ticket.id, 0))
        assertFalse(h.owner.active)
        assertEquals(0, control.started)
        assertFalse(h.owner.serviceAttached(ticket, h, Control()))
    }

    @Test fun nativePreparationMustFinishBeforeSendingIsReportedAndLateCallbacksAreFenced() = runBlocking {
        val h = Harness()
        h.enable()
        h.begin()
        val ticket = requireNotNull(h.request)
        h.owner.serviceAttached(ticket, h, Control())
        h.owner.handle(h.channel.descriptor, result(ticket.id, 0))
        assertEquals(1L, h.owner.state)
        h.clock.now = 5000
        h.owner.tick()
        assertFalse(h.owner.active)
        h.owner.capturePrepared(ticket)
        assertEquals(0L, h.owner.state)
    }

    @Test fun renewalCancelsUnsealedAudioAndResumesOnlyCurrentPcm() = runBlocking {
        val h = Harness()
        h.enable()
        h.begin()
        val ticket = requireNotNull(h.request)
        val control = Control()
        h.owner.serviceAttached(ticket, h, control)
        h.owner.handle(h.channel.descriptor, result(ticket.id, 0))
        h.owner.capturePrepared(ticket)
        h.channel.gated = true
        h.owner.capturePacket(ticket, 1, ByteArray(3840))
        h.owner.capturePacket(ticket, 2, ByteArray(3840))
        h.clock.now = 1000
        h.channel.maintenance.update(SessionMaintenanceSnapshot(sinceMillis = 1000, revision = 1))
        h.owner.capacityAvailable(h.channel.descriptor)
        h.clock.now = 45000
        h.owner.capturePacket(ticket, 3, ByteArray(3840))
        h.owner.tick()
        assertTrue(h.owner.active)
        assertEquals(4L, h.owner.state)
        h.channel.maintenance.update(SessionMaintenanceSnapshot(elapsedMillis = 44000, revision = 2))
        h.owner.capacityAvailable(h.channel.descriptor)
        h.owner.capturePacket(ticket, 4, ByteArray(3840))
        assertEquals(listOf(4L), h.channel.sent.filter { it.kind == 3L }.map { it.number(1) })
        assertEquals(1, control.started)
        assertEquals(1, h.channel.sent.count { it.kind == 1L })
        control.available = false
        h.clock.now = 47000
        h.channel.maintenance.update(SessionMaintenanceSnapshot(elapsedMillis = 45000, revision = 4))
        h.owner.tick()
        assertFalse(h.owner.active)
    }

    @Test fun reverseOwnerRegisteredFirstDoesNotConsumeForwardOrUnrelatedData() = runBlocking {
        val h = Harness()
        val dispatch = FeatureDispatch(now = { h.clock.now }, presentation = Dispatchers.Unconfined)
        dispatch.register(h.owner)
        val forward = object : io.github.anisharyal09.anice.infrastructure.connections.FeatureHandler {
            var handled = 0
            override fun available(channel: SecuredChannel) {}
            override fun retired(descriptor: ChannelDescriptor) {}
            override fun capacityAvailable(descriptor: ChannelDescriptor) {}
            override suspend fun handle(descriptor: ChannelDescriptor, bytes: ByteArray): DataHandling {
                if (AudioSharingMessage.decode(bytes) == null) return DataHandling.UNRECOGNIZED
                handled++
                return DataHandling.HANDLED
            }
        }
        dispatch.register(forward)
        val descriptor = h.channel.descriptor
        dispatch.available(descriptor) {}
        assertEquals(DataHandling.HANDLED, dispatch.handle("lan", descriptor.instance,
            AudioSharingMessage.capability(true).encode()))
        assertEquals(1, forward.handled)
        assertEquals(DataHandling.HANDLED, dispatch.handle("lan", descriptor.instance,
            PhoneAudioMessage.from(AudioSharingMessage.capability(true)).encode()))
        assertEquals(1, forward.handled)
        assertEquals(DataHandling.UNRECOGNIZED, dispatch.handle("lan", descriptor.instance,
            SessionCbor.encode(Cbor.Array(listOf(Cbor.Text("unrelated"), Cbor.Integer(1))))))
        dispatch.retired("lan")
    }

    @Test fun startServiceExceptionStopsWithoutSendingUnsolicitedStop() = runBlocking {
        val h = Harness()
        h.enable()
        h.owner.startService = { _, _ -> throw IllegalStateException("background restricted") }
        h.begin()
        assertFalse(h.owner.active)
        assertEquals(0L, h.owner.state)
        assertTrue(h.channel.sent.isEmpty())
    }

    @Test fun timeoutAndPreReadyCaptureFailureSendPreparationExpiredStopReason() = runBlocking {
        val h = Harness()
        h.enable()
        h.begin()
        h.clock.now = 5000
        h.owner.tick()
        assertFalse(h.owner.active)
        assertEquals(listOf(1L, 4L), h.channel.sent.map { it.kind })
        assertEquals(7L, h.channel.sent.last().number(1))

        h.begin()
        val ticket = requireNotNull(h.request)
        h.owner.captureFailed(ticket, "Capture setup rejected.")
        assertFalse(h.owner.active)
        assertEquals(listOf(1L, 4L, 1L, 4L), h.channel.sent.map { it.kind })
        assertEquals(7L, h.channel.sent.last().number(1))
    }

    @Test fun offMainSendDispatcherQueuesAudioWithoutWaitingOnMainDispatcher() = runBlocking {
        val main = QueuedDispatcher()
        val send = QueuedDispatcher()
        val clock = Clock()
        val channel = Channel(clock)
        val owner = PhoneAudioController(now = { clock.now }, dispatcher = main,
            automaticTicks = false, sendDispatcher = send)
        owner.startService = { _, grant -> checkNotNull(grant.consume()) }
        owner.available(channel)
        owner.handle(channel.descriptor, PhoneAudioMessage.from(AudioSharingMessage.capability(true)).encode())
        send.drain()
        owner.begin(PhoneAudioGrant(-1, Any()))
        main.drain()
        send.drain()
        val ticket = requireNotNull(owner.request(channel.sent.single().text(0), channel.descriptor.instance))
        owner.serviceAttached(ticket, this, Control())
        owner.handle(channel.descriptor, result(ticket.id, 0))
        val pendingMainBefore = main.pending
        owner.capturePacket(ticket, 1L, ByteArray(3840))
        assertEquals(pendingMainBefore, main.pending)
        assertEquals(1, send.pending)
        send.drain()
        assertEquals(listOf(1L), channel.sent.filter { it.kind == 3L }.map { it.number(1) })
        owner.stop()
        main.drain()
        send.drain()
    }

    @Test fun callActiveStateUpdatesStatusAndRestoresWhenCallEnds() = runBlocking {
        val h = Harness()
        h.enable()
        h.begin()
        val ticket = requireNotNull(h.request)
        h.owner.serviceAttached(ticket, h, Control())
        h.owner.handle(h.channel.descriptor, result(ticket.id, 0))
        h.owner.capturePrepared(ticket)
        h.owner.callActiveChanged(ticket, true)
        assertTrue(h.owner.callActive)
        assertTrue(h.owner.status.contains("call", ignoreCase = true))
        h.owner.callActiveChanged(ticket, false)
        assertFalse(h.owner.callActive)
        assertTrue(h.owner.status.startsWith("Sending this phone's audio"))
        h.owner.stop()
        assertFalse(h.owner.callActive)
    }

    @Test fun attachedServiceThatStopsDuringCaptureStartStillOwnsCleanup() = runBlocking {
        val h = Harness()
        h.autoDestroy = false
        h.enable()
        h.begin()
        val ticket = requireNotNull(h.request)
        val descriptor = h.channel.descriptor
        val ready = result(ticket.id, 0)
        assertEquals(DataHandling.DISCARDED, h.owner.handle(descriptor, result("01234567-89ab-4cde-8fab-0123456789ab", 0)))
        assertEquals(DataHandling.HANDLED, h.owner.handle(descriptor, ready))
        assertEquals(DataHandling.DISCARDED, h.owner.handle(descriptor, ready))
        assertTrue(h.owner.serviceAttached(ticket, h, object : PhoneAudioCaptureControl {
            override fun start() { throw IllegalStateException("Capture unavailable") }
            override fun close() {}
        }))
        assertFalse(h.owner.active)
        assertTrue(h.owner.busy)
        h.owner.serviceDestroyed(ticket, h)
        assertFalse(h.owner.busy)
    }

    @Test fun requestConsentWhenOfflineTriggersLanRequired() {
        val clock = Clock()
        val owner = PhoneAudioController(now = { clock.now }, dispatcher = Dispatchers.Unconfined,
            automaticTicks = false)
        var requests = 0
        owner.onLanRequired = { requests++ }
        assertNull(owner.requestConsent())
        assertEquals(1, requests)
    }

    private class Clock(var now: Long = 0)
    private class Channel(private val clock: Clock, instance: String = "channel") : SecuredChannel {
        override val descriptor = ChannelDescriptor(instance, "lan", DeviceIdentity(
            "01234567-89ab-4cde-8fab-0123456789ab", "Fixture Mac", "macos", "fixture-key", "a".repeat(64)))
        override val maintenance = ChannelMaintenance { clock.now }
        val sent = mutableListOf<AudioSharingMessage>()
        var gated = false
        var backpressured = false
        var attempts = 0
        private var gate = CompletableDeferred<Unit>()
        fun release() { gate.complete(Unit); gate = CompletableDeferred() }
        override suspend fun sendData(bytes: ByteArray) {
            attempts++
            if (backpressured) throw SessionBackpressure()
            if (gated) { gated = false; gate.await() }
            sent.add(requireNotNull(PhoneAudioMessage.decode(bytes)).validated())
        }
    }
    private class Control : PhoneAudioCaptureControl {
        var started = 0
        var closed = 0
        override var available = true
        override fun start() { started++ }
        override fun close() { closed++ }
    }
    private class QueuedDispatcher : CoroutineDispatcher() {
        private val work = ArrayDeque<Runnable>()
        val pending get() = work.size
        override fun dispatch(context: CoroutineContext, block: Runnable) { work.addLast(block) }
        fun drain() { while (work.isNotEmpty()) work.removeFirst().run() }
    }
    private class Harness(dispatcher: CoroutineDispatcher = Dispatchers.Unconfined) {
        val clock = Clock()
        val channel = Channel(clock)
        val owner = PhoneAudioController(now = { clock.now }, dispatcher = dispatcher,
            automaticTicks = false)
        var request: PhoneAudioRequest? = null
        var autoDestroy = true
        val leases = mutableListOf<Boolean>()
        init {
            owner.startService = { value, grant -> checkNotNull(grant.consume()); request = value }
            owner.stopService = { value ->
                if (autoDestroy) value.serviceOwner?.let { owner.serviceDestroyed(value, it) }
            }
            owner.serviceOwnershipChanged = { _, _, acquired ->
                if (leases.lastOrNull() != acquired) leases.add(acquired)
            }
            owner.available(channel)
        }
        suspend fun enable() {
            owner.handle(channel.descriptor,
                PhoneAudioMessage.from(AudioSharingMessage.capability(true)).encode())
        }
        fun begin() { owner.begin(PhoneAudioGrant(-1, Any())) }
    }
    private fun result(id: String, code: Long) =
        PhoneAudioMessage(2, listOf(Cbor.Text(id), Cbor.Integer(code))).encode()
}
