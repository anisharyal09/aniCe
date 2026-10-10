// SPDX-License-Identifier: GPL-3.0-or-later
// Returns completed pairing to device controls only after the matching active trust record is visible.
package io.github.anisharyal09.anice.features.pairing

import io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity
import io.github.anisharyal09.anice.infrastructure.pairing.PeerTrustRecord

internal fun completedPairingPeer(phase: String, peer: DeviceIdentity?, localFingerprint: String?,
    records: List<PeerTrustRecord>): DeviceIdentity? {
    if (phase != "paired" || peer == null || localFingerprint == null) return null
    return records.singleOrNull {
        it.active && it.localFingerprint == localFingerprint &&
            it.peer.deviceId == peer.deviceId && it.peer.fingerprint == peer.fingerprint &&
            it.peer.publicKey == peer.publicKey
    }?.peer
}
