// SPDX-License-Identifier: GPL-3.0-or-later
// Pins simultaneous transport owners to one peer credential and local identity.
package io.github.anisharyal09.anice.infrastructure.session

import io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity
import kotlinx.coroutines.flow.MutableStateFlow

class SessionPeerReservation {
    private data class Credential(val id: String, val fingerprint: String, val key: String)

    private data class Binding(val peer: Credential, val local: String)

    private val owners = mutableMapOf<Any, Binding>()
    val changes = MutableStateFlow(0L)

    private fun credential(peer: DeviceIdentity) =
        Credential(peer.deviceId, peer.fingerprint, peer.publicKey)

    @Synchronized
    fun permits(peer: DeviceIdentity): Boolean = owners.values.all { it.peer == credential(peer) }

    @Synchronized
    fun acquire(owner: Any, peer: DeviceIdentity, localFingerprint: String): Boolean {
        val binding = Binding(credential(peer), localFingerprint)
        if (owners.values.any { it != binding }) return false
        owners[owner] = binding
        changes.value++
        return true
    }

    @Synchronized
    fun release(owner: Any) {
        if (owners.remove(owner) != null) changes.value++
    }
}
