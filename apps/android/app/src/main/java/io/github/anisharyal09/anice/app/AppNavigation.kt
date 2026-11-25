// SPDX-License-Identifier: GPL-3.0-or-later
// Preserves destination, nested routes and peer context independently of transport ownership.
package io.github.anisharyal09.anice.app

import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.listSaver

enum class AppDestination(val label: String) { Home("Home"), Devices("Devices"), Features("Features"), Favourites("Favourites"), Settings("Settings"), About("About"), Guide("Guide");
    companion object { val primary = listOf(Home, Devices, Features, Favourites, Settings) }
}
enum class DeviceRoute { Overview, Pairing, Discovery }
enum class SettingsRoute { Overview, Identity, NotificationApps, About }

enum class GuideCategory(val label: String) {
    All("All"), Connect("Connect"), ShareAndFiles("Share & Files"), Control("Control"), SyncAndAlerts("Sync & Alerts")
}

enum class GuideTopic(val category: GuideCategory) {
    PairingAndConnection(GuideCategory.Connect),
    Permissions(GuideCategory.Connect),
    OpenLinkInMac(GuideCategory.ShareAndFiles),
    FilesAndEdgeDrop(GuideCategory.ShareAndFiles),
    ClipboardAndQuickSend(GuideCategory.ShareAndFiles),
    PasteTrayAndPins(GuideCategory.ShareAndFiles),
    ControlMac(GuideCategory.Control),
    ControlAndroidAndFloatingKey(GuideCategory.Control),
    MacDeskDeck(GuideCategory.Control),
    NowPlayingAndAudio(GuideCategory.Control),
    MessagesAndSms(GuideCategory.SyncAndAlerts),
    NotificationsAndCalls(GuideCategory.SyncAndAlerts),
    DndSync(GuideCategory.SyncAndAlerts),
    FindDeviceAndPing(GuideCategory.SyncAndAlerts),
    CompanionAndShortcuts(GuideCategory.SyncAndAlerts)
}

enum class SettingsCategory(val label: String) {
    All("All"), General("General"), Permissions("Permissions"), Features("Features"), Shortcuts("Shortcuts");

    companion object {
        // Shortcuts remains decodable from older saved UI state but is no longer a phone category.
        val visibleEntries = listOf(All, General, Permissions, Features)
        fun forSection(title: String): SettingsCategory = when (title) {
            "Appearance", "Updates", "Connection", "This device" -> General
            "Permissions" -> Permissions
            "Shortcuts" -> All
            else -> Features
        }
    }
}

internal fun comparisonUsesDeviceSheet(destination: AppDestination, route: DeviceRoute): Boolean =
    route == DeviceRoute.Pairing && destination in listOf(AppDestination.Home, AppDestination.Devices)

internal fun showsAppBarBack(destination: AppDestination, route: DeviceRoute,
    settingsRoute: SettingsRoute, featurePanel: AppFeature?): Boolean =
    destination == AppDestination.About ||
        destination == AppDestination.Guide ||
        (destination == AppDestination.Devices && route !in listOf(DeviceRoute.Overview, DeviceRoute.Pairing)) ||
        (destination == AppDestination.Settings && settingsRoute != SettingsRoute.Overview) ||
        (destination == AppDestination.Features && featurePanel != null)

