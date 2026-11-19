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
import io.github.anisharyal09.anice.infrastructure.bluetooth.PairedBleCandidate
import io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity
import io.github.anisharyal09.anice.ui.theme.AniCeTheme
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ComparisonPresentationTest {
    @Suppress("UNCHECKED_CAST")
    private fun <T> state(model: PairingViewModel, name: String) =
        PairingViewModel::class.java.getDeclaredField("$name\$delegate")
            .apply { isAccessible = true }.get(model) as MutableState<T>

    @Test fun comparisonVisibilitySubscribesEvenWhenTheInitialMethodIsNotSas() {
        val runner = InstrumentationRegistry.getInstrumentation()
        val app = runner.targetContext.applicationContext as io.github.anisharyal09.anice.AniCeApplication
        assumeTrue("Use an isolated preview", app.packageName.contains(".preview"))
        runner.runOnMainSync {
            val model = PairingViewModel(app)
            val store = androidx.lifecycle.ViewModelStore().apply { put("comparison", model) }
            val observer = SnapshotStateObserver { it() }
            var invalidations = 0
            observer.start()
            try {
                state<PairingMethod>(model, "method").value = PairingMethod.QR
                state<String>(model, "phase").value = "idle"
                Snapshot.sendApplyNotifications()
                observer.observeReads("comparison", { invalidations++ }) { assertFalse(model.comparingNearby) }
                state<PairingMethod>(model, "method").value = PairingMethod.SAS
                state<String>(model, "phase").value = "preparing"
                Snapshot.sendApplyNotifications()
                assertTrue(invalidations > 0)
                assertTrue(model.comparingNearby)
            } finally {
                observer.stop(); observer.clear()
                store.clear()
            }
        }
    }

    @Test fun everyPairingMethodHandsOffItsNativeCandidateOnlyOnceAfterTrustIsSaved() {
        val runner = InstrumentationRegistry.getInstrumentation()
        val app = runner.targetContext.applicationContext as io.github.anisharyal09.anice.AniCeApplication
        assumeTrue("Use an isolated preview", app.packageName.contains(".preview"))
        runner.runOnMainSync {
            val model = PairingViewModel(app)
            val store = androidx.lifecycle.ViewModelStore().apply { put("pairing", model) }
            val peer = DeviceIdentity("fixture", "Verified Mac", "macos", "key", "fingerprint")
            val candidateField = PairingViewModel::class.java.getDeclaredField("pairedCandidate")
                .apply { isAccessible = true }
            try {
                for (method in listOf(PairingMethod.QR, PairingMethod.PIN, PairingMethod.SAS)) {
                    state<PairingMethod>(model, "method").value = method
                    state<Boolean>(model, "completedWithComparison").value = method == PairingMethod.SAS
                    val candidate = PairedBleCandidate(null, peer, SystemClock.elapsedRealtime() + 15_000)
                    candidateField.set(model, candidate)
                    state<String>(model, "phase").value = "saving"
                    assertNull(model.takePairedCandidate())
                    state<String>(model, "phase").value = "paired"
                    assertSame("All pairing methods must share the fresh Bluetooth handoff", candidate, model.takePairedCandidate())
                    assertNull(model.takePairedCandidate())
                }
            } finally { model.cancel(); store.clear() }
        }
    }

    @Test fun globalAndAddDeviceSurfacesRenderTheSameLiveCodeAcrossPhaseChanges() {
        val runner = InstrumentationRegistry.getInstrumentation()
        assumeTrue("UI fixture runs only on an isolated emulator", Build.HARDWARE in setOf("ranchu", "goldfish"))
        assumeTrue(runner.targetContext.packageName.contains(".preview"))
        runner.uiAutomation
        // Hold Home's unrelated first-launch prompt without changing OS permissions.
        val fixture = PresentationFixture()
        val activity = runner.startActivitySync(fixture.intent()) as MainActivity
        lateinit var model: PairingViewModel
        val store = androidx.lifecycle.ViewModelStore()
        var initialized = false
        val embedded = mutableStateOf(false)
        val scale = mutableFloatStateOf(1f)
        val dark = mutableStateOf(false)
        try {
            runner.runOnMainSync {
                // The fixture has its own pairing owner; native Activity lifecycle must not cancel a synthetic exchange.
                model = PairingViewModel(runner.targetContext.applicationContext as io.github.anisharyal09.anice.AniCeApplication)
                store.put("comparison", model)
                initialized = true
                model.beforePairing = {}
                model.cancel()
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
                    state<PairingMethod>(model, "method").value = PairingMethod.SAS
                    state<String>(model, "phase").value = "preparing"
                    state<String>(model, "status").value = "Preparing a nearby comparison…"
                    state<String?>(model, "comparisonCode").value = null
                }
                awaitLabels("Connect your Mac", "Preparing a nearby comparison…")
                runner.runOnMainSync {
                    state<Long>(model, "comparisonAttempt").value = 42L
                    state<String?>(model, "comparisonCode").value = "012345"
                    state<String>(model, "phase").value = "comparison"
                }
                val tree = awaitLabels("012 345", "Confirm", "Dismiss", "Reconnect automatically")
                val confirm = clickable(find(tree, "Confirm"))
                assertNotNull(confirm)
                assertTrue(confirm!!.isEnabled)
                val rectangle = android.graphics.Rect()
                confirm.getBoundsInScreen(rectangle)
                assertTrue(rectangle.height() >= (48 * activity.resources.displayMetrics.density).toInt() - 1)
                runner.runOnMainSync {
                    state<String>(model, "phase").value = "waiting"
                    state<String>(model, "status").value = "Confirmed here. Waiting for your Mac…"
                }
                val waiting = awaitLabels("012 345", "Confirmed here. Waiting for your Mac…")
                assertFalse(clickable(find(waiting, "Confirm"))!!.isEnabled)
                runner.runOnMainSync {
                    state<String?>(model, "comparisonCode").value = null
                    state<String>(model, "phase").value = "idle"
                    state<PairingMethod>(model, "method").value = PairingMethod.QR
                }
                runner.waitForIdleSync()
            }
        } finally {
            runner.runOnMainSync { if (initialized) model.cancel(); store.clear(); activity.finish() }
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
