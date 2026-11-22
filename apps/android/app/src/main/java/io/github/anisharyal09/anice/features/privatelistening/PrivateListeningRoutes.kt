// SPDX-License-Identifier: GPL-3.0-or-later
// Separates private routes from explicitly consented built-in speaker playback; never trusts labels or ephemeral IDs.
package io.github.anisharyal09.anice.features.privatelistening

import android.media.AudioDeviceInfo

internal data class ListeningRoute(val type: Int, val address: String, val label: String) {
    val confirmationKey: String? get() = address.takeIf { it.isNotBlank() }?.let { "$type:$it" }
}

internal object PrivateListeningRoutes {
    fun privateOutput(route: ListeningRoute, confirmed: Set<String>): Boolean = when (route.type) {
        AudioDeviceInfo.TYPE_WIRED_HEADPHONES, AudioDeviceInfo.TYPE_WIRED_HEADSET,
        AudioDeviceInfo.TYPE_USB_HEADSET, AudioDeviceInfo.TYPE_BLE_HEADSET -> true
        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP, AudioDeviceInfo.TYPE_USB_DEVICE,
        AudioDeviceInfo.TYPE_USB_ACCESSORY -> route.confirmationKey?.let { it in confirmed } == true
        else -> false
    }

    fun approved(routes: List<ListeningRoute>, confirmed: Set<String>): Boolean =
        routes.isNotEmpty() && routes.all { privateOutput(it, confirmed) }

    fun permitted(routes: List<ListeningRoute>, confirmed: Set<String>, speakerFallback: Boolean): Boolean =
        routes.isNotEmpty() && routes.all {
            privateOutput(it, confirmed) || speakerFallback && it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER
        }
}
