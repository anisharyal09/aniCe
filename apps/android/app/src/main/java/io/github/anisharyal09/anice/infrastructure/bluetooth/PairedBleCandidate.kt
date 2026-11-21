// SPDX-License-Identifier: GPL-3.0-or-later
// Freezes the just-paired native locator for one fresh pinned session, never reusing pairing keys.
package io.github.anisharyal09.anice.infrastructure.bluetooth

import android.bluetooth.BluetoothDevice
import android.os.SystemClock
import io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity

internal class PairedBleCandidate(
    private var device: BluetoothDevice?,
    private val peer: DeviceIdentity,
    private val expiresAt: Long = SystemClock.elapsedRealtime() + 15_000,
) {
    fun take(selected: DeviceIdentity, now: Long = SystemClock.elapsedRealtime()): BluetoothDevice? {
        val candidate = device
        device = null
        if (!pairedBleCandidateMatches(peer, selected, expiresAt, now)) return null
        return candidate
    }
    fun discard() { device = null }
}

internal fun pairedBleCandidateMatches(peer: DeviceIdentity, selected: DeviceIdentity, expiresAt: Long, now: Long) =
    now < expiresAt && peer.deviceId == selected.deviceId &&
        peer.fingerprint == selected.fingerprint && peer.publicKey == selected.publicKey
