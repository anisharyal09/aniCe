// SPDX-License-Identifier: GPL-3.0-or-later
// Checks one-step comparison selection and authenticated chooser scoping without BLE or OS enrollment.
package io.github.anisharyal09.anice.infrastructure.connections

import io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity
import io.github.anisharyal09.anice.infrastructure.bluetooth.pairedBleCandidateMatches
import io.github.anisharyal09.anice.infrastructure.session.*
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test

class ProximitySetupTests {
    @Test fun firstPermissionPromptRequiresUnpairedForegroundAndNoPriorRequestOrDenial() {
        var prompts = 0
        for (eligible in listOf(false, true)) for (missing in listOf(false, true))
            for (requested in listOf(false, true)) for (denied in listOf(false, true)) {
                val ready = initialNearbyPermissionReady(eligible, missing, requested, denied)
                assertEquals(eligible && missing && !requested && !denied, ready)
                if (ready) prompts++
            }
        assertEquals(1, prompts)
    }
    @Test fun immediateBleHandoffPinsCredentialsAndExpiresWithoutRetargeting() {
        val mac = DeviceIdentity("id", "Mac", "macos", "key", "fingerprint")
        assertTrue(pairedBleCandidateMatches(mac, mac.copy(deviceName = "Renamed"), 15_000, 14_999))
        for (changed in listOf(mac.copy(deviceId = "other"), mac.copy(fingerprint = "other"),
            mac.copy(publicKey = "other"))) assertFalse(pairedBleCandidateMatches(mac, changed, 15_000, 0))
        assertFalse(pairedBleCandidateMatches(mac, mac, 15_000, 15_000))
    }
    @Test fun oneCandidateStartsOnlyOneComparison() {
        val policy = NearbyComparisonPolicy()
        assertNull(policy.candidate(emptyList(), true, false))
        assertEquals(1L, policy.candidate(listOf(1), true, false))
        assertNull(policy.candidate(listOf(1), true, false))
        assertNull(policy.candidate(listOf(2), true, false))
    }
    @Test fun multipleCandidatesRequireSelectionEvenAfterOneDisappears() {
        val policy = NearbyComparisonPolicy()
        assertNull(policy.candidate(listOf(1, 2), true, false))
        assertFalse(policy.allowsAutomatic)
        assertNull(policy.candidate(listOf(1), true, false))
        policy.reset()
        assertEquals(1L, policy.candidate(listOf(1), true, false))
    }
    @Test fun dismissalAndForegroundLossNeverStartAnExchange() {
        val policy = NearbyComparisonPolicy()
        assertNull(policy.candidate(listOf(1), false, false))
        assertNull(policy.candidate(listOf(1), true, true))
        assertEquals(1L, policy.candidate(listOf(1), true, false))
    }
    @Test fun setupTargetRequiresTheSameCredentialChannelAndDeadline() {
        val peer = DeviceIdentity("id", "Mac", "macos", "key", "fingerprint")
        val target = CompanionSetupTarget(peer, "02:00:00:00:00:01", "channel-1", 60_000)
        assertTrue(target.matches(peer.copy(deviceName = "New name"), "channel-1", 59_999))
        for (changed in listOf(null, peer.copy(deviceId = "other"), peer.copy(fingerprint = "other"),
            peer.copy(publicKey = "other"))) assertFalse(target.matches(changed, "channel-1", 0))
        assertFalse(target.matches(peer, "channel-2", 0))
        assertFalse(target.matches(peer, "channel-1", 60_000))
    }
    @Test fun setupWireEnforcesDurationsAndExactShapes() {
        for (message in listOf(CompanionSetupMessage(1), CompanionSetupMessage(2, seconds = 60),
            CompanionSetupMessage(2), CompanionSetupMessage(3, true), CompanionSetupMessage(3, false))) {
            assertEquals(message, CompanionSetupMessage.decode(message.encode()))
        }
        assertThrows(IllegalArgumentException::class.java) { CompanionSetupMessage(2, seconds = 61).encode() }
        val extra = SessionCbor.encode(Cbor.Array(listOf(Cbor.Text(CompanionSetupMessage.TAG), Cbor.Integer(1),
            Cbor.Integer(2), Cbor.Array(listOf(Cbor.Integer(60), Cbor.Integer(60))))))
        assertThrows(IllegalArgumentException::class.java) { CompanionSetupMessage.decode(extra) }
        assertNull(CompanionSetupMessage.decode(SessionCbor.encode(Cbor.Array(listOf(Cbor.Text("other"))))))
        val messages = listOf(CompanionSetupMessage(1), CompanionSetupMessage(2, seconds = 60),
            CompanionSetupMessage(2), CompanionSetupMessage(3, true), CompanionSetupMessage(3, false))
        assertEquals(listOf("8475616e69436520636f6d70616e696f6e20736574757001018101",
            "8475616e69436520636f6d70616e696f6e207365747570010281183c",
            "8475616e69436520636f6d70616e696f6e20736574757001028100",
            "8475616e69436520636f6d70616e696f6e207365747570010381f5",
            "8475616e69436520636f6d70616e696f6e207365747570010381f4"),
            messages.map { it.encode().joinToString("") { byte -> "%02x".format(byte.toInt() and 255) } })
    }

