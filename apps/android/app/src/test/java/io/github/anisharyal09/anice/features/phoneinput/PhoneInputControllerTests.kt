// SPDX-License-Identifier: GPL-3.0-or-later
// Verifies BLE negotiation, accepted-session gating, ordered edits and cancellation release.
package io.github.anisharyal09.anice.features.phoneinput

import io.github.anisharyal09.anice.infrastructure.connections.ChannelDescriptor
import io.github.anisharyal09.anice.infrastructure.connections.SecuredChannel
import io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity
import io.github.anisharyal09.anice.infrastructure.session.Cbor
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PhoneInputControllerTests {
    @Test fun requiresTextAndKeyTransitionsForCorrectionSupport() = runBlocking {
        val setup = connectedController(remoteEvents = 0x01)
        assertEquals(3L, setup.channel.messages().first().number(1))
        assertFalse(setup.owner.compatible(setup.peer))
        assertFalse(setup.owner.start(setup.peer))
        assertEquals(PhoneInputState.IDLE, setup.owner.state)
        assertEquals(listOf(1L), setup.channel.messages().map { it.kind })
    }

    @Test fun commitsOnlyAfterAcceptanceAndStopsWithReleaseBeforeBoundary() = runBlocking {
        val (owner, channel, descriptor, peer) = connectedController()
        assertEquals(3L, channel.messages().first().number(1))
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
        override suspend fun sendData(bytes: ByteArray) { sent += bytes.copyOf() }
        fun messages() = sent.mapNotNull(PhoneInputMessage::decode)
    }
}
