// SPDX-License-Identifier: GPL-3.0-or-later
// Checks explicit speaker authorization without opening native audio or changing device settings.
package io.github.anisharyal09.anice.features.privatelistening

import android.media.AudioDeviceInfo
import io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity
import org.junit.Assert.*
import org.junit.Test

class PrivateListeningSpeakerTests {
    private val speaker = ListeningRoute(AudioDeviceInfo.TYPE_BUILTIN_SPEAKER, "", "Phone")
    private val headphones = ListeningRoute(AudioDeviceInfo.TYPE_WIRED_HEADPHONES, "", "Headphones")

    @Test fun defaultPrivateRoutingStillRejectsSpeakers() {
        assertFalse(PrivateListeningRoutes.approved(listOf(speaker), emptySet()))
        assertFalse(PrivateListeningRoutes.permitted(listOf(speaker), emptySet(), false))
        assertTrue(PrivateListeningRoutes.permitted(listOf(headphones), emptySet(), false))
        assertTrue(PrivateListeningRoutes.permitted(listOf(speaker), emptySet(), true))
    }

    @Test fun fallbackNeverAuthorizesUnknownBluetoothOrExternalSpeakers() {
        for (type in listOf(AudioDeviceInfo.TYPE_UNKNOWN, AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
            AudioDeviceInfo.TYPE_HDMI, AudioDeviceInfo.TYPE_BUILTIN_EARPIECE)) {
            val route = ListeningRoute(type, "unknown", "Headphones")
            assertFalse(PrivateListeningRoutes.permitted(listOf(route), emptySet(), true))
            assertFalse(PrivateListeningRoutes.permitted(listOf(speaker, route), emptySet(), true))
        }
        assertFalse(PrivateListeningRoutes.permitted(emptyList(), emptySet(), true))
    }

    @Test fun speakerConsentIsDefaultOffAndFullCredentialScoped() {
        val preferences = PrivateListeningPreferences()
        val peer = DeviceIdentity("01234567-89ab-4cde-8fab-0123456789ab", "Mac", "macos", "key", "a".repeat(64))
        val local = "b".repeat(64)
        assertFalse(preferences.speakerFallback(local, peer))
        preferences.setSpeakerFallback(local, peer, true)
        assertTrue(preferences.speakerFallback(local, peer))
        assertFalse(preferences.enabled(local, peer))
        assertFalse(preferences.speakerFallback("c".repeat(64), peer))
        assertFalse(preferences.speakerFallback(local, peer.copy(publicKey = "replacement")))
        preferences.clear()
        assertFalse(preferences.speakerFallback(local, peer))
    }
}
