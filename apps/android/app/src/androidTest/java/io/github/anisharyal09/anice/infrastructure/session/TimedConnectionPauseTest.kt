// SPDX-License-Identifier: GPL-3.0-or-later
// Exercises timed connection-pause catch-up on an isolated emulator without arming Bluetooth.
package io.github.anisharyal09.anice.infrastructure.session

import android.content.Context
import android.content.BroadcastReceiver
import android.content.Intent
import android.os.Build
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.github.anisharyal09.anice.AniCeApplication
import io.github.anisharyal09.anice.infrastructure.connections.CompanionProbe
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class TimedConnectionPauseTest {
    @Test fun foregroundReturnClearsAnExpiredPauseWithoutEnablingDisabledAutomation() = exercise(expired = true)
    @Test fun foregroundReturnDoesNotClearAnIndefinitePause() = exercise(expired = false)
    @Test fun screenReturnClearsAnExpiredPauseWhileTheAppRemainsInBackground() = exercise(expired = true, screenReturn = true)
    @Test fun anExplicitPauseReplacesAndCancelsATimedPause() = exercise(expired = false, replaceTimed = true)

    private fun exercise(expired: Boolean, screenReturn: Boolean = false, replaceTimed: Boolean = false) = runBlocking {
        val app = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as AniCeApplication
        assumeTrue("Pause fixtures run only on the isolated UI preview", app.packageName == "io.github.anisharyal09.anice.preview")
        assumeTrue("Pause fixtures never use a physical phone", Build.HARDWARE in setOf("ranchu", "goldfish"))
        val preferences = app.getSharedPreferences("companion_feasibility", Context.MODE_PRIVATE)
        val keys = listOf("automatic", "armed", "paused", "paused_until")
        val previous = preferences.all
        val token = Any()
        val policy = withContext(Dispatchers.Main) { CompanionProbe.get(app) }
        val automaticLan = withContext(Dispatchers.Main) { app.lanSessionController.automatic }
        assumeTrue("The preview must not have a configured companion association", policy.address == null && policy.peerId == null)
        try {
            withContext(Dispatchers.Main) {
                policy.disable()
                app.lanSessionController.setAutomaticEnabled(false)
                policy.pauseFor(if (expired || replaceTimed) 60_000L else null)
                if (replaceTimed) {
                    assertTrue(policy.pause("Manually paused"))
                    assertFalse(preferences.contains("paused_until"))
                }
                if (expired) assertTrue(preferences.edit().putLong("paused_until", System.currentTimeMillis() - 60_000).commit())
                if (screenReturn) {
                    val receiver = policy.javaClass.getDeclaredField("pauseEvents").apply { isAccessible = true }
                        .get(policy) as BroadcastReceiver
                    receiver.onReceive(app, Intent(Intent.ACTION_SCREEN_ON))
                } else app.sessionController.foreground(token)
            }
            if (expired) {
                withTimeout(2000) {
                    while (withContext(Dispatchers.Main) { policy.connectionPaused }) delay(10)
                }
                assertNull(policy.connectionPauseUntil)
                assertFalse(preferences.contains("paused_until"))
                assertFalse(preferences.getBoolean("paused", true))
            } else {
                assertTrue(policy.connectionPaused)
                assertNull(policy.connectionPauseUntil)
            }
            assertFalse(policy.automaticEnabled)
            assertFalse(app.lanSessionController.automatic)
            assertFalse(policy.armed)
        } finally {
            withContext(NonCancellable + Dispatchers.Main) {
                app.sessionController.background(token)
                policy.disable()
                val edit = preferences.edit()
                for (key in keys) {
                    edit.remove(key)
                    when (val value = previous[key]) {
                        is Boolean -> edit.putBoolean(key, value)
                        is Long -> edit.putLong(key, value)
                    }
                }
                assertTrue(edit.commit())
                app.lanSessionController.setAutomaticEnabled(automaticLan)
            }
        }
    }
}
