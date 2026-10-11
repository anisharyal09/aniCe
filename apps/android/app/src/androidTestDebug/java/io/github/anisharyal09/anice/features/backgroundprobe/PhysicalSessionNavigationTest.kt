// SPDX-License-Identifier: GPL-3.0-or-later
// Verifies shared Android session ownership and authenticated teardown against a physical Mac.
package io.github.anisharyal09.anice.features.backgroundprobe

import io.github.anisharyal09.anice.infrastructure.connections.CompanionProbe
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import android.app.Activity
import android.content.Intent
import io.github.anisharyal09.anice.AniCeApplication
import io.github.anisharyal09.anice.infrastructure.connections.ConnectionState
import java.io.File
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

/** Opt-in physical BLE regressions; each method requires its runner argument and Mac setup. */
@RunWith(AndroidJUnit4::class)
class PhysicalSessionNavigationTest {
  @Test fun authenticatedMacCloseRetiresControllerAndAllowsFreshRecovery() = runBlocking {
    val peerId = InstrumentationRegistry.getArguments().getString("physicalMacClose")
    assumeTrue("Supply physicalMacClose with automatic setup and a physical Mac", peerId != null)
    val app = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as AniCeApplication
    val controller = app.sessionController
    val policy = CompanionProbe.get(app)
    val identityFile = File(app.noBackupFilesDir, "identity-v1.json")
    val trustFile = File(app.noBackupFilesDir, "trusted_peers.json")
    val beforeIdentity = identityFile.readBytes()
    val beforeTrust = trustFile.readBytes()
    // Observe the actual encrypted channel; no synthetic presence or peer-close state is injected.
    val field = controller.javaClass.getDeclaredField("connection").apply { isAccessible = true }
    try {
      withTimeout(90000) {
        while (withContext(Dispatchers.Main) {
          controller.state != ConnectionState.SECURED || controller.controlSupport != true
        }) delay(50)
      }
      val old = withContext(Dispatchers.Main) {
        assertTrue(policy.armed)
        assertEquals(peerId, policy.peerId)
        assertTrue(controller.hasCompanionOwner)
        field.get(controller) as io.github.anisharyal09.anice.infrastructure.session.SessionConnection
      }
      android.util.Log.i("aniCe-close-test", "secured; disconnect Mac now")
      withTimeout(60000) { while (!old.closedByPeer) delay(20) }
      withTimeout(2000) {
        while (withContext(Dispatchers.Main) { controller.state == ConnectionState.SECURED }) delay(20)
      }
      withContext(Dispatchers.Main) {
        assertTrue(old.isClosed)
        assertNotSame(old, field.get(controller))
        assertNotEquals(ConnectionState.SECURED, controller.progress.value.state)
        assertTrue(policy.armed) // Remote Disconnect does not pause Android's recovery policy.
      }
      android.util.Log.i("aniCe-close-test", "close retired; enable Mac automatic now")
      withTimeout(90000) {
        while (withContext(Dispatchers.Main) {
          controller.state != ConnectionState.SECURED || controller.controlSupport != true
        }) delay(50)
      }
      withContext(Dispatchers.Main) { assertNotSame(old, field.get(controller)) }
    } finally {
      assertArrayEquals(beforeIdentity, identityFile.readBytes())
      assertArrayEquals(beforeTrust, trustFile.readBytes())
    }
  }

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