// Only local presentation identifiers are persisted; feature support remains with its owner.
enum class AppFeature(val label: String) {
    PhoneInput("Control Mac"), DeskDeck("Mac Desk Deck"), Files("Send files"), Clipboard("Clipboard"),
    Playback("Now Playing"), Sms("Messages");
    fun toggled(value: String): String {
        val saved = favourites(value).toMutableList()
        if (!saved.remove(this)) saved.add(this)
        return saved.joinToString(",") { it.name }
    }
    companion object {
        const val DEFAULT_FAVOURITES = "PhoneInput,DeskDeck,Clipboard"
        // The former launcher is a local route alias, not a new Find Device protocol action.
        fun stored(name: String?): AppFeature? =
            if (name == "FindDevice") DeskDeck else entries.firstOrNull { it.name == name }
        fun favourites(value: String): List<AppFeature> {
            return value.split(',').mapNotNull(::stored).distinct()
        }
        // Keep unrecognized saved identifiers; rendering ignores them without erasing another build's shortcuts.
        fun migrateStored(value: String): String = value.split(',').filter(String::isNotEmpty)
            .map { if (it == "FindDevice") DeskDeck.name else it }.distinct().joinToString(",")
        fun favouritePreference(value: String?): String = migrateStored(value ?: DEFAULT_FAVOURITES)
        fun ordered(value: String): List<AppFeature> {
            val saved = favourites(value)
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
    var settingsRoute by mutableStateOf(settingsRoute)
    var favouriteFeatures by mutableStateOf(AppFeature.DEFAULT_FAVOURITES)
    var featureOrder by mutableStateOf("")
    var settingsSection by mutableStateOf<String?>(null)
    var guideTopic by mutableStateOf<GuideTopic?>(null)
    var guideOrigin by mutableStateOf(AppDestination.Home)
    var guideOriginRoute by mutableStateOf(DeviceRoute.Overview)
    var guideOriginSettingsRoute by mutableStateOf(SettingsRoute.Overview)
    var guideOriginFeature by mutableStateOf<AppFeature?>(null)

    fun openSettings(section: String) {
        settingsSection = section
        settingsRoute = SettingsRoute.Overview
        destination = AppDestination.Settings
    }
    fun openFeature(feature: AppFeature) {
        if (destination != AppDestination.Features || featurePanel == null) {
            featureOrigin = when (destination) {
                AppDestination.Home, AppDestination.Favourites -> destination
                else -> AppDestination.Features
            }
        }
        featurePanel = feature
        destination = AppDestination.Features
    }
    fun closeFeature() { featurePanel = null; destination = featureOrigin }

    fun openGuide(topic: GuideTopic? = null) {
        if (destination != AppDestination.Guide) {
            guideOrigin = destination
            guideOriginRoute = route
            guideOriginSettingsRoute = settingsRoute
            guideOriginFeature = featurePanel
        }
        guideTopic = topic
        destination = AppDestination.Guide
    }

    fun select(page: AppDestination, unpaired: Boolean) {
        destination = page
        if (page == AppDestination.Features || page == AppDestination.Favourites) featurePanel = null
        if (page == AppDestination.Home) route = DeviceRoute.Overview
        if (page == AppDestination.Devices && unpaired) route = DeviceRoute.Pairing
    }
    fun openDevice(id: String) { focusedPeer = id; route = DeviceRoute.Overview; destination = AppDestination.Devices }
    fun pair() { route = DeviceRoute.Pairing; destination = AppDestination.Devices }
    fun paired() { route = DeviceRoute.Overview; destination = AppDestination.Home }
    fun back() {
        if (destination == AppDestination.Guide) {
            destination = guideOrigin
            route = guideOriginRoute
            settingsRoute = guideOriginSettingsRoute
            featurePanel = guideOriginFeature
            guideTopic = null
        } else if (destination == AppDestination.Devices && route != DeviceRoute.Overview) route = DeviceRoute.Overview
        else if (destination == AppDestination.Features && featurePanel != null) closeFeature()
        else if (destination == AppDestination.Home && mediaDetails) mediaDetails=false
        else if (destination == AppDestination.Settings && settingsRoute != SettingsRoute.Overview) settingsRoute = SettingsRoute.Overview
        else destination = AppDestination.Home
    }
    companion object {
        val saver = listSaver<AppNavigation, String>(
            // Keep the retired findDetails slot so older saved fields do not shift.
            save = {
                listOf(
                    it.destination.name, it.route.name, it.focusedPeer.orEmpty(), it.settingsRoute.name,
                    it.mediaDetails.toString(), "false", AppFeature.migrateStored(it.favouriteFeatures),
                    it.featurePanel?.name.orEmpty(), it.featureOrigin.name, AppFeature.migrateStored(it.featureOrder),
                    it.guideTopic?.name.orEmpty(), it.guideOrigin.name, it.guideOriginRoute.name,
                    it.guideOriginSettingsRoute.name, it.guideOriginFeature?.name.orEmpty()
                )
            },
            restore = { saved ->
                // Older saved state can still point at the removed Permissions destination.
                val settingsRoute = SettingsRoute.entries.firstOrNull { it.name == saved.getOrNull(3) }
                    ?: SettingsRoute.Overview
                AppNavigation(
                    AppDestination.entries.firstOrNull { it.name == saved.getOrNull(0) } ?: AppDestination.Home,
                    DeviceRoute.entries.firstOrNull { it.name == saved.getOrNull(1) } ?: DeviceRoute.Overview,
                    saved.getOrNull(2)?.ifEmpty { null },
                    settingsRoute,
                ).also { value ->
                    value.mediaDetails = saved.getOrNull(4) == "true"
                    value.favouriteFeatures = AppFeature.favouritePreference(saved.getOrNull(6))
                    val panel = saved.getOrNull(7)
                    value.featurePanel = AppFeature.stored(panel)
                        ?: AppFeature.DeskDeck.takeIf { panel.isNullOrEmpty() && saved.getOrNull(5) == "true" }
                    value.featureOrigin = AppDestination.entries.firstOrNull { page -> page.name == saved.getOrNull(8) }
                        ?: AppDestination.Features
                    value.featureOrder = AppFeature.migrateStored(saved.getOrNull(9).orEmpty())
                    value.guideTopic = GuideTopic.entries.firstOrNull { it.name == saved.getOrNull(10) }
                    value.guideOrigin = AppDestination.entries.firstOrNull { it.name == saved.getOrNull(11) } ?: AppDestination.Home
                    value.guideOriginRoute = DeviceRoute.entries.firstOrNull { it.name == saved.getOrNull(12) } ?: DeviceRoute.Overview
                    value.guideOriginSettingsRoute = SettingsRoute.entries.firstOrNull { it.name == saved.getOrNull(13) } ?: SettingsRoute.Overview
                    value.guideOriginFeature = AppFeature.stored(saved.getOrNull(14))
                }
            }
        )
    }
}
