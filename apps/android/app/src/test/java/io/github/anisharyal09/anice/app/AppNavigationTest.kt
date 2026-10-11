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
}
