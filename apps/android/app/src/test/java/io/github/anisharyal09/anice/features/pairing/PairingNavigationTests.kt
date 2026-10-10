// SPDX-License-Identifier: GPL-3.0-or-later
// Verifies that pairing navigation cannot skip approval or expose pending, revoked or conflicting trust.
package io.github.anisharyal09.anice.features.pairing

import io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity
import io.github.anisharyal09.anice.infrastructure.pairing.PairingMethod
import io.github.anisharyal09.anice.infrastructure.pairing.PeerTrustRecord
import org.junit.Assert.*
import org.junit.Test

class PairingNavigationTests {
    private val peer = DeviceIdentity("mac-id", "My Mac", "macos", "key", "fingerprint")
    private val record = PeerTrustRecord(peer, "local", PairingMethod.QR, 1, byteArrayOf(), active = true)

    @Test fun approvalAndPendingStorageNeverFinishNavigation() {
        val unfinished = listOf("idle", "scan", "approval", "waiting", "saving", "cleanup", "failed")
        assertEquals(7, unfinished.size)
        unfinished.forEach { assertNull(completedPairingPeer(it, peer, "local", listOf(record))) }
        assertNull(completedPairingPeer("paired", peer, "local", listOf(record.copy(active = false))))
        assertEquals(peer, completedPairingPeer("paired", peer, "local", listOf(record)))
    }

    @Test fun revokedOrAmbiguousCredentialsNeverCompleteNavigation() {
        assertNull(completedPairingPeer("paired", peer, "local", emptyList()))
        assertNull(completedPairingPeer("paired", peer, "local", listOf(record, record)))
        assertNull(completedPairingPeer("paired", null, "local", listOf(record)))
        assertNull(completedPairingPeer("paired", peer, null, listOf(record)))
        val mismatches = listOf(record.copy(localFingerprint = "other"),
            record.copy(peer = peer.copy(deviceId = "other")),
            record.copy(peer = peer.copy(fingerprint = "other")),
            record.copy(peer = peer.copy(publicKey = "other")))
        assertEquals(4, mismatches.size)
        mismatches.forEach { assertNull(completedPairingPeer("paired", peer, "local", listOf(it))) }
        assertEquals(peer.copy(deviceName = "Renamed Mac"), completedPairingPeer("paired", peer, "local",
            listOf(record.copy(peer = peer.copy(deviceName = "Renamed Mac")))))
    }
}
