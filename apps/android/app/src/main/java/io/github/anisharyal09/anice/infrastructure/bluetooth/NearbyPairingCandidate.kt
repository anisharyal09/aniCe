// SPDX-License-Identifier: GPL-3.0-or-later
// Retains one freshly user-selected native locator for bounded handoff to the existing GATT owner.
package io.github.anisharyal09.anice.infrastructure.bluetooth

import android.bluetooth.BluetoothDevice
import android.os.SystemClock
import io.github.anisharyal09.anice.infrastructure.pairing.PairingSas

internal class NearbyPairingCandidate(
    private var device: BluetoothDevice?,
    private val deadline: Long = SystemClock.elapsedRealtime() + 15_000,
) {
    fun connect(transport: AndroidGattTransport) {
        val candidate = requireNotNull(device) { "Nearby candidate is no longer available" }
        device = null
        check(SystemClock.elapsedRealtime() < deadline) { "Nearby candidate expired; find nearby again" }
        transport.startCandidate(candidate, PairingSas.DISCOVERY_FLAG)
    }
    fun discard() { device = null }
}
