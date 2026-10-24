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
  @Test fun physicalReplySubscription() = runBlocking<Unit> {
    assumeTrue("Supply physicalSubscription=true with an open Mac invitation",
      InstrumentationRegistry.getArguments().getString("physicalSubscription") == "true")
    val app = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as AniCeApplication
    val ready = CompletableDeferred<Unit>()
    val transport = withContext(Dispatchers.Main) {
      io.github.anisharyal09.anice.infrastructure.bluetooth.AndroidGattTransport(
        app, {}, { ready.complete(Unit) }, {},
        { _, failure -> ready.completeExceptionally(AssertionError(failure?.message ?: "Subscription ended")) },
        { stage, _ -> android.util.Log.i("aniCe-subscription-test", "stage=$stage") })
    }
    try {
      withContext(Dispatchers.Main) { transport.startScan(qr = true) }
      withTimeout(30_000) { ready.await() }
      android.util.Log.i("aniCe-subscription-test", "reply subscription succeeded; authentication not attempted")
    } finally {
      withContext(Dispatchers.Main) { transport.close() }
    }
  }

  @Test fun physicalMediaCommandLatency() = runBlocking {
    val transport = InstrumentationRegistry.getArguments().getString("physicalMedia")
    assumeTrue("Supply physicalMedia=ble or lan for real playback timing", transport != null)
    require(transport == "ble" || transport == "lan")
    val runner = InstrumentationRegistry.getInstrumentation()
    val app = runner.targetContext.applicationContext as AniCeApplication
    val media = app.nowPlaying
    val active = media.javaClass.getDeclaredField("active").apply { isAccessible = true }
    val rows = org.json.JSONArray()
    val report = File(app.cacheDir, "physical-media-$transport.json")
    var home: Activity? = null
    val previous = withContext(Dispatchers.Main) { media.trace }
    var result: CompletableDeferred<Pair<Long, Int>>? = null
    var command: String? = null
    val inputPattern = Regex("^input command=(\\d+)")
    val resultPattern = Regex("^result command=(\\d+) result=(\\d+)")
    try {
      home = runner.startActivitySync(Intent().setClassName(app, "io.github.anisharyal09.anice.MainActivity")
        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
      withContext(Dispatchers.Main) {
        media.foreground(this@PhysicalSessionNavigationTest)
        media.trace = { event, time ->
          previous(event, time)
          inputPattern.find(event)?.let { command = it.groupValues[1] }
          resultPattern.find(event)?.let {
            if (it.groupValues[1] == command) result?.complete(time to it.groupValues[2].toInt())
          }
        }
      }
      withTimeout(90_000) {
        while (withContext(Dispatchers.Main) {
          active.get(media) != transport || media.playback?.actions?.and(1L) != 1L || media.busy
        }) delay(100)
      }
      repeat(200) { index ->
        val response = CompletableDeferred<Pair<Long, Int>>()
        val started = withContext(Dispatchers.Main) {
          assertEquals("Transport changed during measurement", transport, active.get(media))
          assertFalse(media.busy)
          result = response
          command = null
          val time = android.os.SystemClock.elapsedRealtime()
          media.command(1)
          time
        }
        val settled = withTimeoutOrNull(12_000) { response.await() }
        val row = org.json.JSONObject().put("index", index).put("result", settled?.second ?: -1)
          .put("elapsedMs", (settled?.first ?: android.os.SystemClock.elapsedRealtime()) - started)
        rows.put(row)
        android.util.Log.i("aniCe-media-benchmark", "transport=$transport sample=$row")
        // An uncertain command is never replayed, including by the benchmark.
        assertNotNull("Command result was not confirmed", settled)
        assertEquals("Command failed", 0, settled!!.second)
        delay(250)
      }
    } finally {
      report.writeText(org.json.JSONObject().put("transport", transport).put("expected", 200)
        .put("completed", rows.length()).put("samples", rows).toString())
      withContext(Dispatchers.Main) {
        media.trace = previous
        media.background(this@PhysicalSessionNavigationTest, false)
        home?.finish()
      }
    }
    assertEquals(200, rows.length())
  }

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
