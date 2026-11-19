// SPDX-License-Identifier: GPL-3.0-or-later
// Checks retained approval ownership and stable themed setup without BLE, native enrollment or trust changes.
package io.github.anisharyal09.anice.features.backgroundprobe

import android.app.PendingIntent
import android.content.Intent
import android.content.res.Configuration
import android.graphics.Rect
import android.os.Build
import android.os.SystemClock
import android.view.WindowManager
import android.view.accessibility.AccessibilityNodeInfo
import androidx.activity.compose.setContent
import androidx.compose.runtime.*
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Density
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.ViewModelStore
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.github.anisharyal09.anice.AniCeApplication
import io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity
import io.github.anisharyal09.anice.ui.theme.AniCeTheme
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class CompanionSetupPresentationTest {
    private val runner get() = InstrumentationRegistry.getInstrumentation()
    private fun isolatedEmulator() {
        assumeTrue("Setup fixtures run only in an isolated emulator", Build.HARDWARE in setOf("ranchu", "goldfish"))
        assumeTrue(runner.targetContext.packageName.contains(".preview"))
    }
    @Suppress("UNCHECKED_CAST")
    private fun <T> state(model: CompanionSetupViewModel, name: String) =
        CompanionSetupViewModel::class.java.getDeclaredField("$name\$delegate")
            .apply { isAccessible = true }.get(model) as MutableState<T>

    @Test fun rotationRetainsOneApprovalAndCancelFencesItsLateResult() {
        isolatedEmulator()
        val scenario = ActivityScenario.launch<CompanionQuickSetupActivity>(
            Intent(runner.targetContext, CompanionQuickSetupActivity::class.java))
        lateinit var original: CompanionSetupViewModel
        var pending: PendingIntent? = null
        try {
            awaitLabels(CompanionSetupCopy.title, "Close")
            scenario.onActivity { activity ->
                original = ViewModelProvider(activity)[CompanionSetupViewModel::class.java]
                state<DeviceIdentity?>(original, "peer").value = DeviceIdentity("fixture", "Fixture Mac", "macos", "", "")
                state<CompanionSetupPhase>(original, "phase").value = CompanionSetupPhase.PREPARING
                val op = CompanionSetupViewModel::class.java.getDeclaredField("generation")
                    .apply { isAccessible = true }.getInt(original)
                // A sender is claimed but never sent. No system association or permission is requested.
                pending = PendingIntent.getActivity(activity, 431, Intent(activity, CompanionQuickSetupActivity::class.java),
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_CANCEL_CURRENT)
                val approval = CompanionApproval(op, requireNotNull(pending).intentSender)
                state<CompanionApproval?>(original, "pendingApproval").value = approval
                assertSame(approval.sender, original.claimApproval(approval))
                repeat(5) { assertNull(original.claimApproval(approval)) }
                assertEquals(CompanionSetupPhase.APPROVAL, original.phase)
            }
            scenario.recreate()
            scenario.onActivity { activity ->
                val retained = ViewModelProvider(activity)[CompanionSetupViewModel::class.java]
                assertSame("Rotation must not create another enrollment owner", original, retained)
                assertEquals(CompanionSetupPhase.APPROVAL, retained.phase)
                assertNull(retained.pendingApproval)
                retained.startWhenReady()
                assertEquals(CompanionSetupPhase.APPROVAL, retained.phase)
                retained.cancel()
                val cancelled = retained.notice
                assertFalse("An old chooser result must be drained before another attempt", retained.canEnable)
                retained.approvalReturned(success = true, association = null)
                assertEquals(cancelled, retained.notice)
                assertEquals(CompanionSetupPhase.READY, retained.phase)
                assertTrue(retained.canEnable)
                assertFalse(retained.complete)
            }
        } finally {
            pending?.cancel()
            scenario.close()
        }
    }

    @Test fun freshProcessNeverAutomaticallyRepeatsAnInterruptedApproval() {
        isolatedEmulator()
        runner.runOnMainSync {
            val model = CompanionSetupViewModel(runner.targetContext.applicationContext as AniCeApplication)
            val store = ViewModelStore().apply { put("setup", model) }
            try {
                // Null peer avoids any native identity/trust lookup; only restored-start policy is exercised.
                model.initialize(null, quick = true, enable = true, restored = true)
                state<DeviceIdentity?>(model, "peer").value = DeviceIdentity("fixture", "Fixture Mac", "macos", "", "")
                state<CompanionSetupPhase>(model, "phase").value = CompanionSetupPhase.READY
                model.startWhenReady()
                assertEquals(CompanionSetupPhase.READY, model.phase)
                assertNull(model.pendingApproval)
                assertNull(model.permissionRequest)
                assertFalse(model.complete)
            } finally { store.clear() }
        }
    }

    @Test fun preparationAndApprovalKeepTheSamePanelAcrossThemesWidthsAndTextScales() {
        isolatedEmulator()
        val scenario = ActivityScenario.launch<CompanionQuickSetupActivity>(
            Intent(runner.targetContext, CompanionQuickSetupActivity::class.java))
        val phase = mutableStateOf(CompanionSetupPhase.LOADING)
        val scale = mutableFloatStateOf(1f)
        val dark = mutableStateOf(false)
        try {
            scenario.onActivity { activity ->
                activity.setContent {
                    val configuration = Configuration(LocalConfiguration.current).apply {
                        uiMode = (uiMode and Configuration.UI_MODE_NIGHT_MASK.inv()) or
                            if (dark.value) Configuration.UI_MODE_NIGHT_YES else Configuration.UI_MODE_NIGHT_NO
                    }
                    CompositionLocalProvider(LocalConfiguration provides configuration) {
                        AniCeTheme {
                            val density = LocalDensity.current
                            CompositionLocalProvider(LocalDensity provides Density(density.density, scale.floatValue)) {
                                CompanionSetupPanel("Fixture Mac", phase.value, "", {}, {})
                            }
                        }
                    }
                }
            }
            for (width in listOf(280, 360)) for (fontScale in listOf(0.8f, 1.2f)) for (night in listOf(false, true)) {
                var minimumTouchHeight = 0
                scenario.onActivity { activity ->
                    activity.window.setLayout((width * activity.resources.displayMetrics.density).toInt(),
                        WindowManager.LayoutParams.WRAP_CONTENT)
                    minimumTouchHeight = (48 * activity.resources.displayMetrics.density).toInt() - 1
                    scale.floatValue = fontScale
                    dark.value = night
                    phase.value = CompanionSetupPhase.LOADING
                }
                drawn(scenario)
                val before = bounds(clickable(find(awaitLabels(CompanionSetupCopy.title, "Fixture Mac", "Not now"), "Not now")))
                assertTrue(before.height() >= minimumTouchHeight)
                for (step in listOf(CompanionSetupPhase.READY, CompanionSetupPhase.PREPARING,
                    CompanionSetupPhase.APPROVAL, CompanionSetupPhase.SAVING)) {
                    scenario.onActivity { phase.value = step }
                    drawn(scenario)
                    val tree = awaitLabels(CompanionSetupCopy.title, CompanionSetupCopy.explanation,
                        CompanionSetupCopy.permissions, "Not now")
                    assertEquals("Setup resized during $step at $width dp / $fontScale / dark=$night",
                        before, bounds(clickable(find(tree, "Not now"))))
                    assertNull("Preparation must never flash a retry control", find(tree, "Try again"))
                }
                if (width == 280 && fontScale == 1.2f) {
                    runner.uiAutomation.takeScreenshot()?.let { image ->
                        File(runner.targetContext.cacheDir, "companion-setup-${if (night) "dark" else "light"}.png")
                            .outputStream().use { image.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) }
                        image.recycle()
                    }
                }
                scenario.onActivity { phase.value = CompanionSetupPhase.FAILED }
                val failed = awaitLabels(CompanionSetupCopy.title, "Close", "Try again")
                assertTrue(bounds(clickable(find(failed, "Try again"))).height() >= minimumTouchHeight)
            }
        } finally { scenario.close() }
    }

    private fun awaitLabels(vararg labels: String): AccessibilityNodeInfo {
        val automation = runner.uiAutomation
        val deadline = SystemClock.uptimeMillis() + 5_000
        do {
            automation.waitForIdle(100, 1000)
            if (Build.VERSION.SDK_INT >= 34) automation.clearCache()
            val root = automation.rootInActiveWindow
            if (root != null && labels.all { find(root, it)?.isVisibleToUser == true }) return root
        } while (SystemClock.uptimeMillis() < deadline)
        error("Setup panel did not show ${labels.joinToString()}")
    }
    private fun drawn(scenario: ActivityScenario<CompanionQuickSetupActivity>) {
        val drawn = CountDownLatch(1)
        scenario.onActivity { activity ->
            activity.window.decorView.postOnAnimation {
                activity.window.decorView.postOnAnimation {
                    activity.window.decorView.post { drawn.countDown() }
                }
            }
        }
        assertTrue("Setup frame did not draw", drawn.await(10, TimeUnit.SECONDS))
        runner.waitForIdleSync()
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
    private fun bounds(node: AccessibilityNodeInfo?): Rect =
        Rect().also { requireNotNull(node) { "Missing accessible control" }.getBoundsInScreen(it) }
}
