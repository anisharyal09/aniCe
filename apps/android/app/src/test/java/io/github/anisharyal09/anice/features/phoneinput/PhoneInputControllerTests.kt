// SPDX-License-Identifier: GPL-3.0-or-later
// Verifies BLE negotiation, accepted-session gating, ordered edits and cancellation release.
package io.github.anisharyal09.anice.features.phoneinput

import io.github.anisharyal09.anice.infrastructure.connections.ChannelDescriptor
import io.github.anisharyal09.anice.infrastructure.connections.SecuredChannel
import io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity
import io.github.anisharyal09.anice.infrastructure.session.Cbor
import io.github.anisharyal09.anice.infrastructure.session.SessionBackpressure
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PhoneInputControllerTests {
    @Test fun requiresTextAndKeyTransitionsForCorrectionSupport() = runBlocking {
        val setup = connectedController(remoteEvents = 0x01)
        assertEquals(7L, setup.channel.messages().first().number(1))
        assertFalse(setup.owner.compatible(setup.peer))
        assertFalse(setup.owner.supportsPointer(setup.peer))
        assertFalse(setup.owner.start(setup.peer))
        assertEquals(PhoneInputState.IDLE, setup.owner.state)
        assertEquals(listOf(1L), setup.channel.messages().map { it.kind })
    }

    @Test fun coalescesMotionAndOrdersScrollAndButtonsBeforeRelease() = runBlocking {
        val (owner, channel, descriptor, peer) = connectedController()
        assertEquals(7L, channel.messages().first().number(1))
        assertTrue(owner.supportsPointer(peer))
        assertTrue(owner.start(peer))
        val request = channel.messages().last()
        owner.handle(descriptor, PhoneInputMessage.of(3, Cbor.Text(request.text(0)), Cbor.Integer(0)).encode())

        assertTrue(owner.sendPointerMotion(10, 5))
        assertTrue(owner.sendPointerMotion(20, -2))
        kotlinx.coroutines.delay(40)

        val motion = channel.messages().filter { it.kind == 6L }
        assertEquals(1, motion.size)
        assertEquals(30L, motion.single().number(2))
        assertEquals(3L, motion.single().number(3))
        assertTrue(owner.sendScroll(-12, 24))
        assertTrue(owner.sendPointerButtons(1))
        assertTrue(owner.sendPointerButtons(0))
        owner.stop()

        val messages = channel.messages().dropWhile { it.kind != 6L }
        assertEquals(listOf(6L, 8L, 7L, 7L, 9L, 10L), messages.map { it.kind })
        assertEquals(listOf(1L, 2L, 3L, 4L, 5L, 6L), messages.map { it.number(1) })
        assertEquals(-12L, messages[1].number(2))
        assertEquals(24L, messages[1].number(3))
    }

    @Test fun olderMacCanTypeWithoutAdvertisingTrackpadInput() = runBlocking {
        val (owner, _, _, peer) = connectedController(remoteEvents = 0x03)
        assertTrue(owner.compatible(peer))
        assertFalse(owner.supportsPointer(peer))
    }

    @Test fun splitsAccumulatedPointerDeltasAtTheWireLimitBeforeStopping() = runBlocking {
        val (owner, channel, descriptor, peer) = connectedController()
        assertTrue(owner.start(peer))
        val request = channel.messages().last()
        owner.handle(descriptor, PhoneInputMessage.of(3, Cbor.Text(request.text(0)), Cbor.Integer(0)).encode())

        assertTrue(owner.sendPointerMotion(40_000, -40_000))
        owner.stop()

        val messages = channel.messages().dropWhile { it.kind != 6L }
        assertEquals(listOf(6L, 6L, 9L, 10L), messages.map { it.kind })
        assertEquals(32_767L, messages[0].number(2))
        assertEquals(-32_767L, messages[0].number(3))
        assertEquals(7_233L, messages[1].number(2))
        assertEquals(-7_233L, messages[1].number(3))
    }

    @Test fun pointerBackpressureKeepsTextAndStopOrderedBehindMovement() = runBlocking {
        val (owner, channel, descriptor, peer) = connectedController()
        assertTrue(owner.start(peer))
        val request = channel.messages().last()
        owner.handle(descriptor, PhoneInputMessage.of(3, Cbor.Text(request.text(0)), Cbor.Integer(0)).encode())

        channel.blocked = true
        assertTrue(owner.sendPointerMotion(40_000, -40_000))
        kotlinx.coroutines.delay(40)
        assertTrue(owner.sendText(PhoneInputTextPlan(listOf(PhoneInputTextAction.Commit("x")))))
        owner.stop()

        channel.blocked = false
        owner.capacityAvailable(descriptor)
        kotlinx.coroutines.delay(40)

        val messages = channel.messages().dropWhile { it.kind != 6L }
        assertEquals(listOf(6L, 6L, 4L, 9L, 10L), messages.map { it.kind })
        assertEquals(listOf(1L, 2L, 3L, 4L, 5L), messages.map { it.number(1) })
    }

    @Test fun commitsOnlyAfterAcceptanceAndStopsWithReleaseBeforeBoundary() = runBlocking {
        val (owner, channel, descriptor, peer) = connectedController()
        assertEquals(7L, channel.messages().first().number(1))
        assertTrue(owner.start(peer))
        val request = channel.messages().last()
        assertEquals(2L, request.kind)
        assertEquals(PhoneInputState.STARTING, owner.state)
        assertFalse(owner.sendKey(0x28, 0, true))

        owner.handle(descriptor, PhoneInputMessage.of(3, Cbor.Text(request.text(0)), Cbor.Integer(0)).encode())
        assertEquals(PhoneInputState.ACTIVE, owner.state)
        assertTrue(owner.sendText(PhoneInputTextPlan(listOf(
            PhoneInputTextAction.Commit("hi"),
            PhoneInputTextAction.Backspace(1),
        ))))

        val sentInput = channel.messages().takeLast(3)
        assertEquals(listOf(4L, 5L, 5L), sentInput.map { it.kind })
        assertEquals(listOf(1L, 2L, 3L), sentInput.map { it.number(1) })
        assertEquals(listOf(true, false), sentInput.drop(1).map { it.flag(4) })

        owner.stop()
        val terminal = channel.messages().takeLast(2)
        assertEquals(listOf(9L, 10L), terminal.map { it.kind })
        assertEquals(PhoneInputState.IDLE, owner.state)
        assertEquals("Typing stopped.", owner.status)
    }

    @Test fun cancellationWhileMacIsDecidingReleasesLateAcceptanceWithoutActivating() = runBlocking {
        val (owner, channel, descriptor, peer) = connectedController()
        owner.start(peer)
        val request = channel.messages().last()
        owner.stop()
        assertEquals(PhoneInputState.IDLE, owner.state)

        owner.handle(descriptor, PhoneInputMessage.of(3, Cbor.Text(request.text(0)), Cbor.Integer(0)).encode())
        assertEquals(PhoneInputState.IDLE, owner.state)
        assertFalse(owner.active)
        assertEquals(listOf(9L, 10L), channel.messages().takeLast(2).map { it.kind })
    }

    @Test fun rejectsCommitsAboveTheNegotiatedLimitAndReleasesTheSession() = runBlocking {
        val (owner, channel, descriptor, peer) = connectedController(remoteTextBytes = 4)
        assertTrue(owner.start(peer))
        val request = channel.messages().last()
        owner.handle(descriptor, PhoneInputMessage.of(3, Cbor.Text(request.text(0)), Cbor.Integer(0)).encode())

        assertFalse(owner.sendText(PhoneInputTextPlan(listOf(PhoneInputTextAction.Commit("hello")))))
        assertEquals(PhoneInputState.IDLE, owner.state)
        assertEquals(listOf(9L, 10L), channel.messages().takeLast(2).map { it.kind })
    }

    private suspend fun connectedController(remoteEvents: Long = 7, remoteTextBytes: Long = 1024): TestSetup {
        val peer = DeviceIdentity(
            "00000000-0000-4000-8000-000000000001", "Test Mac", "macos", "unused", "unused",
        )
        val descriptor = ChannelDescriptor("test-channel", "ble", peer)
        val channel = FakeChannel(descriptor)
        val owner = PhoneInputController(Dispatchers.Unconfined)
        owner.available(channel)
        val capability = PhoneInputMessage.of(
            1, Cbor.Integer(remoteTextBytes), Cbor.Integer(remoteEvents),
        ).encode()
        owner.handle(descriptor, capability)
        return TestSetup(owner, channel, descriptor, peer)
    }

    private data class TestSetup(
        val owner: PhoneInputController,
        val channel: FakeChannel,
        val descriptor: ChannelDescriptor,
        val peer: DeviceIdentity,
    )

    private class FakeChannel(override val descriptor: ChannelDescriptor) : SecuredChannel {
        private val sent = mutableListOf<ByteArray>()
        var blocked = false
        override suspend fun sendData(bytes: ByteArray) {
            if (blocked) throw SessionBackpressure()
            sent += bytes.copyOf()
        }
        fun messages() = sent.mapNotNull(PhoneInputMessage::decode)
    }
}
