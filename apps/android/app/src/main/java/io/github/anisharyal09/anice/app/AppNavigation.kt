// SPDX-License-Identifier: GPL-3.0-or-later
// Preserves destination, nested routes and peer context independently of transport ownership.
package io.github.anisharyal09.anice.app

import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.listSaver

enum class AppDestination(val label: String) { Home("Home"), Devices("Devices"), Features("Features"), Favourites("Favourites"), Settings("Settings"), About("About");
    companion object { val primary = listOf(Home, Devices, Features, Favourites, Settings) }
}
enum class DeviceRoute { Overview, Pairing, Discovery }
enum class SettingsRoute { Overview, Identity, About }

// Only local presentation identifiers are persisted; feature support remains with its owner.
enum class AppFeature(val label: String) {
    Playback("Now Playing"), Files("Send files"), FindDevice("Find Device"), Clipboard("Clipboard");
    fun toggled(value: String): String {
        val saved = favourites(value).toMutableSet()
        if (!saved.add(this)) saved.remove(this)
        return entries.filter { it in saved }.joinToString(",") { it.name }
    }
    companion object {
        fun favourites(value: String): List<AppFeature> {
            val saved = value.split(',').toSet()
            return entries.filter { it.name in saved }
        }
    }
}

@Stable
class AppNavigation(destination: AppDestination = AppDestination.Home,
    route: DeviceRoute = DeviceRoute.Overview, focusedPeer: String? = null, settingsRoute: SettingsRoute = SettingsRoute.Overview) {
    var destination by mutableStateOf(destination)
    var route by mutableStateOf(route)
    var focusedPeer by mutableStateOf(focusedPeer)
    var featurePanel by mutableStateOf<AppFeature?>(null)
    var featureOrigin by mutableStateOf(AppDestination.Features)
    var mediaDetails by mutableStateOf(false)
    var findDetails by mutableStateOf(false)
    var settingsRoute by mutableStateOf(settingsRoute)
    var favouriteFeatures by mutableStateOf("")
    fun openFeature(feature: AppFeature) {
        featureOrigin = if (destination == AppDestination.Favourites) AppDestination.Favourites else AppDestination.Features
        featurePanel = feature
        findDetails = feature == AppFeature.FindDevice
        destination = AppDestination.Features
    }
    fun closeFeature() { featurePanel = null; findDetails = false; destination = featureOrigin }

    fun select(page: AppDestination, unpaired: Boolean) {
        destination = page
        if (page == AppDestination.Features || page == AppDestination.Favourites) { featurePanel = null; findDetails = false }
        if (page == AppDestination.Home) route = DeviceRoute.Overview
        if (page == AppDestination.Devices && unpaired) route = DeviceRoute.Pairing
    }
    fun openDevice(id: String) { focusedPeer = id; route = DeviceRoute.Overview; destination = AppDestination.Devices }
    fun pair() { route = DeviceRoute.Pairing; destination = AppDestination.Devices }
    fun paired() { route = DeviceRoute.Overview; destination = AppDestination.Home }
    fun back() {
        if (destination == AppDestination.Devices && route != DeviceRoute.Overview) route = DeviceRoute.Overview
        else if (destination == AppDestination.Features && featurePanel != null) closeFeature()
        else if (destination == AppDestination.Features && findDetails) findDetails=false
        else if (destination == AppDestination.Home && mediaDetails) mediaDetails=false
        else if (destination == AppDestination.Settings && settingsRoute != SettingsRoute.Overview) settingsRoute = SettingsRoute.Overview
        else destination = AppDestination.Home
    }
    companion object {
        val saver = listSaver<AppNavigation, String>(
            save = { listOf(it.destination.name, it.route.name, it.focusedPeer.orEmpty(), it.settingsRoute.name, it.mediaDetails.toString(), it.findDetails.toString(), it.favouriteFeatures, it.featurePanel?.name.orEmpty(), it.featureOrigin.name) },
            restore = { AppNavigation(AppDestination.valueOf(it[0]), DeviceRoute.valueOf(it[1]), it[2].ifEmpty { null }, SettingsRoute.valueOf(it.getOrNull(3) ?: SettingsRoute.Overview.name)).also { value -> value.mediaDetails=it.getOrNull(4)=="true"; value.findDetails=it.getOrNull(5)=="true"; value.favouriteFeatures=it.getOrNull(6).orEmpty(); value.featurePanel=AppFeature.entries.firstOrNull { feature -> feature.name == it.getOrNull(7) }; value.featureOrigin=AppDestination.entries.firstOrNull { page -> page.name == it.getOrNull(8) } ?: AppDestination.Features } })
    }
}
