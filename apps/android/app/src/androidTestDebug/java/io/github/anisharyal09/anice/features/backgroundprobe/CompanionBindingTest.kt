// SPDX-License-Identifier: GPL-3.0-or-later
// Exercises same-instance companion rebind and terminal retirement without changing trusted setup.
package io.github.anisharyal09.anice.features.backgroundprobe

import io.github.anisharyal09.anice.infrastructure.connections.ProbePresence
import io.github.anisharyal09.anice.infrastructure.connections.CompanionProbe
import android.companion.CompanionDeviceService
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.SdkSuppress
import androidx.test.platform.app.InstrumentationRegistry
import io.github.anisharyal09.anice.AniCeApplication
import java.io.File
import org.junit.Assert.*
import org.junit.Assume.assumeFalse
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
@SdkSuppress(minSdkVersion = 31)
class CompanionBindingTest {
  @Test fun rebindRestoresMissingPresenceReplayAndDestroyedServiceStaysRetired() {
    val runner = InstrumentationRegistry.getInstrumentation()
    val app = runner.targetContext.applicationContext as AniCeApplication
    val policy = CompanionProbe.get(app)
    assumeFalse("Run lifecycle injection on an installation without armed automatic setup", policy.armed)
    assumeTrue("Lifecycle injection requires no saved companion association", policy.associationId == -1)
    val preferences = app.getSharedPreferences("companion_feasibility", Context.MODE_PRIVATE)
    val saved = preferences.all.toMap()
    val journals = listOf("identity-v1.json", "trusted_peers.json").associateWith {
      File(app.noBackupFilesDir, it).let { file -> if (file.exists()) file.readBytes() else null }
    }
    runner.runOnMainSync {
      val service = CompanionProbeService()
      // App code cannot bind this signature-protected service; inject framework lifecycle callbacks.
      ContextWrapper::class.java.getDeclaredMethod("attachBaseContext", Context::class.java).apply {
        isAccessible = true
        invoke(service, app)
      }
      val presence = CompanionProbeService::class.java.getDeclaredField("presence").run {
        isAccessible = true
        get(service) as ProbePresence
      }
      val intent = Intent(CompanionDeviceService.SERVICE_INTERFACE)
      service.onCreate()
      try {
        assertTrue(presence.present)
        assertNotNull(service.onBind(intent))
        assertTrue("Same-instance rebind must be requested", service.onUnbind(intent))
        assertFalse(presence.present)
        assertFalse(presence.event(1, true))
        service.onRebind(Intent("invalid.service"))
        assertFalse("An unrelated bind cannot restore ownership", presence.present)
        service.onRebind(intent)
        assertTrue("No new presence callback was delivered", presence.present)
        presence.event(1, false)
        presence.event(2, false)
        assertFalse(presence.present)
        assertTrue(service.onUnbind(intent))
        service.onRebind(intent)
        assertTrue(presence.present)
      } finally {
        service.onDestroy()
      }
      service.onRebind(intent)
      assertFalse("A destroyed service cannot regain ownership", presence.present)
    }
    assertEquals(saved, preferences.all)
    journals.forEach { (name, before) ->
      val file = File(app.noBackupFilesDir, name)
      if (before == null) assertFalse(file.exists()) else assertArrayEquals(before, file.readBytes())
    }
  }
}
