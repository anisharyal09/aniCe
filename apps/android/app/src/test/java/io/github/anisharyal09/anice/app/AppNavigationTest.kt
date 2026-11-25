// SPDX-License-Identifier: GPL-3.0-or-later
// Verifies presentation routing preserves device context without transport actions.
package io.github.anisharyal09.anice.app

import org.junit.Assert.*
import org.junit.Test
import io.github.anisharyal09.anice.ui.theme.Appearance

class AppNavigationTest {
    @Test fun clipboardSettingsRouteKeepsPeerContextAndDoesNotStartTransport() {
        val navigation = AppNavigation(AppDestination.Features, focusedPeer = "mac-a")
        navigation.openSettings("Clipboard")
        assertEquals(AppDestination.Settings, navigation.destination)
        assertEquals("Clipboard", navigation.settingsSection)
        assertEquals("mac-a", navigation.focusedPeer)
        assertEquals(SettingsRoute.Overview, navigation.settingsRoute)
    }

    @Test fun settingsCategoriesKeepGeneralAndPermissionsSeparateFromFeatureControls() {
        assertEquals(5, SettingsCategory.entries.size)
        for (section in listOf("Appearance", "Updates", "Connection", "This device")) {
            assertEquals(SettingsCategory.General, SettingsCategory.forSection(section))
        }
        assertEquals(SettingsCategory.Permissions, SettingsCategory.forSection("Permissions"))
        assertEquals(SettingsCategory.All, SettingsCategory.forSection("Shortcuts"))
        assertEquals(listOf(SettingsCategory.All, SettingsCategory.General, SettingsCategory.Permissions, SettingsCategory.Features),
            SettingsCategory.visibleEntries)
        for (section in listOf("Clipboard", "Messages", "Notification sync", "Do Not Disturb", "File transfer")) {
            assertEquals(SettingsCategory.Features, SettingsCategory.forSection(section))
        }
    }

    @Test fun appBarBackMatchesNestedDestinationsWithoutLeakingInactiveRoutes() {
        for (destination in AppDestination.entries) {
            for (route in DeviceRoute.entries) {
                for (settings in SettingsRoute.entries) {
                    for (feature in listOf(null, AppFeature.PhoneInput)) {
                        val expected = destination == AppDestination.About ||
                            destination == AppDestination.Guide ||
                            (destination == AppDestination.Devices && route == DeviceRoute.Discovery) ||
                            (destination == AppDestination.Settings && settings != SettingsRoute.Overview) ||
                            (destination == AppDestination.Features && feature != null)
                        assertEquals(expected, showsAppBarBack(destination, route, settings, feature))
                    }
                }
            }
        }
        val state = AppNavigation(AppDestination.About, DeviceRoute.Discovery, "mac-a")
        state.back()
        assertEquals(AppDestination.Home, state.destination)
        assertEquals("mac-a", state.focusedPeer)
    }

    @Test fun openGuidePreservesOriginRouteFeatureAndRoundTripsSaver() {
        val state = AppNavigation(AppDestination.Devices, DeviceRoute.Discovery, "mac-a").also {
            it.openFeature(AppFeature.DeskDeck)
            it.openGuide(GuideTopic.MacDeskDeck)
        }
        assertEquals(AppDestination.Guide, state.destination)
        assertEquals(GuideTopic.MacDeskDeck, state.guideTopic)
        assertTrue(showsAppBarBack(state.destination, state.route, state.settingsRoute, state.featurePanel))

        val scope = androidx.compose.runtime.saveable.SaverScope { true }
        val saved = with(AppNavigation.saver) { scope.save(state) }!!
        val restored = AppNavigation.saver.restore(saved)!!
        assertEquals(AppDestination.Guide, restored.destination)
        assertEquals(GuideTopic.MacDeskDeck, restored.guideTopic)

        restored.back()
        assertEquals(AppDestination.Features, restored.destination)
        assertEquals(AppFeature.DeskDeck, restored.featurePanel)
        assertNull(restored.guideTopic)
        assertEquals("mac-a", restored.focusedPeer)
    }

