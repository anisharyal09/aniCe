// SPDX-License-Identifier: GPL-3.0-or-later
// Covers truthful battery-source and charge-state mapping without mocking Android framework services.
package io.github.anisharyal09.anice.features.deskdeck

import android.os.BatteryManager
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DevicePowerControllerTests {
    @Test fun macSummaryShowsBatteryStateAndLevelWithoutPowerSourceDetails() {
        assertEquals("Charging · 80%", DevicePowerReading(3, 80, 2).macSummary)
        assertEquals("On battery · 35%", DevicePowerReading(2, 35, 1).macSummary)
        assertEquals("Mac power unavailable", DevicePowerReading(0, null, 0).macSummary)
        assertEquals("No battery", DevicePowerReading(1, null, 2).macSummary)
    }

    @Test fun reportsChargingSourceAndUnknownPercentageAccurately() {
        val ac = DevicePowerReading.fromValues(true, 0, 0, BatteryManager.BATTERY_STATUS_CHARGING,
            BatteryManager.BATTERY_PLUGGED_AC)
        assertEquals(DevicePowerReading(3, null, 2), ac)
        assertTrue(ac.plugged)

        val usb = DevicePowerReading.fromValues(true, 80, 100, BatteryManager.BATTERY_STATUS_NOT_CHARGING,
            BatteryManager.BATTERY_PLUGGED_USB)
        assertEquals(DevicePowerReading(5, 80, 3), usb)

        val wireless = DevicePowerReading.fromValues(true, 100, 100, BatteryManager.BATTERY_STATUS_FULL,
            BatteryManager.BATTERY_PLUGGED_WIRELESS)
        assertEquals(DevicePowerReading(4, 100, 4), wireless)
    }

    @Test fun distinguishesOnBatteryMissingBatteryAndUnknownCharger() {
        val battery = DevicePowerReading.fromValues(true, 35, 100, BatteryManager.BATTERY_STATUS_DISCHARGING, 0)
        assertEquals(DevicePowerReading(2, 35, 1), battery)
        assertFalse(battery.plugged)

        val absent = DevicePowerReading.fromValues(false, -1, -1, BatteryManager.BATTERY_STATUS_UNKNOWN, 0)
        assertEquals(1L, absent.state)
        assertNull(absent.percent)

        val unknownPlug = DevicePowerReading.fromValues(true, 50, 100, BatteryManager.BATTERY_STATUS_CHARGING, 16)
        assertEquals(3L, unknownPlug.state)
        assertEquals(0L, unknownPlug.source)
        assertFalse(unknownPlug.plugged)
    }
}
