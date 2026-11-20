// SPDX-License-Identifier: GPL-3.0-or-later
// Exercises live comparison visibility through Compose and navigation without BLE, confirmation or trust mutations.
package io.github.anisharyal09.anice.features.pairing

import android.content.res.Configuration
import android.os.Build
import android.os.SystemClock
import android.view.accessibility.AccessibilityNodeInfo
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.snapshots.Snapshot
import androidx.compose.runtime.snapshots.SnapshotStateObserver
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.github.anisharyal09.anice.MainActivity
import io.github.anisharyal09.anice.ui.PresentationFixture
import io.github.anisharyal09.anice.infrastructure.pairing.PairingMethod
import io.github.anisharyal09.anice.ui.theme.AniCeTheme
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ComparisonPresentationTest {
    @Test fun comparisonVisibilitySubscribesEvenWhenTheInitialMethodIsNotSas() {
        PairingPresentationFixture.assumeIsolated()
        val runner = InstrumentationRegistry.getInstrumentation()
        runner.runOnMainSync {
            val fixture = PairingPresentationFixture()
            val model = fixture.model
            val observer = SnapshotStateObserver { it() }
            var invalidations = 0
            observer.start()
            try {
                fixture.present { method = PairingMethod.QR; phase = "idle" }
                Snapshot.sendApplyNotifications()
                observer.observeReads("comparison", { invalidations++ }) { assertFalse(model.comparingNearby) }
                fixture.present { method = PairingMethod.SAS; phase = "preparing" }
                Snapshot.sendApplyNotifications()
                assertTrue(invalidations > 0)
                assertTrue(model.comparingNearby)
                val beforePhaseChange = invalidations
                observer.observeReads("comparison", { invalidations++ }) { assertTrue(model.comparingNearby) }
                fixture.present { phase = "idle" }
                Snapshot.sendApplyNotifications()
                assertTrue("Live visibility must observe phase as well as method", invalidations > beforePhaseChange)
                assertFalse(model.comparingNearby)
            } finally {
                observer.stop(); observer.clear()
                fixture.close()
            }
        }
    }

    @Test fun globalAndAddDeviceSurfacesRenderTheSameLiveCodeAcrossPhaseChanges() {
        PairingPresentationFixture.assumeIsolated()
        val runner = InstrumentationRegistry.getInstrumentation()
        runner.uiAutomation
        // Hold Home's unrelated first-launch prompt without changing OS permissions.
        val fixture = PresentationFixture()
        val activity = runner.startActivitySync(fixture.intent()) as MainActivity
        lateinit var model: PairingViewModel
        var presentation: PairingPresentationFixture? = null
        var initialized = false
        val embedded = mutableStateOf(false)
        val scale = mutableFloatStateOf(1f)
        val dark = mutableStateOf(false)
        try {
            runner.runOnMainSync {
                // The fixture has its own pairing owner; native Activity lifecycle must not cancel a synthetic exchange.
                val owner = PairingPresentationFixture()
                presentation = owner
                model = owner.model
                initialized = true
                activity.setContent {
                    val configuration = Configuration(LocalConfiguration.current).apply {
                        uiMode = (uiMode and Configuration.UI_MODE_NIGHT_MASK.inv()) or
                            if (dark.value) Configuration.UI_MODE_NIGHT_YES else Configuration.UI_MODE_NIGHT_NO
                    }
                    CompositionLocalProvider(LocalConfiguration provides configuration) {
                        AniCeTheme {
                            val density = LocalDensity.current
                            CompositionLocalProvider(LocalDensity provides Density(density.density, scale.floatValue)) {
                                Surface(Modifier.fillMaxSize()) {
                                    Column(Modifier.safeDrawingPadding().padding(16.dp)) {
                                        Text("Comparison review fixture")
                                        if (embedded.value) PairingScreen(model)
                                        else ComparisonPrompt(model) {}
                                    }
                                }
                            }
                        }
                    }
                }
            }
            runner.waitForIdleSync()
            for (inline in listOf(false, true)) for (fontScale in listOf(0.8f, 1.2f)) for (night in listOf(false, true)) {
                runner.runOnMainSync {
                    embedded.value = inline
                    scale.floatValue = fontScale
                    dark.value = night
                    requireNotNull(presentation).present {
                        method = PairingMethod.SAS
                        phase = "preparing"
                        status = "Preparing a nearby comparison…"
                        comparisonCode = null
                    }
                }
                awaitLabels("Connect your Mac", "Preparing a nearby comparison…")
                runner.runOnMainSync {
                    requireNotNull(presentation).present {
                        comparisonAttempt = 42L
                        comparisonCode = "012345"
                        phase = "comparison"
                    }
                }
                val tree = awaitLabels("012 345", "Confirm", "Dismiss", "Reconnect automatically")
                val confirm = clickable(find(tree, "Confirm"))
                assertNotNull(confirm)
                assertTrue(confirm!!.isEnabled)
                val rectangle = android.graphics.Rect()
                confirm.getBoundsInScreen(rectangle)
                assertTrue(rectangle.height() >= (48 * activity.resources.displayMetrics.density).toInt() - 1)
                runner.runOnMainSync {
                    requireNotNull(presentation).present {
                        phase = "waiting"
                        status = "Confirmed here. Waiting for your Mac…"
                    }
                }
                val waiting = awaitLabels("012 345", "Confirmed here. Waiting for your Mac…")
                assertFalse(clickable(find(waiting, "Confirm"))!!.isEnabled)
                runner.runOnMainSync {
                    requireNotNull(presentation).present {
                        comparisonCode = null
                        phase = "idle"
                        method = PairingMethod.QR
                    }
                }
                runner.waitForIdleSync()
            }
        } finally {
            runner.runOnMainSync { if (initialized) presentation?.close(); activity.finish() }
            fixture.close()
        }
    }

    private fun awaitLabels(vararg labels: String): AccessibilityNodeInfo {
        val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
        val deadline = SystemClock.uptimeMillis() + 5_000
        do {
            automation.waitForIdle(100, 1000)
            if (Build.VERSION.SDK_INT >= 34) automation.clearCache()
            val root = automation.rootInActiveWindow
            if (root != null && labels.all { find(root, it)?.isVisibleToUser == true }) return root
        } while (SystemClock.uptimeMillis() < deadline)
        error("Comparison surface did not show ${labels.joinToString()}")
    }
    private fun find(node: AccessibilityNodeInfo?, label: String): AccessibilityNodeInfo? {
        if (node == null) return null
        if (node.text?.toString() == label || node.contentDescription?.toString() == label) return node
        for (index in 0 until node.childCount) find(node.getChild(index), label)?.let { return it }
        return null
    }
    private fun clickable(node: AccessibilityNodeInfo?): AccessibilityNodeInfo? {
        var current = node
        repeat(8) { if (current?.isClickable == true) return current; current = current?.parent }
        return null
    }
}
