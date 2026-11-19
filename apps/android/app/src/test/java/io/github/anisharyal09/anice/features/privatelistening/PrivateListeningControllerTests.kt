// SPDX-License-Identifier: GPL-3.0-or-later
// Verifies consent, service tickets, stale traffic and retained-channel maintenance with deterministic native-output fakes.
package io.github.anisharyal09.anice.features.privatelistening

import io.github.anisharyal09.anice.infrastructure.connections.ChannelDescriptor
import io.github.anisharyal09.anice.infrastructure.connections.ChannelMaintenance
import io.github.anisharyal09.anice.infrastructure.connections.DataHandling
import io.github.anisharyal09.anice.infrastructure.connections.SecuredChannel
import io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity
import io.github.anisharyal09.anice.infrastructure.session.Cbor
import io.github.anisharyal09.anice.infrastructure.session.SessionMaintenanceSnapshot
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class PrivateListeningControllerTests {
    @Test fun profileIsFrozenForTheCurrentTicketAndRetiredHealthCannotReappear() = runBlocking {
        val h = Harness()
        h.owner.setBufferProfile(ListeningBufferProfile.LOWER_DELAY)
        h.owner.setConsent(true)
        h.start()
        val ticket = requireNotNull(h.request)
        assertEquals(ListeningBufferProfile.LOWER_DELAY, ticket.bufferProfile)
        h.owner.setBufferProfile(ListeningBufferProfile.BALANCED)
        assertEquals(ListeningBufferProfile.LOWER_DELAY, h.owner.bufferProfile)
        h.attach()
        h.owner.playbackHealth(ticket, ListeningPlaybackHealth(1, 960, 3840, 0, false, targetFrames = 3840))
        assertEquals(3840, h.owner.diagnostics?.targetFrames)
        h.owner.focusChanged(ticket, false)
        assertNull(h.owner.diagnostics)
        h.owner.playbackHealth(ticket, ListeningPlaybackHealth(2, 1920, 3840, 0, false))
        assertNull(h.owner.diagnostics)
        h.owner.stop()
        assertNull(h.owner.diagnostics)
        h.owner.playbackHealth(ticket, ListeningPlaybackHealth(2, 1920, 9600, 1, false))
        assertNull(h.owner.diagnostics)
        h.owner.serviceDestroyed(ticket, h)
        h.owner.setBufferProfile(ListeningBufferProfile.BALANCED)
        h.start(OTHER_ID)
        assertEquals(ListeningBufferProfile.BALANCED, requireNotNull(h.request).bufferProfile)
        h.owner.stop()
    }

    private class Clock(var now: Long = 0)
    private class Channel(private val clock: Clock, instance: String = "channel") : SecuredChannel {
        override val descriptor = ChannelDescriptor(instance, "lan", DeviceIdentity(
            "01234567-89ab-4cde-8fab-0123456789ab", "Fixture Mac", "macos", "fixture-key", "a".repeat(64)))
        override val maintenance = ChannelMaintenance { clock.now }
        val sent = mutableListOf<PrivateListeningMessage>()
        override suspend fun sendData(bytes: ByteArray) {
            sent.add(requireNotNull(PrivateListeningMessage.decode(bytes)))
        }
    }
    private class Output : PrivateListeningOutput {
        var paused = 0
        var resumed = 0
        var closed = 0
        val audio = mutableListOf<PrivateListeningMessage>()
        var resumeGate: CompletableDeferred<Unit>? = null
        override fun offer(message: PrivateListeningMessage): Boolean { audio.add(message); return true }
        override fun pause() { paused++ }
        override suspend fun resume() { resumed++; resumeGate?.await() }
        override fun close() { closed++ }
    }
    private class Harness {
        val clock = Clock()
        val channel = Channel(clock)
        val owner = PrivateListeningController(now = { clock.now }, dispatcher = Dispatchers.Unconfined,
            automaticTicks = false)
        var starts = 0
        var request: PrivateListeningRequest? = null
        var stopped = 0
        val leases = mutableListOf<Boolean>()
        init {
            owner.loadLocalFingerprint = { "b".repeat(64) }
            owner.startupAllowed = { true }
            owner.startService = { request = it; starts++ }
            owner.stopService = { stopped++ }
            owner.serviceOwnershipChanged = { _, _, acquired -> leases.add(acquired) }
            owner.available(channel)
        }
        suspend fun start(id: String = ID) {
            owner.handle(channel.descriptor, PrivateListeningMessage.start(id).encode())
        }
        fun attach(output: Output = Output()): Output {
            assertTrue(owner.serviceAttached(requireNotNull(request), this, output))
            owner.ready(requireNotNull(request))
            return output
        }
        fun results() = channel.sent.filter { it.kind == 2L }.map { it.number(1) }
        suspend fun audio(sequence: Long) = owner.handle(channel.descriptor,
            PrivateListeningMessage.audio(ID, sequence, ByteArray(3840)).encode())
    }

    @Test fun defaultOffAndChangedCredentialsCannotAuthorizePlayback() = runBlocking {
        val h = Harness()
        assertFalse(h.owner.consentEnabled)
        assertEquals(false, h.channel.sent.first().flag(4))
        h.start()
        assertEquals(listOf(1L), h.results())
        assertEquals(0, h.starts)
        h.owner.setConsent(true)
        h.start() // A refused stream ID stays retired on this channel.
        assertEquals(0, h.starts)
        h.start(OTHER_ID)
        assertEquals(1, h.starts)
        val peer = h.channel.descriptor.peer
        assertFalse(h.owner.preferences.enabled("c".repeat(64), peer))
        assertFalse(h.owner.preferences.enabled("b".repeat(64), peer.copy(publicKey = "replacement-key")))
        assertFalse(h.owner.preferences.enabled("b".repeat(64), peer.copy(fingerprint = "c".repeat(64))))
        h.owner.stop()
    }

    @Test fun backgroundRefusalNeverCreatesAServiceTicket() = runBlocking {
        val h = Harness()
        h.owner.setConsent(true)
        h.owner.startupAllowed = { false }
        h.start()
        assertEquals(listOf(4L), h.results())
        assertEquals(0, h.starts)
        assertFalse(h.owner.active)
    }

    @Test fun startsCoalesceAndOldServiceCompletionsCannotReviveStoppedAudio() = runBlocking {
        val h = Harness()
        h.owner.setConsent(true)
        h.start()
        val request = requireNotNull(h.request)
        h.start()
        assertEquals(1, h.starts)
        h.start(OTHER_ID)
        assertEquals(listOf(2L), h.results())
        val output = h.attach()
        assertEquals(listOf(2L, 0L), h.results())
        h.start()
        assertEquals(listOf(2L, 0L, 0L), h.results())
        assertEquals(DataHandling.HANDLED, h.audio(1))
        assertEquals(DataHandling.DISCARDED, h.audio(1))
        assertEquals(1, output.audio.size)
        h.owner.stop()
        h.owner.ready(request)
        assertFalse(h.owner.active)
        assertEquals(1, output.closed)
        assertTrue(h.channel.sent.any { it.kind == 4L })
    }

    @Test fun watchdogAndFirstAudioTimeoutRemainBoundedWithoutBreakingSilentAudio() = runBlocking {
        val h = Harness()
        h.owner.setConsent(true)
        h.start()
        val output = h.attach()
        h.clock.now = 4000
        h.audio(1)
        h.clock.now = 13000
        h.owner.tick()
        assertTrue(h.owner.active)
        h.clock.now = 14000
        h.owner.tick()
        assertFalse(h.owner.active)
        assertEquals(1, output.closed)
    }

    @Test fun maintenanceKeepsTheSameStreamAndBuffersDuringSilentRepriming() = runBlocking {
        val h = Harness()
        h.owner.setConsent(true)
        h.start()
        val output = h.attach()
        h.audio(1)
        h.clock.now = 1000
        h.channel.maintenance.update(SessionMaintenanceSnapshot(sinceMillis = 1000, revision = 1))
        h.owner.capacityAvailable(h.channel.descriptor)
        assertEquals(4L, h.owner.state)
        h.clock.now = 45000
        h.owner.tick()
        assertTrue(h.owner.active)
        h.audio(2)
        assertEquals(1, output.audio.size)
        output.resumeGate = CompletableDeferred()
        h.channel.maintenance.update(SessionMaintenanceSnapshot(elapsedMillis = 44000, revision = 2))
        h.owner.capacityAvailable(h.channel.descriptor)
        assertEquals(ID, h.owner.streamId)
        assertEquals(1, output.resumed)
        assertEquals(1, h.starts)
        h.audio(3)
        assertEquals(2, output.audio.size) // Output gate, not wire admission, owns audible re-priming.
        output.resumeGate!!.complete(Unit)
        h.owner.tick()
        assertTrue(h.owner.active)
        h.owner.stop()
    }

    @Test fun coalescedMaintenanceStillDiscardsOldAudioAndLateRetirementCannotCloseReplacement() = runBlocking {
        val h = Harness()
        h.owner.setConsent(true)
        h.start()
        val output = h.attach()
        h.clock.now = 3000
        h.channel.maintenance.update(SessionMaintenanceSnapshot(elapsedMillis = 2000, revision = 2))
        h.owner.capacityAvailable(h.channel.descriptor)
        assertEquals(1, output.paused)
        assertEquals(1, output.resumed)
        val replacement = Channel(h.clock, instance = "replacement")
        h.owner.available(replacement)
        assertEquals(1, output.closed)
        h.owner.retired(h.channel.descriptor)
        assertEquals(replacement.descriptor.peer, h.owner.peer)
        assertFalse(h.owner.active)
    }

    @Test fun focusPauseHasAnAbsoluteExpiryAndPermanentLossEndsOwnership() = runBlocking {
        val h = Harness()
        h.owner.setConsent(true)
        h.start()
        val output = h.attach()
        h.owner.focusChanged(requireNotNull(h.request), false)
        assertEquals(3L, h.owner.state)
        h.audio(1)
        assertTrue(output.audio.isEmpty())
        for (time in 1000L..89000L step 1000) {
            h.clock.now = time
            val status = PrivateListeningMessage(5, listOf(Cbor.Text(ID), Cbor.Integer(0), Cbor.Integer(3),
                Cbor.Integer(0), Cbor.Integer(0), Cbor.Integer(0), Cbor.Integer(0)))
            h.owner.handle(h.channel.descriptor, status.encode())
            h.owner.tick()
        }
        assertTrue(h.owner.active)
        h.clock.now = 90000
        h.owner.tick()
        assertFalse(h.owner.active)
        val h2 = Harness()
        h2.owner.setConsent(true)
        h2.start()
        val second = h2.attach()
        h2.owner.focusChanged(requireNotNull(h2.request), false, permanent = true)
        assertFalse(h2.owner.active)
        assertEquals(1, second.closed)
    }

    @Test fun preparationTimeoutAndInvalidSideNeverPromoteTheStream() = runBlocking {
        val h = Harness()
        h.owner.setConsent(true)
        h.start()
        h.clock.now = 5000
        h.owner.tick()
        assertFalse(h.owner.active)
        assertEquals(listOf(9L), h.results())
        val h2 = Harness()
        h2.owner.setConsent(true)
        h2.start()
        h2.attach()
        val status = PrivateListeningMessage(5, listOf(Cbor.Text(ID), Cbor.Integer(1), Cbor.Integer(2),
            Cbor.Integer(0), Cbor.Integer(0), Cbor.Integer(0), Cbor.Integer(0)))
        assertEquals(DataHandling.DISCARDED, h2.owner.handle(h2.channel.descriptor, status.encode()))
        h2.owner.stop()
    }

    @Test fun serviceDestructionFromAnOldOwnerCannotReleaseAReplacementOperation() = runBlocking {
        val h = Harness()
        h.owner.setConsent(true)
        h.start()
        val old = requireNotNull(h.request)
        h.attach()
        h.owner.stop()
        h.start(OTHER_ID)
        assertFalse(h.owner.active) // Wait for native teardown rather than stopping a new service by class.
        h.owner.serviceDestroyed(old, h)
        h.start(OTHER_ID)
        assertTrue(h.owner.active)
        val replacement = requireNotNull(h.request)
        assertNotSame(old, replacement)
        h.owner.serviceDestroyed(old, h)
        assertTrue(h.owner.active)
        h.owner.stop()
    }

    @Test fun macStatusCannotExtendTheFirstAudioDeadlineAndNativeDestructionDoesNotLatchBusy() = runBlocking {
        val h = Harness()
        h.owner.setConsent(true)
        h.start()
        h.attach()
        h.clock.now = 4000
        val report = PrivateListeningMessage(5, listOf(Cbor.Text(ID), Cbor.Integer(0), Cbor.Integer(2),
            Cbor.Integer(0), Cbor.Integer(0), Cbor.Integer(0), Cbor.Integer(0)))
        h.owner.handle(h.channel.descriptor, report.encode())
        h.clock.now = 5000
        h.owner.tick()
        assertFalse(h.owner.active)
        val old = requireNotNull(h.request)
        h.owner.serviceDestroyed(old, h)
        h.start(OTHER_ID)
        h.attach()
        val second = requireNotNull(h.request)
        h.owner.serviceDestroyed(second, h)
        assertFalse(h.owner.active)
        val fresh = "01234567-89ab-4cde-8fab-0123456789ad"
        h.start(fresh)
        assertTrue(h.owner.active)
        h.owner.stop()
    }

    companion object {
        private const val ID = "01234567-89ab-4cde-8fab-0123456789ab"
        private const val OTHER_ID = "01234567-89ab-4cde-8fab-0123456789ac"
    }
}
