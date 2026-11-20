// SPDX-License-Identifier: GPL-3.0-or-later
// Binds a native companion chooser to one currently authenticated BLE connection, never an arbitrary locator.
package io.github.anisharyal09.anice.infrastructure.connections

import io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity

internal data class CompanionSetupTarget(
    val peer: DeviceIdentity,
    val address: String,
    val channel: String,
    val expiresAt: Long,
) {
    fun matches(selected: DeviceIdentity?, channel: String?, now: Long): Boolean =
        now < expiresAt && this.channel == channel && companionSetupPeerMatches(peer, selected)
}

internal fun companionSetupPeerMatches(expected: DeviceIdentity, selected: DeviceIdentity?): Boolean =
    selected?.deviceId == expected.deviceId && selected.fingerprint == expected.fingerprint &&
        selected.publicKey == expected.publicKey
