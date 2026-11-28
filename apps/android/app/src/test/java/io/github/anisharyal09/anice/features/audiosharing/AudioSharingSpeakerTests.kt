// SPDX-License-Identifier: GPL-3.0-or-later
// Checks explicit speaker authorization without opening native audio or changing device settings.
package io.github.anisharyal09.anice.features.audiosharing

import android.media.AudioDeviceInfo
import io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity
import org.junit.Assert.*
import org.junit.Test

class AudioSharingSpeakerTests {
    private val speaker = ListeningRoute(AudioDeviceInfo.TYPE_BUILTIN_SPEAKER, "", "Phone")
    private val headphones = ListeningRoute(AudioDeviceInfo.TYPE_WIRED_HEADPHONES, "", "Headphones")

    @Test fun defaultPrivateRoutingStillRejectsSpeakers() {
        assertFalse(AudioSharingRoutes.approved(listOf(speaker), emptySet()))
        assertFalse(AudioSharingRoutes.permitted(listOf(speaker), emptySet(), false))
        assertTrue(AudioSharingRoutes.permitted(listOf(headphones), emptySet(), false))
        assertTrue(AudioSharingRoutes.permitted(listOf(speaker), emptySet(), true))
    }

    @Test fun fallbackNeverAuthorizesUnknownBluetoothOrExternalSpeakers() {
        for (type in listOf(AudioDeviceInfo.TYPE_UNKNOWN, AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
            AudioDeviceInfo.TYPE_HDMI, AudioDeviceInfo.TYPE_BUILTIN_EARPIECE)) {
            val route = ListeningRoute(type, "unknown", "Headphones")
            assertFalse(AudioSharingRoutes.permitted(listOf(route), emptySet(), true))
            assertFalse(AudioSharingRoutes.permitted(listOf(speaker, route), emptySet(), true))
        }
        assertFalse(AudioSharingRoutes.permitted(emptyList(), emptySet(), true))
    }

    @Test fun speakerFallbackDefaultsOnAndRemembersOffPerCredential() {
        val preferences = AudioSharingPreferences()
        val peer = DeviceIdentity("01234567-89ab-4cde-8fab-0123456789ab", "Mac", "macos", "key", "a".repeat(64))
        val local = "b".repeat(64)
        assertTrue(preferences.speakerFallback(local, peer))
        preferences.setSpeakerFallback(local, peer, false)
        assertFalse(preferences.speakerFallback(local, peer))
        assertTrue(preferences.enabled(local, peer))
        assertTrue(preferences.speakerFallback("c".repeat(64), peer))
        assertTrue(preferences.speakerFallback(local, peer.copy(publicKey = "replacement")))
    }
}
