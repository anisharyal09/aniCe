// SPDX-License-Identifier: GPL-3.0-or-later
// Verifies one retained inline approval, dismissal and themed layout without native enrollment or trust changes.
package io.github.anisharyal09.anice.features.backgroundprobe

import android.app.PendingIntent
import android.content.Intent
import android.content.res.Configuration
import android.graphics.Rect
import android.os.Build
import android.os.SystemClock
import android.view.accessibility.AccessibilityNodeInfo
import androidx.activity.compose.setContent
import androidx.compose.runtime.*
import androidx.compose.foundation.layout.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Density
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.ViewModelStore
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.github.anisharyal09.anice.AniCeApplication
import io.github.anisharyal09.anice.infrastructure.connections.ConnectionState
import io.github.anisharyal09.anice.infrastructure.connections.CompanionSetupTarget
import io.github.anisharyal09.anice.infrastructure.connections.SessionController
import io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity
import io.github.anisharyal09.anice.MainActivity
import io.github.anisharyal09.anice.ui.PresentationFixture
import androidx.compose.material3.Text
import androidx.compose.material3.Surface
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
    private val app get() = runner.targetContext.applicationContext as AniCeApplication
    private fun isolatedEmulator() {
        assumeTrue("Run only on an isolated emulator", Build.HARDWARE in setOf("ranchu", "goldfish"))
        assumeTrue(runner.targetContext.packageName.contains(".preview"))
    }
    @Suppress("UNCHECKED_CAST")
    private fun <T> state(model: Any, name: String) =
        model.javaClass.getDeclaredField("$name\$delegate")
            .apply { isAccessible = true }.get(model) as MutableState<T>
    private fun field(model: Any, name: String, value: Any?) =
        model.javaClass.getDeclaredField(name).apply { isAccessible = true }.set(model, value)
    private fun model(activity: MainActivity) =
        ViewModelProvider(activity, ViewModelProvider.AndroidViewModelFactory.getInstance(app))[CompanionSetupViewModel::class.java]
    private fun scenario(fixture: PresentationFixture) = ActivityScenario.launch<MainActivity>(fixture.intent())

    @Test fun rotationRetainsOneApprovalAndCancelFencesItsLateResult() {
        isolatedEmulator()
        val fixture = PresentationFixture()
        val scenario = scenario(fixture)
        lateinit var original: CompanionSetupViewModel
        val controller = app.sessionController
        val beforeState = controller.state
        val beforePeer = controller.selected
        var pending: PendingIntent? = null
        try {
            scenario.onActivity { activity ->
                activity.setContent { Text("Approval ownership fixture") }
                original = model(activity)
                val peer = DeviceIdentity("fixture", "Fixture Mac", "macos", "key", "fingerprint")
                original.start(peer)
                state<Boolean>(original, "startRequested").value = false
                state<CompanionSetupPhase>(original, "phase").value = CompanionSetupPhase.PREPARING
                state<ConnectionState>(controller, "state").value = ConnectionState.SECURED
                state<DeviceIdentity?>(controller, "selected").value = peer
                val operation = SessionController::class.java.getDeclaredField("operation")
                    .apply { isAccessible = true }.getLong(controller)
                val connection = SessionController::class.java.getDeclaredField("connection")
                    .apply { isAccessible = true }.get(controller)
                val token = "$operation-${System.identityHashCode(connection)}"
                val target = CompanionSetupTarget(peer, "02:00:00:00:00:01", token, SystemClock.elapsedRealtime() + 60_000)
                field(controller, "companionSetupTarget", target)
                field(original, "target", target)
                // Claim a sender but never launch it; no association/permission is created.
                pending = PendingIntent.getActivity(activity, 431, Intent(activity, MainActivity::class.java),
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_CANCEL_CURRENT)
                val approval = CompanionApproval(0, requireNotNull(pending).intentSender)
                state<CompanionApproval?>(original, "pendingApproval").value = approval
                assertSame(approval.sender, original.claimApproval(approval))
                repeat(5) { assertNull(original.claimApproval(approval)) }
            }
            scenario.recreate()
            scenario.onActivity { activity ->
                activity.setContent { Text("Approval ownership fixture") }
                val retained = model(activity)
                assertSame(original, retained)
                assertEquals(CompanionSetupPhase.APPROVAL, retained.phase)
                assertNull(retained.pendingApproval)
                retained.dismiss()
                assertFalse("Drain the old result before starting another request", retained.canStart)
                retained.approvalReturned(success = true, association = null)
                assertTrue(retained.canStart)
                assertFalse(retained.showing)
                assertEquals(CompanionSetupPhase.READY, retained.phase)
            }
        } finally {
            pending?.cancel()
            scenario.close()
            fixture.close()
            runner.runOnMainSync {
                field(controller, "companionSetupTarget", null)
                state<ConnectionState>(controller, "state").value = beforeState
                state<DeviceIdentity?>(controller, "selected").value = beforePeer
            }
        }
    }

    @Test fun aReplacementOwnerDoesNotRepeatAnInterruptedApproval() {
        isolatedEmulator()
        runner.runOnMainSync {
            val model = CompanionSetupViewModel(app)
            val store = ViewModelStore().apply { put("setup", model) }
            try {
                model.startWhenReady()
                assertFalse(model.startRequested)
                assertFalse(model.showing)
                assertNull(model.pendingApproval)
                assertNull(model.permissionRequest)
            } finally { store.clear() }
        }
    }

    @Test fun everyEntryPointUsesOneCredentialAndBackgroundOrDismissalCannotRestartIt() {
        isolatedEmulator()
        runner.runOnMainSync {
            val model = CompanionSetupViewModel(app)
            val store = ViewModelStore().apply { put("setup", model) }
            try {
                val peer = DeviceIdentity("fixture", "Fixture Mac", "macos", "key", "fingerprint")
                model.start(peer)
                val initiallyShowing = model.showing
                assertFalse("The request owns the next enrollment", model.canStart)
                model.start(peer.copy(deviceId = "replacement"))
                assertEquals(peer, model.peer)
                model.presentationStopped(changingConfigurations = true)
                assertEquals(initiallyShowing, model.showing)
                model.presentationStopped(changingConfigurations = false)
                assertFalse(model.showing)
                model.start(peer)
                model.dismiss()
                model.startWhenReady()
                assertFalse(model.showing)
                assertNull(model.pendingApproval)
                assertNull(model.permissionRequest)
            } finally { store.clear() }
        }
    }

    @Test fun quietResumeIsCancelledWhenPresentationStopsWithoutShowingACard() {
        isolatedEmulator()
        runner.runOnMainSync {
            val model = CompanionSetupViewModel(app)
            val store = ViewModelStore().apply { put("setup", model) }
            try {
                val peer = DeviceIdentity("fixture", "Fixture Mac", "macos", "key", "fingerprint")
                model.start(peer)
                state<Boolean>(model, "showing").value = false
                state<CompanionSetupPhase>(model, "phase").value = CompanionSetupPhase.CONNECTING
                assertFalse("A quiet resume still owns the request", model.canStart)
                model.presentationStopped(changingConfigurations = false)
                assertFalse(model.startRequested)
                assertFalse(model.showing)
                assertEquals(CompanionSetupPhase.READY, model.phase)
            } finally { store.clear() }
        }
    }

    @Test fun unpinnedApprovalIsRejectedWithoutLaunchingIt() {
        isolatedEmulator()
        runner.runOnMainSync {
            val model = CompanionSetupViewModel(app)
            val store = ViewModelStore().apply { put("setup", model) }
            val pending = PendingIntent.getActivity(runner.targetContext, 432,
                Intent(runner.targetContext, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
            try {
                model.start(DeviceIdentity("fixture", "Fixture Mac", "macos", "key", "fingerprint"))
                state<Boolean>(model, "startRequested").value = false
                val approval = CompanionApproval(0, pending.intentSender)
                state<CompanionApproval?>(model, "pendingApproval").value = approval
                assertNull(model.claimApproval(approval))
                assertEquals(CompanionSetupPhase.FAILED, model.phase)
                assertNull(model.pendingApproval)
            } finally { pending.cancel(); store.clear() }
        }
    }

    @Test fun setupStaysCompactAcrossThemesWidthsAndTextScales() {
        isolatedEmulator()
        val fixture = PresentationFixture()
        val scenario = scenario(fixture)
        lateinit var model: CompanionSetupViewModel
        val scale = mutableFloatStateOf(1f)
        val dark = mutableStateOf(false)
        val width = mutableIntStateOf(280)
        try {
            scenario.onActivity { activity ->
                model = model(activity)
                model.start(DeviceIdentity("fixture", "Fixture Mac", "macos", "key", "fingerprint"))
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
                                    Box(Modifier.safeDrawingPadding().padding(top = 16.dp)) {
                                        Column(Modifier.width(width.intValue.dp)) { CompanionSetupStatus(model) }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            for (widthDp in listOf(280, 360)) for (fontScale in listOf(0.8f, 1.2f)) for (night in listOf(false, true)) {
                var minimumTouchHeight = 0
                scenario.onActivity { activity ->
                    width.intValue = widthDp
                    minimumTouchHeight = (48 * activity.resources.displayMetrics.density).toInt() - 1
                    scale.floatValue = fontScale
                    dark.value = night
                    state<CompanionSetupPhase>(model, "phase").value = CompanionSetupPhase.PREPARING
                }
                drawn(scenario)
                val preparedTree = awaitLabels(CompanionSetupCopy.title, "Not now")
                val before = bounds(clickable(find(preparedTree, "Not now")))
                assertTrue("Not now bounds=$before, expected height >= $minimumTouchHeight at $widthDp / $fontScale",
                    before.height() >= minimumTouchHeight)
                for (phase in listOf(CompanionSetupPhase.APPROVAL, CompanionSetupPhase.SAVING)) {
                    scenario.onActivity { state<CompanionSetupPhase>(model, "phase").value = phase }
                    drawn(scenario)
                    val tree = awaitLabels(CompanionSetupCopy.title, CompanionSetupCopy.explanation, "Not now")
                    assertEquals("Pending approval resized", before, bounds(clickable(find(tree, "Not now"))))
                    assertNull(find(tree, "Try again"))
                }
                if (widthDp == 280 && fontScale == 1.2f) runner.uiAutomation.takeScreenshot()?.let { image ->
                    File(runner.targetContext.cacheDir, "auto-connect-${if (night) "dark" else "light"}.png")
                        .outputStream().use { image.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) }
                    image.recycle()
                }
                scenario.onActivity {
                    state<CompanionSetupPhase>(model, "phase").value = CompanionSetupPhase.FAILED
                    state<String>(model, "notice").value = "Couldn't connect. Try again."
                }
                val failed = awaitLabels("Not now", "Try again")
                assertTrue(bounds(clickable(find(failed, "Try again"))).height() >= minimumTouchHeight)
                scenario.onActivity { state<String>(model, "notice").value = "" }
            }
        } finally { scenario.close(); fixture.close() }
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
        error("Setup did not show ${labels.joinToString()}")
    }
    private fun drawn(scenario: ActivityScenario<MainActivity>) {
        val drawn = CountDownLatch(1)
        scenario.onActivity { activity ->
            activity.window.decorView.postOnAnimation {
                activity.window.decorView.postOnAnimation { activity.window.decorView.post { drawn.countDown() } }
            }
        }
        assertTrue(drawn.await(10, TimeUnit.SECONDS))
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
        Rect().also { requireNotNull(node).getBoundsInScreen(it) }
}
