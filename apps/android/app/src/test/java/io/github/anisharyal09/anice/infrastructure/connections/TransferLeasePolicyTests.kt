// SPDX-License-Identifier: GPL-3.0-or-later
// Verifies picker and background leases never depend on a transiently selected transfer channel.
package io.github.anisharyal09.anice.infrastructure.connections

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TransferLeasePolicyTests {
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
        assertEquals(TransferLeases(true, false, false, false),
            transferLeases(null, connecting = false, backgroundAllowed = true,
                selectingFiles = false, bleSecured = false, paused = true))
        assertEquals(TransferLeases(true, false, false, false),
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
