// SPDX-License-Identifier: GPL-3.0-or-later
package io.github.anisharyal09.anice.features.backgroundprobe

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import android.app.Activity
import android.content.Intent
import io.github.anisharyal09.anice.AniCeApplication
import io.github.anisharyal09.anice.infrastructure.session.ConnectionState
import java.io.File
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

/** Opt-in radio regression: requires an existing trusted Mac with Allow connections open. */
@RunWith(AndroidJUnit4::class)
class PhysicalSessionNavigationTest {
  /** Instruments a real OS-owned lease; the runner does not establish process-death recovery. */
  @Test fun automaticOwnerSurvivesRecentsRemovalAndQuietKeepalive() = runBlocking {
    val peerId = InstrumentationRegistry.getArguments().getString("physicalAutomatic")
    assumeTrue("Supply physicalAutomatic after native association and Mac automatic setup", peerId != null)
    val runner = InstrumentationRegistry.getInstrumentation()
    val app = runner.targetContext.applicationContext as AniCeApplication
    val controller = app.sessionController
    val policy = CompanionProbe.get(app)
    val identity = withContext(Dispatchers.IO) { app.identityService.getOrCreateIdentity().identity }
    val trustFile = File(app.noBackupFilesDir, "trusted_peers.json")
    val beforeTrust = trustFile.readBytes()
    var home: Activity? = null
    var settings: Activity? = null
    try {
      home = runner.startActivitySync(Intent().setClassName(app, "io.github.anisharyal09.anice.MainActivity")
        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
      withContext(Dispatchers.Main) {
        assertTrue("Complete native companion setup first", policy.armed)
        assertEquals(peerId, policy.peerId)
      }
      suspend fun waitOwned(stage: String) {
        try {
          withTimeout(45000) {
            while (withContext(Dispatchers.Main) {
              controller.state != ConnectionState.SECURED || controller.controlSupport != true || !controller.hasCompanionOwner
            }) delay(100)
          }
        } catch (timeout: TimeoutCancellationException) {
          throw AssertionError("$stage: state=${controller.state}, controls=${controller.controlSupport}, " +
            "lease=${controller.hasCompanionOwner}, policy=${policy.status}, connection=${controller.status}", timeout)
        }
      }
      waitOwned("Initial native ownership")
      // The real native service stays bound across pause; resume must reacquire its cached presence.
      withContext(Dispatchers.Main) { policy.pause(); assertFalse(controller.hasCompanionOwner) }
      withContext(Dispatchers.Main) { policy.resume() }
      waitOwned("Resume with cached native presence")
      settings = runner.startActivitySync(Intent().setClassName(app, CompanionProbeActivity::class.java.name)
        .putExtra("peer", peerId).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
      delay(10000)
      withContext(Dispatchers.Main) {
        assertTrue(controller.hasCompanionOwner)
        assertEquals(controller.status, ConnectionState.SECURED, controller.state)
        requireNotNull(settings).finish()
      }
      runner.waitForIdleSync()
      withContext(Dispatchers.Main) { requireNotNull(home).finishAndRemoveTask() }
      runner.waitForIdleSync()
      val quietChecks = withContext(Dispatchers.Main) { controller.receivedChecks }
      // Real elapsed time, with no application checks: only encrypted PING/PONG may sustain activity.
      repeat(190) {
        delay(1000)
        withContext(Dispatchers.Main) {
          assertTrue("System lease disappeared", controller.hasCompanionOwner)
          assertEquals(controller.status, ConnectionState.SECURED, controller.state)
          assertEquals(true, controller.controlSupport)
          assertEquals(ConnectionState.SECURED, controller.progress.value.state)
          assertEquals(true, controller.progress.value.controls)
          assertEquals("Quiet interval received a manual check", quietChecks, controller.receivedChecks)
        }
      }
      withContext(Dispatchers.Main) {
        controller.checkConnection()
        policy.record("physical Recents/quiet keepalive: 190 seconds secured")
      }
      delay(1000)
      withContext(Dispatchers.Main) { assertEquals(ConnectionState.SECURED, controller.state) }
    } finally {
      withContext(Dispatchers.Main) { settings?.finish(); home?.finish() }
      assertArrayEquals(beforeTrust, trustFile.readBytes())
      assertEquals(identity, withContext(Dispatchers.IO) { app.identityService.getOrCreateIdentity().identity })
    }
  }

  @Test fun authenticatedConnectionSurvivesPresentationHandoffs() = runBlocking {
    val peerId = InstrumentationRegistry.getArguments().getString("physicalPeer")
    assumeTrue("Supply physicalPeer only for a real Mac radio run", peerId != null)
    val runner = InstrumentationRegistry.getInstrumentation()
    val app = runner.targetContext.applicationContext as AniCeApplication
    val identity = withContext(Dispatchers.IO) { app.identityService.getOrCreateIdentity().identity }
    val peer = withContext(Dispatchers.IO) { app.trustStore.list(identity.fingerprint).single { it.peer.deviceId == peerId }.peer }
    val trustFile = File(app.noBackupFilesDir, "trusted_peers.json")
    val beforeTrust = trustFile.readBytes()
    val controller = app.sessionController
    var home: Activity? = null
    var probe: Activity? = null
    try {
      home = runner.startActivitySync(Intent().setClassName(app, "io.github.anisharyal09.anice.MainActivity").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
      withContext(Dispatchers.Main) {
        controller.connect(peer)
      }
      withTimeout(40000) {
        while (withContext(Dispatchers.Main) {
          assertNotEquals(controller.status, ConnectionState.FAILED, controller.state)
          controller.state != ConnectionState.SECURED
        }) delay(100)
      }
      // Launch the real screen: its Start and Home's Stop must preserve the authenticated channel.
      probe = runner.startActivitySync(Intent().setClassName(app, CompanionProbeActivity::class.java.name)
        .putExtra("peer", peerId).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
      withContext(Dispatchers.Main) {
        assertEquals(ConnectionState.SECURED, controller.state)
        controller.checkConnection()
      }
      delay(10000)
      withContext(Dispatchers.Main) {
        assertEquals(controller.status, ConnectionState.SECURED, controller.state)
        requireNotNull(probe).finish()
      }
      runner.waitForIdleSync()
      withContext(Dispatchers.Main) {
        assertEquals(ConnectionState.SECURED, controller.state)
        controller.checkConnection()
      }
      delay(10000)
      withContext(Dispatchers.Main) { assertEquals(controller.status, ConnectionState.SECURED, controller.state) }
    } finally {
      withContext(Dispatchers.Main) {
        probe?.finish()
        home?.finish()
        controller.cancel()
      }
      assertArrayEquals(beforeTrust, trustFile.readBytes())
      assertEquals(identity, withContext(Dispatchers.IO) { app.identityService.getOrCreateIdentity().identity })
    }
  }
}