    private val peer = DeviceIdentity("id", "Mac", "macos", "key", "fingerprint")
    private class Link(override val descriptor: ChannelDescriptor) : SecuredChannel {
        val messages = mutableListOf<CompanionSetupMessage>()
        var submit: suspend (CompanionSetupMessage) -> Unit = {}
        override suspend fun sendData(bytes: ByteArray) {
            val message = requireNotNull(CompanionSetupMessage.decode(bytes))
            submit(message)
            messages.add(message)
        }
    }
    private fun link(id: String = "one", transport: String = "ble") = Link(ChannelDescriptor(id, transport, peer))
    private fun target(link: Link, expires: Long = 60_000) =
        CompanionSetupTarget(peer, "02:00:00:00:00:01", link.descriptor.instance, expires)

    @Test fun capabilityIsSentOnAvailabilityAndForeignTransportDoesNotSwallowOtherFeatures() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        try {
            val owner = CompanionSetupLink(scope) { 0 }
            val ble = link()
            owner.available(ble)
            assertEquals(listOf(CompanionSetupMessage(1)), ble.messages)
            val lan = link("lan", "lan")
            owner.available(lan)
            assertTrue(lan.messages.isEmpty())
            assertEquals(DataHandling.UNRECOGNIZED,
                owner.handle(lan.descriptor, NameWire.encode()))
            assertEquals(DataHandling.DISCARDED,
                owner.handle(lan.descriptor, CompanionSetupMessage(1).encode()))
            assertEquals(DataHandling.DISCARDED,
                owner.handle(ble.descriptor, CompanionSetupMessage(2, seconds = 60).encode()))
            assertEquals(DataHandling.DISCARDED,
                owner.handle(ble.descriptor, CompanionSetupMessage(3, true).encode()))
        } finally { scope.cancel() }
    }

    @Test fun onePreparationWaitsForCapabilityAndRejectsConcurrentSetup() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        try {
            val owner = CompanionSetupLink(scope) { 0 }
            val ble = link()
            owner.available(ble)
            val preparation = async(start = CoroutineStart.UNDISPATCHED) { owner.prepare(target(ble)) }
            assertFalse(owner.prepare(target(ble)))
            ble.submit = { message ->
                if (message.kind == 2L)
                    owner.handle(ble.descriptor, CompanionSetupMessage(3, true).encode())
            }
            owner.handle(ble.descriptor, CompanionSetupMessage(1).encode())
            assertTrue(withTimeout(1000) { preparation.await() })
            assertEquals(listOf(1L, 2L), ble.messages.map { it.kind })
            owner.finish(target(ble))
            assertEquals(CompanionSetupMessage(2), ble.messages.last())
        } finally { scope.cancel() }
    }

    @Test fun backpressureWaitsForSuccessfulLocalCapabilityBeforeOpeningWindow() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        try {
            val owner = CompanionSetupLink(scope) { 0 }
            val ble = link()
            ble.submit = { throw SessionBackpressure() }
            owner.available(ble)
            owner.handle(ble.descriptor, CompanionSetupMessage(1).encode())
            val preparation = async(start = CoroutineStart.UNDISPATCHED) { owner.prepare(target(ble)) }
            assertFalse(preparation.isCompleted)
            assertTrue(ble.messages.isEmpty())
            ble.submit = { message ->
                if (message.kind == 2L)
                    owner.handle(ble.descriptor, CompanionSetupMessage(3, true).encode())
            }
            owner.capacityAvailable(ble.descriptor)
            assertTrue(withTimeout(1000) { preparation.await() })
            assertEquals(listOf(1L, 2L), ble.messages.map { it.kind })
        } finally { scope.cancel() }
    }

    @Test fun replacementAndExpiryFencePendingPreparationAndFinish() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        try {
            var now = 0L
            val owner = CompanionSetupLink(scope) { now }
            val old = link()
            owner.available(old)
            val preparation = async(start = CoroutineStart.UNDISPATCHED) {
                try { owner.prepare(target(old)) } catch (_: CancellationException) { false }
            }
            val next = link("two")
            owner.available(next)
            assertFalse(withTimeout(1000) { preparation.await() })
            owner.retired(old.descriptor)
            owner.finish(target(old))
            assertEquals(listOf(1L), next.messages.map { it.kind })
            owner.handle(next.descriptor, CompanionSetupMessage(1).encode())
            now = 60_000
            assertFalse(owner.prepare(target(next)))
            assertEquals(listOf(1L), next.messages.map { it.kind })
        } finally { scope.cancel() }
    }
}
