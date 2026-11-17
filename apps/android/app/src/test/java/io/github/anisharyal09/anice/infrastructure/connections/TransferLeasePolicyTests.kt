// SPDX-License-Identifier: GPL-3.0-or-later
// Verifies picker and background leases never depend on a transiently selected transfer channel.
package io.github.anisharyal09.anice.infrastructure.connections

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlinx.coroutines.*

class TransferLeasePolicyTests {
    @Test fun concurrentProducerReleaseCannotLoseOrReviveWork() = runBlocking {
        val changes = java.util.concurrent.atomic.AtomicInteger()
        val leases = ConnectionWorkLeases { changes.incrementAndGet() }
        val owner = Any()
        leases.updateOwner(owner, true)
        (0..<64).map { index ->
            async(Dispatchers.Default) {
                val lease = leases.acquire(owner, "job-$index")
                yield()
                lease.close(); lease.close()
            }
        }.awaitAll()
        assertEquals(0, leases.count)
        assertEquals(128, changes.get())
    }

    @Test fun workIsReferenceCountedByNativeOwnerAndStaleReleaseCannotAffectReplacement() {
        var changes = 0
        val leases = ConnectionWorkLeases { changes++ }
        val transfer = Any(); val streaming = Any()
        try { leases.acquire(transfer, "unapproved"); org.junit.Assert.fail("Unowned work was accepted") }
        catch (_: IllegalStateException) {}
        leases.updateOwner(transfer, true); leases.updateOwner(streaming, true)
        val first = leases.acquire(transfer, "job")
        val second = leases.acquire(transfer, "job")
        val media = leases.acquire(streaming, "stream")
        assertEquals(3, leases.count)
        first.close(); first.close()
        assertEquals(2, leases.count)
        leases.updateOwner(transfer, false)
        assertEquals(1, leases.count); assertTrue(leases.held)
        leases.updateOwner(transfer, true)
        val replacement = leases.acquire(transfer, "job")
        second.close()
        assertEquals(2, leases.count)
        media.close()
        assertTrue(leases.held)
        replacement.close()
        assertFalse(leases.held)
        assertEquals(8, changes)
    }

    @Test fun workOwnerIdentityAndInventoryAreBounded() {
        data class Owner(val id: Int)
        val owner = Owner(1)
        val leases = ConnectionWorkLeases {}
        leases.updateOwner(owner, true)
        try { leases.acquire(Owner(1), "copy"); org.junit.Assert.fail("Value-equal owner manufactured ownership") }
        catch (_: IllegalStateException) {}
        val active = (0..<128).map { leases.acquire(owner, "job-$it") }
        assertEquals(128, leases.count)
        try { leases.acquire(owner, "overflow"); org.junit.Assert.fail("Unbounded work ownership") }
        catch (_: IllegalStateException) {}
        leases.clear()
        active.forEach { it.close() }
        assertEquals(0, leases.count)
    }

    @Test fun pickerLeasesEverySecuredTransportRegardlessOfActiveChannel() {
        for (transport in listOf(null, "lan", "ble")) {
            val leases = transferLeases(transport, connecting = false, backgroundAllowed = false,
                selectingFiles = true, bleSecured = true)
            assertTrue("LAN picker lease for $transport", leases.lanPicker)
            assertTrue("BLE picker lease for $transport", leases.blePicker)
            assertFalse(leases.lanWork)
            assertFalse(leases.bleWork)
        }
    }

    @Test fun pickerDoesNotLeaseATransportThatIsNotSecured() {
        val leases = transferLeases(null, connecting = false, backgroundAllowed = false,
            selectingFiles = true, bleSecured = false)
        assertTrue(leases.lanPicker)
        assertFalse(leases.blePicker)
    }

    @Test fun workLeaseFollowsTheActiveTransportAndLanConnecting() {
        assertEquals(TransferLeases(true, false, false, false),
            transferLeases("lan", connecting = false, backgroundAllowed = true,
                selectingFiles = false, bleSecured = true))
        assertEquals(TransferLeases(false, false, true, false),
            transferLeases("ble", connecting = false, backgroundAllowed = true,
                selectingFiles = false, bleSecured = true))
        assertEquals(TransferLeases(true, false, false, false),
            transferLeases(null, connecting = true, backgroundAllowed = true,
                selectingFiles = false, bleSecured = false))
    }

    @Test fun idleTransferKeepsASecuredBleFallbackButNeverStartsLanWork() {
        assertEquals(TransferLeases(false, false, true, false),
            transferLeases(null, connecting = false, backgroundAllowed = true,
                selectingFiles = false, bleSecured = true))
        assertEquals(TransferLeases(false, false, false, false),
            transferLeases(null, connecting = false, backgroundAllowed = true,
                selectingFiles = false, bleSecured = false))
        assertEquals(TransferLeases(false, false, false, false),
            transferLeases("lan", connecting = false, backgroundAllowed = false,
                selectingFiles = false, bleSecured = true))
    }

    @Test fun pausedTransferKeepsLanWorkSoAutomaticLanCanResume() {
        assertEquals(TransferLeases(true, false, true, false),
            transferLeases(null, connecting = false, backgroundAllowed = true,
                selectingFiles = false, bleSecured = false, paused = true))
        assertEquals(TransferLeases(true, false, true, false),
            transferLeases("lan", connecting = false, backgroundAllowed = true,
                selectingFiles = false, bleSecured = false, paused = true))
        // A still-secured BLE channel keeps its fallback lease while the batch waits.
        assertEquals(TransferLeases(true, false, true, false),
            transferLeases(null, connecting = false, backgroundAllowed = true,
                selectingFiles = false, bleSecured = true, paused = true))
        assertEquals(TransferLeases(false, false, false, false),
            transferLeases("lan", connecting = false, backgroundAllowed = false,
                selectingFiles = false, bleSecured = false, paused = true))
    }

    @Test fun activeBatchKeepsASecuredBleFallbackWhileLanStreams() {
        // The BLE session is what "Continue over Bluetooth" and a lost LAN fall back to; retiring it
        // when LAN becomes active turns a mid-batch fallback into a reconnect flicker.
        assertEquals(TransferLeases(true, false, true, false),
            transferLeases("lan", connecting = false, backgroundAllowed = true,
                selectingFiles = false, bleSecured = true, busy = true))
        assertEquals(TransferLeases(false, false, true, false),
            transferLeases(null, connecting = false, backgroundAllowed = true,
                selectingFiles = false, bleSecured = true, busy = true))
        assertEquals(TransferLeases(true, false, false, false),
            transferLeases("lan", connecting = false, backgroundAllowed = true,
                selectingFiles = false, bleSecured = false, busy = true))
        assertEquals(TransferLeases(false, false, false, false),
            transferLeases("lan", connecting = false, backgroundAllowed = false,
                selectingFiles = false, bleSecured = true, busy = true))
    }
}
