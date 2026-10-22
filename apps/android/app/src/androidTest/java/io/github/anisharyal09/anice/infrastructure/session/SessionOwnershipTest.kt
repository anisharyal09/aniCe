// SPDX-License-Identifier: GPL-3.0-or-later
// Verifies foreground, companion and observable automatic-policy ownership without UI interaction.
package io.github.anisharyal09.anice.infrastructure.session

import io.github.anisharyal09.anice.infrastructure.connections.ConnectionState
import android.content.Context
import androidx.compose.runtime.snapshots.Snapshot
import androidx.compose.runtime.snapshots.SnapshotStateObserver
import org.junit.Assume.assumeTrue
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.github.anisharyal09.anice.AniCeApplication
import io.github.anisharyal09.anice.infrastructure.connections.CompanionProbe
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SessionOwnershipTest {
  @Test fun applicationConstructionDoesNotReadAnUnattachedContext() {
    val detached = AniCeApplication()
    assertNull(detached.baseContext)
    assertEquals(io.github.anisharyal09.anice.features.transfer.TransferState.Idle, detached.transfer.state)
  }
  @Test fun duplicateConnectAndAutomaticAdoptionKeepTheAttemptGeneration() = runBlocking {
    val app = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as AniCeApplication
    val controller = app.sessionController
    val peer = withContext(Dispatchers.IO) { app.identityService.getOrCreateIdentity().identity }
      .copy(platform = "macos", deviceName = "Isolated attempt")
    withContext(Dispatchers.Main) {
      val owner = Any()
      controller.acquireCompanion(owner)
      try {
        controller.connect(peer)
        assumeTrue("Requires Bluetooth permissions and radio", controller.state == ConnectionState.CONNECTING)
        val progress = controller.progress.value
        assertTrue(controller.adoptAutomatic(peer))
        controller.connect(peer, automatic = true)
        assertSame(progress, controller.progress.value)
        assertFalse(controller.adoptAutomatic(peer.copy(fingerprint = "different")))
      } finally { controller.releaseCompanion(owner) }
    }
  }
  @Test fun automaticPreferenceNotifiesWithoutReadingStatus() = runBlocking {
    val app = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as AniCeApplication
    val policy = CompanionProbe.get(app)
    withContext(Dispatchers.Main) {
      assumeTrue("Requires native companion setup", policy.available && policy.address != null && policy.peerId != null)
      val wasArmed = policy.armed
      val wasAutomatic = app.getSharedPreferences("companion_feasibility", Context.MODE_PRIVATE)
        .getBoolean("automatic", false)
      val observer = SnapshotStateObserver { it() }
      var changes = 0
      fun observe() = observer.observeReads(Unit, { changes++ }) { policy.armed }
      observer.start()
      try {
        if (!policy.armed) policy.resume()
        Snapshot.sendApplyNotifications()
        observe()
        policy.pause()
        Snapshot.sendApplyNotifications()
        assertFalse(policy.armed)
        assertEquals(1, changes)
        observe()
        try {
          policy.resume { throw IllegalStateException("Injected trust lookup failure") }
          fail("Failed validation armed automatic connection")
        } catch (_: IllegalStateException) {}
        Snapshot.sendApplyNotifications()
        assertFalse(policy.armed)
        assertEquals(1, changes)
        policy.resume()
        Snapshot.sendApplyNotifications()
        assertTrue(policy.armed)
        assertTrue(changes >= 2)
        val afterResume = changes
        observe()
        policy.disable()
        Snapshot.sendApplyNotifications()
        assertFalse(policy.armed)
        assertTrue(changes > afterResume)
        val afterDisable = changes
        observe()
        policy.disable()
        Snapshot.sendApplyNotifications()
        assertEquals(afterDisable, changes)
      } finally {
        observer.stop(); observer.clear()
        if (wasArmed) {
          if (!policy.armed) policy.resume()
        } else if (wasAutomatic) policy.pause() else policy.disable()
      }
    }
  }

  @Test fun backgroundStateChangesEmitWithoutAComposePresentation() = runBlocking {
    val app = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as AniCeApplication
    val controller = app.sessionController
    val policy = CompanionProbe.get(app)
    val peer = withContext(Dispatchers.IO) { app.identityService.getOrCreateIdentity().identity }
      .copy(platform = "macos", deviceName = "Isolated observer")
    val token = Any()
    val resume = withContext(Dispatchers.Main) { policy.armed }
    try {
      withContext(Dispatchers.Main) {
        if (resume) policy.pause()
        controller.cancel()
        // No Activity/Recomposer or snapshot notification is started by this test.
        val next = async(start = CoroutineStart.UNDISPATCHED) {
          controller.progress.first { it.state != ConnectionState.DISCONNECTED }
        }
        controller.foreground(token)
        controller.connect(peer)
        val observed = withTimeout(2000) { next.await() }
        assertEquals(controller.state, controller.progress.value.state)
        assertTrue(observed.state == ConnectionState.CONNECTING || observed.state == ConnectionState.FAILED)
        controller.background(token)
        assertEquals(ConnectionState.DISCONNECTED, controller.progress.value.state)
        assertNull(controller.progress.value.controls)
        assertNull(controller.progress.value.renewal)
      }
    } finally {
      withContext(Dispatchers.Main) {
        controller.background(token)
        if (resume) policy.resume()
      }
    }
  }
  @Test fun openingAndLeavingProbeDoesNotBackgroundAnotherVisibleActivity() {
    val runner = InstrumentationRegistry.getInstrumentation()
    val app = runner.targetContext.applicationContext as AniCeApplication
    runner.runOnMainSync {
      val controller = app.sessionController
      val home = Any()
      val probe = Any()
      try {
        controller.foreground(home)
        controller.foreground(probe)
        controller.foreground(probe) // Duplicate starts are idempotent.
        controller.background(home)
        controller.presentationCleared()
        assertTrue(controller.foreground)
        controller.background(home) // Stale stops cannot release the other activity.
        assertTrue(controller.foreground)
        controller.foreground(home)
        controller.background(probe)
        assertTrue(controller.foreground)
        controller.background(home, changingConfigurations = true)
        assertFalse(controller.foreground)
        controller.foreground(home)
        controller.background(home)
        assertFalse(controller.foreground)
      } finally {
        controller.background(home)
        controller.background(probe)
      }
    }
  }

  @Test fun uiClearAndStaleReleaseCannotRetireTheCurrentCompanionOwner() {
    val runner = InstrumentationRegistry.getInstrumentation()
    val app = runner.targetContext.applicationContext as AniCeApplication
    runner.runOnMainSync {
      val controller = app.sessionController
      val current = Any()
      val stale = Any()
      controller.cancel()
      try {
        controller.acquireCompanion(current)
        controller.foreground()
        controller.background()
        controller.presentationCleared()
        assertTrue(controller.hasCompanionOwner)
        controller.releaseCompanion(stale)
        assertTrue(controller.hasCompanionOwner)
        try { controller.acquireCompanion(stale); fail("A second owner was admitted") }
        catch (_: IllegalStateException) {}
        controller.releaseCompanion(current)
        assertFalse(controller.hasCompanionOwner)
        assertEquals(ConnectionState.DISCONNECTED, controller.state)
        controller.acquireCompanion(stale)
        controller.releaseCompanion(current)
        assertTrue(controller.hasCompanionOwner)
      } finally {
        controller.releaseCompanion(current)
        controller.releaseCompanion(stale)
        controller.background()
      }
    }
  }
}
