// SPDX-License-Identifier: GPL-3.0-or-later
// Exercises companion setup through the debug application probe.
package io.github.anisharyal09.anice.features.backgroundprobe

import io.github.anisharyal09.anice.infrastructure.connections.CompanionProbe
import androidx.test.ext.junit.runners.AndroidJUnit4
import android.bluetooth.BluetoothAdapter
import android.net.MacAddress
import androidx.test.platform.app.InstrumentationRegistry
import io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity
import io.github.anisharyal09.anice.AniCeApplication
import android.content.Context
import java.io.File
import java.io.IOException
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class CompanionSetupTest {
  @Test fun stopWinsOverSuspendedResumeSuccessAndLookupFailure() = runBlocking {
    val app = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as AniCeApplication
    val policy = CompanionProbe.get(app)
    assumeTrue("Resume ownership requires the Debug API 31+ companion gate", policy.available)
    val preferences = app.getSharedPreferences("companion_feasibility", Context.MODE_PRIVATE)
    val saved = preferences.all.toMap()
    val wasArmed = withContext(Dispatchers.Main) { policy.armed }
    val journals = listOf("identity-v1.json", "trusted_peers.json").associateWith {
      File(app.noBackupFilesDir, it).let { file -> if (file.exists()) file.readBytes() else null }
    }
    val cases = listOf(false to false, false to true, true to false, true to true)
    assertEquals(4, cases.size)
    try {
      withContext(Dispatchers.Main) { policy.pause() }
      for ((disable, lookupFails) in cases) {
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val resume = async(Dispatchers.Main.immediate) {
          policy.resume {
            entered.complete(Unit)
            release.await()
            if (lookupFails) throw IOException("Injected trust lookup failure")
            DeviceIdentity("invalid", "Retired lookup", "macos", "", "")
          }
        }
        withTimeout(2000) { entered.await() }
        withContext(Dispatchers.Main) { policy.pause(disable = disable) }
        val stopped = preferences.all.filterKeys { it != "events" }
        release.complete(Unit)
        try { withTimeout(2000) { resume.await() }; fail("A stopped Resume completed") }
        catch (error: TimeoutCancellationException) { throw error }
        catch (error: CancellationException) { assertEquals("Setup was cancelled.", error.message) }
        withContext(Dispatchers.Main) { assertFalse(policy.armed) }
        assertEquals("Late Resume changed persisted policy", stopped, preferences.all.filterKeys { it != "events" })
        journals.forEach { (name, before) ->
          val file = File(app.noBackupFilesDir, name)
          if (before == null) assertFalse(file.exists()) else assertArrayEquals(before, file.readBytes())
        }
      }
    } finally {
      withContext(NonCancellable + Dispatchers.Main) {
        val edit = preferences.edit().clear()
        saved.forEach { (key, value) ->
          when (value) {
            is String -> edit.putString(key, value)
            is Boolean -> edit.putBoolean(key, value)
            is Int -> edit.putInt(key, value)
            is Long -> edit.putLong(key, value)
            else -> error("Unexpected companion preference type")
          }
        }
        // Resume revalidates the original association; tests create or remove no trust records.
        if (wasArmed) edit.putBoolean("armed", false).putBoolean("paused", true)
        assertTrue(edit.commit())
        if (wasArmed) policy.resume()
      }
    }
  }

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
