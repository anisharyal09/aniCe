// SPDX-License-Identifier: GPL-3.0-or-later
// Preserves destination, nested routes and peer context independently of transport ownership.
package io.github.anisharyal09.anice.app

import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.listSaver

enum class AppDestination(val label: String) { Home("Home"), Devices("Devices"), Features("Features"), Favourites("Favourites"), Settings("Settings"), About("About");
    companion object { val primary = listOf(Home, Devices, Features, Favourites, Settings) }
}
enum class DeviceRoute { Overview, Pairing, Discovery }
enum class SettingsRoute { Overview, Identity, NotificationApps, About }

// Only local presentation identifiers are persisted; feature support remains with its owner.
enum class AppFeature(val label: String) {
    Playback("Now Playing"), Files("Send files"), FindDevice("Find Device"), Clipboard("Clipboard"), DeskDeck("Mac Desk Deck"),
    PhoneInput("Control Mac"), Sms("Messages");
    fun toggled(value: String): String {
        val saved = favourites(value).toMutableList()
        if (!saved.remove(this)) saved.add(this)
        return saved.joinToString(",") { it.name }
    }
    companion object {
        fun favourites(value: String): List<AppFeature> {
            return value.split(',').mapNotNull { name -> entries.firstOrNull { it.name == name } }.distinct()
        }
        fun ordered(value: String): List<AppFeature> {
            val saved = value.split(',').mapNotNull { name -> entries.firstOrNull { it.name == name } }.distinct()
            return saved + entries.filterNot(saved::contains)
        }
        fun moved(feature: AppFeature, rows: List<AppFeature>, offset: Int): String {
            val reordered = rows.toMutableList()
            val from = reordered.indexOf(feature)
            if (from < 0 || reordered.size < 2) return reordered.joinToString(",") { it.name }
            val to = (from + offset).coerceIn(0, reordered.lastIndex)
            reordered.add(to, reordered.removeAt(from))
            return reordered.joinToString(",") { it.name }
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
    var featureOrder by mutableStateOf("")
    fun openFeature(feature: AppFeature) {
        if (destination != AppDestination.Features || featurePanel == null) {
            featureOrigin = when (destination) {
                AppDestination.Home, AppDestination.Favourites -> destination
                else -> AppDestination.Features
            }
        }
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
            save = { listOf(it.destination.name, it.route.name, it.focusedPeer.orEmpty(), it.settingsRoute.name, it.mediaDetails.toString(), it.findDetails.toString(), it.favouriteFeatures, it.featurePanel?.name.orEmpty(), it.featureOrigin.name, it.featureOrder) },
            restore = { saved ->
                // Older saved state can still point at the removed Permissions destination.
                val settingsRoute = SettingsRoute.entries.firstOrNull { it.name == saved.getOrNull(3) }
                    ?: SettingsRoute.Overview
                AppNavigation(
                    AppDestination.valueOf(saved[0]),
                    DeviceRoute.valueOf(saved[1]),
                    saved[2].ifEmpty { null },
                    settingsRoute,
                ).also { value ->
                    value.mediaDetails = saved.getOrNull(4) == "true"
                    value.findDetails = saved.getOrNull(5) == "true"
                    value.favouriteFeatures = saved.getOrNull(6).orEmpty()
                    value.featurePanel = AppFeature.entries.firstOrNull { feature -> feature.name == saved.getOrNull(7) }
                    value.featureOrigin = AppDestination.entries.firstOrNull { page -> page.name == saved.getOrNull(8) }
                        ?: AppDestination.Features
                    value.featureOrder = saved.getOrNull(9).orEmpty()
                }
            }
        )
    }
}
