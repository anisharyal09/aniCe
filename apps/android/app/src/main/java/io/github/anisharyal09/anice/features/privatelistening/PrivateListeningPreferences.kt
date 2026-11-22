// SPDX-License-Identifier: GPL-3.0-or-later
// Stores default-off listening consent bound to local and full peer credentials without persisting audio or sessions.
package io.github.anisharyal09.anice.features.privatelistening

import android.content.SharedPreferences
import io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity

class PrivateListeningPreferences(private val storage: SharedPreferences? = null) {
    private val consent = mutableMapOf<String, Boolean>()
    private var profile = ListeningBufferProfile.restored(storage?.getString("buffer_profile", null))

    internal fun bufferProfile() = profile

    internal fun setBufferProfile(value: ListeningBufferProfile) {
        check(storage?.edit()?.putString("buffer_profile", value.preference)?.commit() != false) {
            "Buffering preference could not be saved"
        }
        profile = value
    }

    private fun key(localFingerprint: String, peer: DeviceIdentity): String =
        "receive:$localFingerprint:${peer.deviceId}:${peer.fingerprint}:${peer.publicKey}"

    private val speakers = mutableMapOf<String, Boolean>()
    internal fun speakerFallback(localFingerprint: String, peer: DeviceIdentity): Boolean =
        speakers.getOrPut(key(localFingerprint, peer)) {
            storage?.getBoolean("speaker:" + key(localFingerprint, peer), false) ?: false
        }

    internal fun setSpeakerFallback(localFingerprint: String, peer: DeviceIdentity, enabled: Boolean) {
        require(localFingerprint.isNotEmpty())
        val key = key(localFingerprint, peer)
        check(storage?.edit()?.putBoolean("speaker:$key", enabled)?.commit() != false) {
            "Speaker fallback preference could not be saved"
        }
        speakers[key] = enabled
    }

    fun enabled(localFingerprint: String, peer: DeviceIdentity): Boolean =
        consent.getOrPut(key(localFingerprint, peer)) {
            storage?.getBoolean(key(localFingerprint, peer), false) ?: false
        }

    fun set(localFingerprint: String, peer: DeviceIdentity, enabled: Boolean) {
        require(localFingerprint.isNotEmpty())
        val key = key(localFingerprint, peer)
        // Persist before publishing consent; a failed write cannot silently authorize background playback.
        check(storage?.edit()?.putBoolean(key, enabled)?.commit() != false) { "Listening consent could not be saved" }
        consent[key] = enabled
    }

    fun clear() {
        check(storage?.edit()?.clear()?.commit() != false) { "Listening consent could not be cleared" }
        consent.clear()
        speakers.clear()
        profile = ListeningBufferProfile.BALANCED
    }
}
