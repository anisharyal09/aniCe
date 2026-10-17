// SPDX-License-Identifier: GPL-3.0-or-later
// Persists only credential-scoped clipboard consent, never clipboard content.
package io.github.anisharyal09.anice.features.clipboard

import android.content.SharedPreferences
import io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity

class ClipboardPreferences(private val storage: SharedPreferences? = null) {
    private val values = mutableMapOf<String, Boolean>()
    fun key(peer: DeviceIdentity) = peer.deviceId + ":" + peer.fingerprint
    fun enabled(peer: DeviceIdentity) = values.getOrPut(key(peer)) { storage?.getBoolean(key(peer), false) ?: false }
    fun set(peer: DeviceIdentity, enabled: Boolean) { values[key(peer)] = enabled; storage?.edit()?.putBoolean(key(peer), enabled)?.apply() }
    fun prune(peers: List<DeviceIdentity>) {
        val keep = peers.map(::key).toSet()
        values.keys.retainAll(keep)
        storage?.edit()?.also { editor -> storage.all.keys.filter { it !in keep }.forEach(editor::remove) }?.apply()
    }
    fun clear() { values.clear(); storage?.edit()?.clear()?.apply() }
}