    @org.junit.Test fun comparisonCannotBeHiddenByAnInactiveDeviceRoute() {
        for (destination in AppDestination.entries) for (route in DeviceRoute.entries) {
            org.junit.Assert.assertEquals(
                route == DeviceRoute.Pairing && destination in listOf(AppDestination.Home, AppDestination.Devices),
                comparisonUsesDeviceSheet(destination, route))
        }
    }
    @Test fun nestedBackAndTabChangesRetainDeviceContext() {
        val state = AppNavigation()
        assertEquals(AppDestination.Home, state.destination)
        state.openDevice("mac-a")
        state.route = DeviceRoute.Discovery
        state.select(AppDestination.Settings, false)
        state.select(AppDestination.Devices, false)
        assertEquals(DeviceRoute.Discovery, state.route)
        assertEquals("mac-a", state.focusedPeer)
        state.back()
        assertEquals(DeviceRoute.Overview, state.route)
        assertEquals(AppDestination.Devices, state.destination)
        state.back()
        assertEquals(AppDestination.Home, state.destination)
        assertEquals("mac-a", state.focusedPeer)
    }
    @Test fun unpairedEntryAndPairingCompletionHaveExplicitDestinations() {
        val state = AppNavigation()
        state.select(AppDestination.Devices, true)
        assertEquals(AppDestination.Devices, state.destination)
        assertEquals(DeviceRoute.Pairing, state.route)
        state.select(AppDestination.Settings, false)
        assertEquals(DeviceRoute.Pairing, state.route)
        state.paired()
        assertEquals(AppDestination.Home, state.destination)
        assertEquals(DeviceRoute.Overview, state.route)
        state.pair()
        assertEquals(AppDestination.Devices, state.destination)
    }
    @Test fun identityBackReturnsToSettingsWithoutLosingDeviceNavigation() {
        val state = AppNavigation(AppDestination.Settings, DeviceRoute.Discovery, "mac-a", SettingsRoute.Identity)
        state.back()
        assertEquals(AppDestination.Settings, state.destination)
        assertEquals(SettingsRoute.Overview, state.settingsRoute)
        assertEquals(DeviceRoute.Discovery, state.route)
        assertEquals("mac-a", state.focusedPeer)
        state.back()
        assertEquals(AppDestination.Home, state.destination)
    }
    @Test fun notificationAppPickerBackReturnsToSettingsAndSurvivesRestoration() {
        val state = AppNavigation()
        state.select(AppDestination.Settings, false)
        state.settingsRoute = SettingsRoute.NotificationApps
        val scope = androidx.compose.runtime.saveable.SaverScope { true }
        val saved = with(AppNavigation.saver) { scope.save(state) }!!
        val restored = AppNavigation.saver.restore(saved)!!
        assertEquals(AppDestination.Settings, restored.destination)
        assertEquals(SettingsRoute.NotificationApps, restored.settingsRoute)
        restored.back()
        assertEquals(AppDestination.Settings, restored.destination)
        assertEquals(SettingsRoute.Overview, restored.settingsRoute)
    }
    @Test fun unknownAppearanceDoesNotForceLightOrDark() {
        assertEquals(Appearance.System, Appearance.stored(null))
        assertEquals(Appearance.System, Appearance.stored("unknown"))
        Appearance.entries.forEach { assertEquals(it, Appearance.stored(it.name)) }
        assertEquals(3, Appearance.entries.size)
    }
    @Test fun saverRoundTripPreservesAllFieldsAndHandlesEmptyPeer() {
        val original = AppNavigation(AppDestination.Settings, DeviceRoute.Discovery, "mac-x", SettingsRoute.Identity)
        val scope = androidx.compose.runtime.saveable.SaverScope { true }
        val saved = with(AppNavigation.saver) { scope.save(original) }
        assertNotNull(saved)
        val restored = AppNavigation.saver.restore(saved!!)
        assertNotNull(restored)
        assertEquals(AppDestination.Settings, restored!!.destination)
        assertEquals(DeviceRoute.Discovery, restored.route)
        assertEquals("mac-x", restored.focusedPeer)
        assertEquals(SettingsRoute.Identity, restored.settingsRoute)

        val emptyPeer = AppNavigation(AppDestination.Home, DeviceRoute.Overview, null, SettingsRoute.Overview)
        val savedEmpty = with(AppNavigation.saver) { scope.save(emptyPeer) }
        val restoredEmpty = AppNavigation.saver.restore(savedEmpty!!)
        assertNotNull(restoredEmpty)
        assertNull(restoredEmpty!!.focusedPeer)
    }
    @Test fun featuresBackAndSavedWorkspacePreserveOtherRoutes() {
        assertEquals(listOf("Home", "Devices", "Features", "Favourites", "Settings"), AppDestination.primary.map { it.label })
        val state=AppNavigation(AppDestination.Features,DeviceRoute.Discovery,"mac-x")
        state.openFeature(AppFeature.DeskDeck)
        val scope=androidx.compose.runtime.saveable.SaverScope { true }
        val saved=with(AppNavigation.saver) { scope.save(state) }!!
        val restored=AppNavigation.saver.restore(saved)!!
        assertEquals(AppFeature.DeskDeck, restored.featurePanel)
        restored.back();assertEquals(AppDestination.Features,restored.destination);assertNull(restored.featurePanel)
        restored.back();assertEquals(AppDestination.Home,restored.destination);assertEquals(DeviceRoute.Discovery,restored.route);assertEquals("mac-x",restored.focusedPeer)
    }

