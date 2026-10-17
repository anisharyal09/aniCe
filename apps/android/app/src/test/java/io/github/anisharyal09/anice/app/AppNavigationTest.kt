// SPDX-License-Identifier: GPL-3.0-or-later
// Verifies presentation routing preserves device context without transport actions.
package io.github.anisharyal09.anice.app

import org.junit.Assert.*
import org.junit.Test
import io.github.anisharyal09.anice.ui.theme.Appearance

class AppNavigationTest {
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
        state.findDetails=true
        val scope=androidx.compose.runtime.saveable.SaverScope { true }
        val saved=with(AppNavigation.saver) { scope.save(state) }!!
        val restored=AppNavigation.saver.restore(saved)!!
        assertTrue(restored.findDetails);restored.back();assertEquals(AppDestination.Features,restored.destination);assertFalse(restored.findDetails)
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

    @Test fun olderSavedNavigationWithoutFindDetailsRestoresAndNestedBackStaysLocal() {
        val restored = AppNavigation.saver.restore(listOf("Features", "Discovery", "mac-a", "Overview", "false"))!!
        assertFalse(restored.findDetails)
        restored.findDetails = true
        restored.back()
        assertFalse(restored.findDetails)
        assertEquals(AppDestination.Features, restored.destination)
        assertEquals(DeviceRoute.Discovery, restored.route)
        assertEquals("mac-a", restored.focusedPeer)
    }

    @Test fun favouritesAreBoundedToKnownFeaturesAndToggleWithoutDuplicates() {
        assertEquals(listOf(AppFeature.Playback, AppFeature.Files), AppFeature.favourites("Files,Files,unknown,Playback"))
        assertTrue(AppFeature.favourites("unknown").isEmpty())
        assertEquals("Playback", AppFeature.Files.toggled("Files,unknown,Playback"))
        assertEquals("Files,FindDevice", AppFeature.FindDevice.toggled("Files,Files"))
        assertEquals(4, AppFeature.entries.size)
        AppFeature.entries.forEach { feature ->
            assertEquals(listOf(feature), AppFeature.favourites(feature.toggled("")))
            assertEquals("", feature.toggled(feature.toggled("")))
        }
    }

    @Test fun favouriteRoutingAndAboutBackPreservePeerAndSavedPreferences() {
        val state = AppNavigation(AppDestination.Devices, DeviceRoute.Discovery, "mac-a")
        state.favouriteFeatures = "Playback,FindDevice"
        state.openFeature(AppFeature.FindDevice)
        assertTrue(state.findDetails)
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
        assertEquals("Playback,FindDevice", restored.favouriteFeatures)
        assertEquals(SettingsRoute.About, restored.settingsRoute)
        restored.back()
        assertEquals(SettingsRoute.Overview, restored.settingsRoute)
        assertEquals("mac-a", restored.focusedPeer)
        assertEquals("Playback,FindDevice", restored.favouriteFeatures)
    }

    @Test fun featurePanelsReturnToTheirOwnSectionAndSurviveRestoration() {
        val scope = androidx.compose.runtime.saveable.SaverScope { true }
        for (origin in listOf(AppDestination.Features, AppDestination.Favourites)) {
            for (feature in AppFeature.entries) {
                val state = AppNavigation(origin, DeviceRoute.Discovery, "mac-a")
                state.openFeature(feature)
                assertEquals(AppDestination.Features, state.destination)
                assertEquals(feature, state.featurePanel)
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

}
