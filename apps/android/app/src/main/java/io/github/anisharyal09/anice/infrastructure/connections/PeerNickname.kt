// SPDX-License-Identifier: GPL-3.0-or-later
// Keeps private display overrides separate from peer identity and trust receipts.
package io.github.anisharyal09.anice.infrastructure.connections

import io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity

internal val DeviceIdentity.displayName: String get() = PeerNames.current?.displayName(this) ?: deviceName
internal val DeviceIdentity.knownDeviceName: String get() = PeerNames.current?.deviceName(this) ?: deviceName

internal data class PeerNickname(val name: String, val enabled: Boolean) {
    init {
        require(name == name.trim() && name.codePointCount(0, name.length) <= 64 &&
            (!enabled || name.isNotBlank()))
    }
    fun displayedName(peer: DeviceIdentity) = if (enabled && name.isNotBlank()) name else peer.deviceName
    companion object {
        fun credential(peer: DeviceIdentity) = peer.deviceId + ":" + peer.fingerprint + ":" + peer.publicKey
    }
}