    @Test fun workspaceEntryExitsManagementWithoutLosingPeerOrExpandedPlayback() {
        val state = AppNavigation(AppDestination.Devices, DeviceRoute.Pairing, "mac-a")
        state.mediaDetails = true
        state.select(AppDestination.Home, false)
        assertEquals(DeviceRoute.Overview, state.route)
        assertEquals("mac-a", state.focusedPeer)
        state.back()
        assertFalse(state.mediaDetails)
        assertEquals(AppDestination.Home, state.destination)
        state.back()
        assertEquals("mac-a", state.focusedPeer)
        assertEquals(AppDestination.Home, state.destination)
    }

    @Test fun olderSavedNavigationWithoutFeaturePanelRestoresAndNestedBackStaysLocal() {
        val restored = AppNavigation.saver.restore(listOf("Features", "Discovery", "mac-a", "Overview", "false"))!!
        assertNull(restored.featurePanel)
        restored.openFeature(AppFeature.DeskDeck)
        restored.back()
        assertNull(restored.featurePanel)
        assertEquals(AppDestination.Features, restored.destination)
        assertEquals(DeviceRoute.Discovery, restored.route)
        assertEquals("mac-a", restored.focusedPeer)
    }

    @Test fun favouritesKeepSavedOrderIgnoreUnknownAndToggleWithoutDuplicates() {
        assertEquals(listOf(AppFeature.Files, AppFeature.Playback), AppFeature.favourites("Files,Files,unknown,Playback"))
        assertTrue(AppFeature.favourites("unknown").isEmpty())
        assertEquals("Playback", AppFeature.Files.toggled("Files,unknown,Playback"))
        assertEquals("Files,DeskDeck", AppFeature.DeskDeck.toggled("Files,Files"))
        assertEquals(6, AppFeature.entries.size)
        AppFeature.entries.forEach { feature ->
            assertEquals(listOf(feature), AppFeature.favourites(feature.toggled("")))
            assertEquals("", feature.toggled(feature.toggled("")))
        }
    }

    @Test fun controlMacLivesInFeaturesAndLegacyPermissionRouteReturnsToSettings() {
        assertTrue(AppFeature.entries.contains(AppFeature.PhoneInput))
        val saved = listOf("Settings", "Overview", "", "Permissions", "false", "false", "")
        val restored = AppNavigation.saver.restore(saved)!!
        assertEquals(SettingsRoute.Overview, restored.settingsRoute)
        restored.back()
        assertEquals(AppDestination.Home, restored.destination)
    }

