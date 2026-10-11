// SPDX-License-Identifier: GPL-3.0-or-later
// Preserves destination, nested routes and peer context independently of transport ownership.
package io.github.anisharyal09.anice.app

import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.listSaver

enum class AppDestination(val label: String) { Home("Home"), Devices("Devices"), Features("Features"), Settings("Settings") }
enum class DeviceRoute { Overview, Pairing, Discovery }
enum class SettingsRoute { Overview, Identity }

@Stable
class AppNavigation(destination: AppDestination = AppDestination.Home,
    route: DeviceRoute = DeviceRoute.Overview, focusedPeer: String? = null, settingsRoute: SettingsRoute = SettingsRoute.Overview) {
    var destination by mutableStateOf(destination)
    var route by mutableStateOf(route)
    var focusedPeer by mutableStateOf(focusedPeer)
    var mediaDetails by mutableStateOf(false)
    var settingsRoute by mutableStateOf(settingsRoute)
    fun select(page: AppDestination, unpaired: Boolean) {
        destination = page
        if (page == AppDestination.Devices && unpaired) route = DeviceRoute.Pairing
    }
    fun openDevice(id: String) { focusedPeer = id; route = DeviceRoute.Overview; destination = AppDestination.Devices }
    fun pair() { route = DeviceRoute.Pairing; destination = AppDestination.Devices }
    fun paired() { route = DeviceRoute.Overview; destination = AppDestination.Home }
    fun back() {
        if (destination == AppDestination.Devices && route != DeviceRoute.Overview) route = DeviceRoute.Overview
        else if (destination == AppDestination.Features && mediaDetails) mediaDetails=false
        else if (destination == AppDestination.Settings && settingsRoute != SettingsRoute.Overview) settingsRoute = SettingsRoute.Overview
        else destination = AppDestination.Home
    }
    companion object {
        val saver = listSaver<AppNavigation, String>(
            save = { listOf(it.destination.name, it.route.name, it.focusedPeer.orEmpty(), it.settingsRoute.name, it.mediaDetails.toString()) },
            restore = { AppNavigation(AppDestination.valueOf(it[0]), DeviceRoute.valueOf(it[1]), it[2].ifEmpty { null }, SettingsRoute.valueOf(it.getOrNull(3) ?: SettingsRoute.Overview.name)).also { value -> value.mediaDetails=it.getOrNull(4)=="true" } })
    }
}
