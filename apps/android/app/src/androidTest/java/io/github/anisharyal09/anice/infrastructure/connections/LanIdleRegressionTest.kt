// SPDX-License-Identifier: GPL-3.0-or-later
// Exercises the native LAN policy with isolated preferences and synthetic state, never user radio or socket work.
package io.github.anisharyal09.anice.infrastructure.connections

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.SystemClock
import androidx.compose.runtime.MutableState
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.github.anisharyal09.anice.AniCeApplication
import io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity
import java.util.UUID
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class LanIdleRegressionTest {
    private class Fixture(val app: AniCeApplication, val now: () -> Long = SystemClock::elapsedRealtime) {
        val name = "lan-idle-regression.${UUID.randomUUID()}"
        val preferences = app.getSharedPreferences(name, Context.MODE_PRIVATE).also {
            check(it.edit().putBoolean("automatic_lan", false)
                .putInt("lan_background_timeout_minutes", 1).commit())
        }
        val presentation = Any()
        val controller = LanSessionController(app,
            backgroundTimeoutMillis = { preferences.getInt("lan_background_timeout_minutes", 0) * 120L },
            recoveryDelays = emptyList(), elapsedRealtime = now, interactive = { true },
            preferences = preferences)

        fun field(name: String): Any? = LanSessionController::class.java.getDeclaredField(name)
            .apply { isAccessible = true }.get(controller)

        @Suppress("UNCHECKED_CAST")
        fun secured() {
            (field("connectionState\$delegate") as MutableState<ConnectionState>).value = ConnectionState.SECURED
        }

        fun close() {
            controller.dispose()
            app.deleteSharedPreferences(name)
        }
    }

    private suspend fun fixture(now: () -> Long = SystemClock::elapsedRealtime): Fixture = withContext(Dispatchers.Main) {
        val app = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as AniCeApplication
        assumeTrue("Only an isolated test target may exercise policy state",
            app.packageName in setOf("io.github.anisharyal09.anice.preview",
                "io.github.anisharyal09.anice.preview.transfer", "io.github.anisharyal09.anice.preview.transfer.regression"))
        Fixture(app, now)
    }

    private suspend fun disconnected(fixture: Fixture) = withTimeout(2_000) {
        while (withContext(Dispatchers.Main) { fixture.controller.state != ConnectionState.DISCONNECTED }) delay(10)
    }

    @Test fun homeAndDuplicateIdleUpdatesRetireLanWithoutARecomposer() = runBlocking {
        val fixture = fixture()
        try {
            withContext(Dispatchers.Main) {
                fixture.controller.foreground(fixture.presentation)
                fixture.secured()
                fixture.controller.background(fixture.presentation, false)
                val deadline = (fixture.field("backgroundIdle") as LanBackgroundIdle).deadline
                assertNotNull(deadline)
                repeat(30) { fixture.controller.updateWorkLease(false, false); fixture.controller.onWorkIdle() }
                assertEquals(deadline, (fixture.field("backgroundIdle") as LanBackgroundIdle).deadline)
                assertNotNull(fixture.field("backgroundTimeoutJob"))
            }
            disconnected(fixture)
        } finally { withContext(NonCancellable + Dispatchers.Main) { fixture.close() } }
    }

    @Test fun screenOffRetiresLanEvenWhenAndroidHasNotStoppedTheActivityYet() = runBlocking {
        val fixture = fixture()
        try {
            withContext(Dispatchers.Main) {
                fixture.controller.foreground(fixture.presentation)
                fixture.secured()
                (fixture.field("screenReceiver") as BroadcastReceiver).onReceive(fixture.app, Intent(Intent.ACTION_SCREEN_OFF))
                assertTrue(fixture.controller.foreground)
                assertNotNull(fixture.field("backgroundTimeoutJob"))
            }
            disconnected(fixture)
        } finally { withContext(NonCancellable + Dispatchers.Main) { fixture.close() } }
    }

    @Test fun overdueIdleDeadlineSurvivesConnectionReplacementAndIsEnforcedBeforeAppReturn() = runBlocking {
        var now = 100L
        val fixture = fixture { now }
        try {
            withContext(Dispatchers.Main) {
                fixture.controller.foreground(fixture.presentation)
                fixture.secured()
                fixture.controller.background(fixture.presentation, false)
                val deadline = (fixture.field("backgroundIdle") as LanBackgroundIdle).deadline
                now = 180
                fixture.controller.cancel()
                fixture.secured()
                fixture.controller.updateWorkLease(false, false)
                assertEquals(deadline, (fixture.field("backgroundIdle") as LanBackgroundIdle).deadline)
                now = 300
                fixture.controller.foreground(fixture.presentation)
                assertEquals(ConnectionState.DISCONNECTED, fixture.controller.state)
                assertNull(fixture.field("backgroundTimeoutJob"))
            }
        } finally { withContext(NonCancellable + Dispatchers.Main) { fixture.close() } }
    }

    @Test fun workAndMediaRetainLanButTheirFinalReleaseStartsTheConfiguredIdleTimeout() = runBlocking {
        for (media in listOf(false, true)) {
            val fixture = fixture()
            try {
                withContext(Dispatchers.Main) {
                    fixture.controller.foreground(fixture.presentation)
                    fixture.secured()
                    if (media) fixture.controller.updateMediaLease(true) else fixture.controller.updateWorkLease(true, false)
                    fixture.controller.background(fixture.presentation, false)
                    assertNull(fixture.field("backgroundTimeoutJob"))
                    assertNotNull(fixture.controller.backgroundRetentionReason)
                }
                delay(180)
                withContext(Dispatchers.Main) {
                    assertEquals(ConnectionState.SECURED, fixture.controller.state)
                    if (media) fixture.controller.updateMediaLease(false) else fixture.controller.updateWorkLease(false, false)
                    assertNull(fixture.controller.backgroundRetentionReason)
                    assertNotNull(fixture.field("backgroundTimeoutJob"))
                }
                disconnected(fixture)
            } finally { withContext(NonCancellable + Dispatchers.Main) { fixture.close() } }
        }
    }

    @Test fun shorteningTheSettingAppliesElapsedIdleTimeAndNeverRemovesOnlyTheIdleTimer() = runBlocking {
        var now = 100L
        val fixture = fixture { now }
        try {
            withContext(Dispatchers.Main) {
                fixture.controller.foreground(fixture.presentation)
                fixture.controller.setBackgroundTimeoutMinutes(5)
                fixture.secured()
                fixture.controller.background(fixture.presentation, false)
                now = 400
                fixture.controller.setBackgroundTimeoutMinutes(1)
                assertEquals(ConnectionState.DISCONNECTED, fixture.controller.state)
                fixture.secured()
                fixture.controller.setBackgroundTimeoutMinutes(0)
                assertNull(fixture.field("backgroundTimeoutJob"))
                now = 100_000
                fixture.controller.onWorkIdle()
                assertEquals(ConnectionState.SECURED, fixture.controller.state)
            }
        } finally { withContext(NonCancellable + Dispatchers.Main) { fixture.close() } }
    }

    @Test fun newFileDemandResumesTransportDisconnectButNotPauseOrDisabledAutomation() = runBlocking {
        for (block in listOf("none", "pause", "disabled")) {
            val fixture = fixture()
            val sent = mutableListOf<Int?>()
            val channel = object : SecuredChannel {
                override val descriptor = ChannelDescriptor("demand-test", "ble",
                    DeviceIdentity("fixture", "Isolated Mac", "macos", "key", "fingerprint"))
                override suspend fun sendData(bytes: ByteArray) { sent.add(LanRendezvousWire.decode(bytes)) }
            }
            try {
                withContext(Dispatchers.Main) {
                    fixture.controller.foreground(fixture.presentation)
                    fixture.controller.setAutomaticEnabled(true)
                    fixture.controller.disconnect()
                    fixture.controller.rendezvous.available(channel)
                    fixture.controller.rendezvous.handle(channel.descriptor, LanRendezvousWire.encode(1))
                    if (block == "pause") fixture.controller.preparePause()
                    if (block == "disabled") fixture.controller.setAutomaticEnabled(false)
                    assertFalse(fixture.controller.requestAutomaticConnection())
                    assertEquals(block == "none", fixture.controller.connectPreferred())
                }
                delay(50)
                withContext(Dispatchers.Main) {
                    assertEquals(block == "none", sent.any { it == 4 || it == 5 })
                    assertEquals(ConnectionState.DISCONNECTED, fixture.controller.state)
                    fixture.controller.rendezvous.retired(channel.descriptor)
                }
            } finally { withContext(NonCancellable + Dispatchers.Main) { fixture.close() } }
        }
    }

    @Test fun remoteUserDemandCanResumeDisconnectButCannotOverrideBackgroundPauseOrDisabledChoice() = runBlocking {
        for (block in listOf("none", "background", "pause", "disabled")) {
            val fixture = fixture()
            val channel = object : SecuredChannel {
                override val descriptor = ChannelDescriptor("remote-demand-test", "ble",
                    DeviceIdentity("fixture", "Isolated Mac", "macos", "key", "fingerprint"))
                override suspend fun sendData(bytes: ByteArray) {}
            }
            try {
                withContext(Dispatchers.Main) {
                    fixture.controller.foreground(fixture.presentation)
                    fixture.controller.setAutomaticEnabled(true)
                    fixture.controller.disconnect()
                    fixture.controller.rendezvous.available(channel)
                    fixture.controller.rendezvous.handle(channel.descriptor,
                        LanRendezvousWire.encode(LanRendezvousMessage(2, 1)))
                    if (block == "background") fixture.controller.background(fixture.presentation, false)
                    if (block == "pause") fixture.controller.preparePause()
                    if (block == "disabled") fixture.controller.setAutomaticEnabled(false)
                }
                // Native Wi-Fi availability may arrive asynchronously; no ready locator is supplied by this fixture.
                delay(80)
                withContext(Dispatchers.Main) {
                    fixture.controller.rendezvous.handle(channel.descriptor,
                        LanRendezvousWire.encode(LanRendezvousMessage(2, 4)))
                    assertFalse(fixture.controller.requestAutomaticConnection())
                    fixture.controller.rendezvous.handle(channel.descriptor,
                        LanRendezvousWire.encode(LanRendezvousMessage(2, 5)))
                    assertEquals(block == "none", fixture.controller.requestAutomaticConnection())
                    assertEquals(ConnectionState.DISCONNECTED, fixture.controller.state)
                    if (block == "background") {
                        fixture.controller.updateWorkLease(approved = true, picking = false)
                        assertTrue("Actual approved work should consume the retained user demand",
                            fixture.controller.requestAutomaticConnection())
                    }
                    fixture.controller.rendezvous.retired(channel.descriptor)
                }
            } finally { withContext(NonCancellable + Dispatchers.Main) { fixture.close() } }
        }
    }
}
