// SPDX-License-Identifier: GPL-3.0-or-later
package io.github.anisharyal09.anice.infrastructure.session

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.github.anisharyal09.anice.AniCeApplication
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SessionOwnershipTest {
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