    @Test fun favouriteRoutingAndAboutBackPreservePeerAndSavedPreferences() {
        val state = AppNavigation(AppDestination.Devices, DeviceRoute.Discovery, "mac-a")
        state.favouriteFeatures = "Playback,FindDevice"
        state.openFeature(AppFeature.stored("FindDevice")!!)
        assertEquals(AppFeature.DeskDeck, state.featurePanel)
        state.back()
        assertEquals(AppDestination.Features, state.destination)
        state.openFeature(AppFeature.Playback)
        assertEquals(AppDestination.Features, state.destination)
        assertEquals(DeviceRoute.Discovery, state.route)
        assertEquals(AppFeature.Playback, state.featurePanel)
        state.select(AppDestination.Settings, false)
        state.settingsRoute = SettingsRoute.About
        val scope = androidx.compose.runtime.saveable.SaverScope { true }
        val saved = with(AppNavigation.saver) { scope.save(state) }!!
        val restored = AppNavigation.saver.restore(saved)!!
        assertEquals("Playback,DeskDeck", restored.favouriteFeatures)
        assertEquals(SettingsRoute.About, restored.settingsRoute)
        restored.back()
        assertEquals(SettingsRoute.Overview, restored.settingsRoute)
        assertEquals("mac-a", restored.focusedPeer)
        assertEquals("Playback,DeskDeck", restored.favouriteFeatures)
    }

    @Test fun featurePanelsReturnToTheirOwnSectionAndSurviveRestoration() {
        val scope = androidx.compose.runtime.saveable.SaverScope { true }
        for (origin in listOf(AppDestination.Home, AppDestination.Features, AppDestination.Favourites)) {
            for (feature in AppFeature.entries) {
                val state = AppNavigation(origin, DeviceRoute.Discovery, "mac-a")
                state.openFeature(feature)
                assertEquals(AppDestination.Features, state.destination)
                assertEquals(feature, state.featurePanel)
                state.openFeature(feature)
                assertEquals(origin, state.featureOrigin)
                val saved = with(AppNavigation.saver) { scope.save(state) }!!
                val restored = AppNavigation.saver.restore(saved)!!
                assertEquals(feature, restored.featurePanel)
                restored.back()
                assertEquals(origin, restored.destination)
                assertNull(restored.featurePanel)
                assertEquals("mac-a", restored.focusedPeer)
                assertEquals(DeviceRoute.Discovery, restored.route)
            }
        }
        val older = AppNavigation.saver.restore(listOf("Features", "Overview", "", "Overview", "false", "false", ""))!!
        assertNull(older.featurePanel)
    }

    @Test fun retiredFindLauncherMigratesShortcutsOnceAtTheirFirstSavedPosition() {
        val cases = mapOf(
            "FindDevice" to "DeskDeck",
            "FindDevice,Files,DeskDeck,Clipboard" to "DeskDeck,Files,Clipboard",
            "Files,DeskDeck,Clipboard,FindDevice" to "Files,DeskDeck,Clipboard",
            "unknown,FindDevice,FindDevice,Files,DeskDeck" to "unknown,DeskDeck,Files",
            "" to "",
        )
        for ((old, migrated) in cases) {
            assertEquals(migrated, AppFeature.migrateStored(old))
            assertEquals(migrated, AppFeature.migrateStored(migrated))
            assertEquals(1, AppFeature.ordered(old).count { it == AppFeature.DeskDeck })
            assertEquals(AppFeature.entries.toSet(), AppFeature.ordered(old).toSet())
            assertFalse(AppFeature.ordered(old).any { it.name == "FindDevice" })
        }
        assertEquals("Files,Clipboard", AppFeature.DeskDeck.toggled("FindDevice,Files,DeskDeck,Clipboard"))
        assertEquals("DeskDeck,Files,Clipboard", AppFeature.moved(AppFeature.DeskDeck,
            AppFeature.favourites("Files,FindDevice,Clipboard,DeskDeck"), -1))
        assertEquals(AppFeature.DeskDeck, AppFeature.stored("FindDevice"))
        assertNull(AppFeature.stored("unknown"))
    }

