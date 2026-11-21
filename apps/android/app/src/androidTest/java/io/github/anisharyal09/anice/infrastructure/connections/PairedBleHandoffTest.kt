// SPDX-License-Identifier: GPL-3.0-or-later
// Checks one-use native post-pair locators without connecting a radio or changing device identity/trust.
package io.github.anisharyal09.anice.infrastructure.connections

import android.annotation.SuppressLint
import android.bluetooth.BluetoothManager
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.github.anisharyal09.anice.infrastructure.bluetooth.PairedBleCandidate
import io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class PairedBleHandoffTest {
    @SuppressLint("MissingPermission")
    @Test fun locatorIsConsumedOnceAndCannotSurviveMismatchExpiryOrDiscard() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val adapter = context.getSystemService(BluetoothManager::class.java)?.adapter
        assumeTrue(adapter != null)
        // Creating a BluetoothDevice handle performs no scan, connection, association or bonding.
        val device = requireNotNull(adapter).getRemoteDevice("02:00:00:00:00:01")
        val peer = DeviceIdentity("fixture", "Fixture Mac", "macos", "key", "fingerprint")
        val candidate = PairedBleCandidate(device, peer, 15_000)
        assertSame(device, candidate.take(peer.copy(deviceName = "Renamed"), now = 14_999))
        assertNull(candidate.take(peer, now = 0))
        val mismatch = PairedBleCandidate(device, peer, 15_000)
        assertNull(mismatch.take(peer.copy(publicKey = "other"), now = 0))
        assertNull(mismatch.take(peer, now = 0))
        assertNull(PairedBleCandidate(device, peer, 15_000).take(peer, now = 15_000))
        val discarded = PairedBleCandidate(device, peer, 15_000)
        discarded.discard()
        assertNull(discarded.take(peer, now = 0))
    }
}
