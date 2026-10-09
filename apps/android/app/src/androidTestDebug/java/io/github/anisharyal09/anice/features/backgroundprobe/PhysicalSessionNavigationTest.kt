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
