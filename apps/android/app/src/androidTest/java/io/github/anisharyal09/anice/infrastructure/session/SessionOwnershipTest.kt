// SPDX-License-Identifier: GPL-3.0-or-later
package io.github.anisharyal09.anice.infrastructure.session

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.github.anisharyal09.anice.AniCeApplication
import io.github.anisharyal09.anice.features.backgroundprobe.CompanionProbe
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SessionOwnershipTest {
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