    @Test fun preferenceMigrationPreservesExplicitlyEmptyFavouritesAcrossRestarts() {
        assertEquals(AppFeature.DEFAULT_FAVOURITES, AppFeature.favouritePreference(null))
        assertEquals("", AppFeature.favouritePreference(""))
        assertEquals("unknown", AppFeature.favouritePreference("unknown"))
        assertEquals("Files,DeskDeck", AppFeature.favouritePreference("Files,FindDevice,DeskDeck"))
        val state = AppNavigation().also { it.favouriteFeatures = "" }
        val scope = androidx.compose.runtime.saveable.SaverScope { true }
        val saved = with(AppNavigation.saver) { scope.save(state) }!!
        assertEquals("", AppNavigation.saver.restore(saved)!!.favouriteFeatures)
        assertEquals(AppFeature.DEFAULT_FAVOURITES,
            AppNavigation.saver.restore(listOf("Home", "Overview", "", "Overview", "false"))!!.favouriteFeatures)
    }

    @Test fun migrationDoesNotEraseUnrecognizedSavedShortcutsFromAnotherBuild() {
        val original = AppNavigation().also {
            it.favouriteFeatures = "futureFeature,FindDevice,Files,DeskDeck"
            it.featureOrder = "Files,futureFeature,FindDevice,DeskDeck"
        }
        val scope = androidx.compose.runtime.saveable.SaverScope { true }
        val saved = with(AppNavigation.saver) { scope.save(original) }!!
        val restored = AppNavigation.saver.restore(saved)!!
        assertEquals("futureFeature,DeskDeck,Files", restored.favouriteFeatures)
        assertEquals("Files,futureFeature,DeskDeck", restored.featureOrder)
        assertEquals(listOf(AppFeature.DeskDeck, AppFeature.Files), AppFeature.favourites(restored.favouriteFeatures))
        assertEquals(listOf(AppFeature.Files, AppFeature.DeskDeck), AppFeature.ordered(restored.featureOrder).take(2))
    }

    @Test fun legacyFindRoutesRedirectToDeskDeckWithoutLosingBackOriginOrPeerContext() {
        val scope = androidx.compose.runtime.saveable.SaverScope { true }
        for (origin in listOf(AppDestination.Home, AppDestination.Features, AppDestination.Favourites)) {
            for (legacyDetails in listOf("true", "false")) {
                val restored = AppNavigation.saver.restore(listOf(
                    "Features", "Discovery", "mac-a", "Identity", "true", legacyDetails,
                    "Files,FindDevice,DeskDeck", "FindDevice", origin.name, "Files,FindDevice,Clipboard,DeskDeck",
                ))!!
                assertEquals(AppFeature.DeskDeck, restored.featurePanel)
                assertEquals("Files,DeskDeck", restored.favouriteFeatures)
                assertEquals("Files,DeskDeck,Clipboard", restored.featureOrder)
                assertTrue(restored.mediaDetails)
                assertEquals(SettingsRoute.Identity, restored.settingsRoute)
                assertTrue(showsAppBarBack(restored.destination, restored.route, restored.settingsRoute, restored.featurePanel))
                val saved = with(AppNavigation.saver) { scope.save(restored) }!! as List<*>
                assertEquals("false", saved[5])
                assertEquals("DeskDeck", saved[7])
                assertFalse(saved.any { it is String && it.contains("FindDevice") })
                restored.back()
                assertEquals(origin, restored.destination)
                assertNull(restored.featurePanel)
                assertEquals("mac-a", restored.focusedPeer)
                assertEquals(DeviceRoute.Discovery, restored.route)
            }
        }
        val detailsOnly = AppNavigation.saver.restore(listOf("Features", "Overview", "", "Overview", "false", "true"))!!
        assertEquals(AppFeature.DeskDeck, detailsOnly.featurePanel)
        detailsOnly.back()
        assertEquals(AppDestination.Features, detailsOnly.destination)
        val newerPanel = AppNavigation.saver.restore(listOf(
            "Features", "Overview", "", "Overview", "false", "true", "", "Playback",
        ))!!
        assertEquals(AppFeature.Playback, newerPanel.featurePanel)
    }

}
