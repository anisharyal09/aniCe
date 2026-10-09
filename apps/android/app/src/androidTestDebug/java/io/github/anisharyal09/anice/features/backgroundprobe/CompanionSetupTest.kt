// SPDX-License-Identifier: GPL-3.0-or-later
package io.github.anisharyal09.anice.features.backgroundprobe

import androidx.test.ext.junit.runners.AndroidJUnit4
import android.bluetooth.BluetoothAdapter
import android.net.MacAddress
import androidx.test.platform.app.InstrumentationRegistry
import io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class CompanionSetupTest {
  @Test fun associationAddressWorksWithNativeBluetoothAndRejectsMalformedLocators() {
    val lowercase = MacAddress.fromString("A2:B3:C4:D5:E6:F7").toString()
    assertFalse(BluetoothAdapter.checkBluetoothAddress(lowercase))
    val normalized = CompanionProbe.bluetoothAddress(lowercase)
    assertEquals("A2:B3:C4:D5:E6:F7", normalized)
    assertTrue(BluetoothAdapter.checkBluetoothAddress(normalized))
    assertEquals(normalized, CompanionProbe.bluetoothAddress(normalized))
    for (invalid in listOf("", "A2:B3:C4:D5:E6", "A2:B3:C4:D5:E6:GG", " A2:B3:C4:D5:E6:F7")) {
      try { CompanionProbe.bluetoothAddress(invalid); fail("Malformed locator accepted") }
      catch (_: IllegalArgumentException) {}
    }
  }

  @Test fun stopInvalidatesSetupBeforeItCanReadTrustOrArmObservation() {
    val runner = InstrumentationRegistry.getInstrumentation()
    runner.runOnMainSync {
      val probe = CompanionProbe.get(runner.targetContext)
      probe.stop()
      val token = probe.beginSetup()
      probe.stop()
      // Invalid identity deliberately proves the cancellation guard runs before any identity/trust access.
      val invalid = DeviceIdentity("invalid", "Fixture", "macos", "", "")
      runBlocking {
        try { probe.arm(invalid, "00:11:22:33:44:55", -1, token); fail("Cancelled setup armed observation") }
        catch (error: IllegalStateException) { assertEquals("Setup was cancelled.", error.message) }
      }
      assertFalse(probe.armed)
      assertNull(probe.address)
      assertEquals(-1, probe.associationId)
    }
  }
}
