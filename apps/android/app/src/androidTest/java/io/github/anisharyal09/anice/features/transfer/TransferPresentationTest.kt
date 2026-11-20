// SPDX-License-Identifier: GPL-3.0-or-later
// Reviews transfer controls in disposable native fixtures without trust, radio or file operations.
package io.github.anisharyal09.anice.features.transfer

import android.content.Intent
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.Rect
import android.app.KeyguardManager
import android.os.Build
import android.view.accessibility.AccessibilityNodeInfo
import android.view.WindowManager
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.github.anisharyal09.anice.MainActivity
import io.github.anisharyal09.anice.AniCeApplication
import io.github.anisharyal09.anice.features.clipboard.ClipboardSettings
import io.github.anisharyal09.anice.features.notifications.NotificationSettings
import io.github.anisharyal09.anice.ui.theme.AniCeTheme
import io.github.anisharyal09.anice.update.UpdateSettingsContent
import io.github.anisharyal09.anice.update.UpdateStatus
import kotlinx.coroutines.cancel
import java.io.File
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class TransferPresentationTest {
    private data class Layout(val dark: Boolean, val scale: Float, val width: Int)
    private val layouts = listOf(
        Layout(false, 0.8f, 280), Layout(true, 1.2f, 280),
        Layout(false, 1.2f, 600), Layout(true, 0.8f, 600),
    )

    @Test fun transferStatesKeepOneOverviewHeadingAndAccessibleActions() {
        requireDisposableReview()
        val runner = InstrumentationRegistry.getInstrumentation()
        val file = TransferFile(UUID.randomUUID().toString(), "Review image.png", 1_048_576, ByteArray(32))
        val batch = TransferBatch(UUID.randomUUID().toString(), listOf(file), file.size, "Fixture Mac")
        val states = listOf(
            TransferState.Idle, TransferState.Connecting(batch.peerName),
            TransferState.WaitingForPeerApproval(batch), TransferState.IncomingOffer(batch),
            TransferState.Transferring(batch, 1, file.name, 524_288, file.size, 524_288, 65_536.0),
            TransferState.Paused(batch, 1, file.name, 524_288, file.size, 524_288, "Connection lost", true),
            TransferState.Completed(batch.id, 1, file.size), TransferState.Rejected(batch.id, 0),
            TransferState.Failed("Connection unavailable"), TransferState.Cancelled,
        )
        for (layout in layouts) {
            val activity = startActivity()
            val owner = TransferController()
            val revision = mutableIntStateOf(0)
            try {
                runner.runOnMainSync {
                    owner.peerConnected = true
                    owner.peerCompatible = true
                    activity.setContent {
                        fixture(layout) {
                            key(revision.intValue) { TransferView(owner, open = {}, overview = true) }
                        }
                    }
                }
                for ((index, state) in states.withIndex()) {
                    val directions = if (state is TransferState.Transferring || state is TransferState.Paused ||
                        state is TransferState.Completed) listOf(false, true) else listOf(false)
                    for (receiving in directions) {
                        runner.runOnMainSync {
                            owner.state = state
                            owner.receiving = receiving
                            revision.intValue++
                        }
                        idle()
                        val actions = when (state) {
                            TransferState.Idle -> listOf("Send files…")
                            is TransferState.Connecting, is TransferState.WaitingForPeerApproval,
                            is TransferState.Transferring -> listOf("Cancel")
                            is TransferState.IncomingOffer -> listOf("Accept", "Decline")
                            is TransferState.Paused -> listOf("Continue over Bluetooth", "Cancel transfer")
                            is TransferState.Completed -> listOf("Send files…", "Done")
                            else -> listOf("Send files…", "Dismiss")
                        }
                        val tree = awaitLabels(listOf("File transfer") + actions)
                        assertEquals("Overview has one File transfer heading", 1, labels(tree, "File transfer").size)
                        assertTrue(labels(tree, "Automatically receive files").isEmpty())
                        assertTrue(labels(tree, "Save received files to").isEmpty())
                        assertTrue(labels(tree, "Show transfer notifications").isEmpty())
                        val viewport = bounds(tree)
                        val density = minOf(activity.resources.displayMetrics.density,
                            activity.resources.displayMetrics.widthPixels / layout.width.toFloat())
                        val actionBounds = actions.map { label ->
                            val action = clickable(labels(tree, label).singleOrNull())
                            assertNotNull("Missing $label in $state", action)
                            bounds(action).also {
                                assertTrue("$label retains its 48 dp interaction area", it.height() >= (48 * density).toInt() - 1)
                                assertTrue("$label fits the viewport", viewport.contains(it))
                            }
                        }
                        actionBounds.zipWithNext().forEach { (first, second) ->
                            assertFalse("Action targets must not overlap", Rect.intersects(first, second))
                        }
                        capture("${layout.width}-${layout.scale}-${layout.dark}-$index-$receiving")
                    }
                }
            } finally {
                runner.runOnMainSync { owner.scope.cancel(); activity.finish() }
                runner.waitForIdleSync()
            }
        }
    }

    @Test fun sharedActionMatchesHomeSizeAndFiresOnlyOnce() {
        requireDisposableReview()
        val runner = InstrumentationRegistry.getInstrumentation()
        for (layout in layouts) {
            val activity = startActivity()
            val events = AtomicInteger()
            val drawn = CountDownLatch(1)
            try {
                runner.runOnMainSync {
                    activity.setContent {
                        fixture(layout) {
                            OutlinedButton(onClick = {}, shape = MaterialTheme.shapes.small,
                                colors = ButtonDefaults.outlinedButtonColors(containerColor = MaterialTheme.colorScheme.surfaceVariant),
                                contentPadding = PaddingValues(horizontal = 10.dp, vertical = 2.dp),
                                modifier = Modifier.defaultMinSize(minHeight = 32.dp)) { Text("Home action") }
                            TransferActionButton(onClick = { events.incrementAndGet() }) { Text("Transfer action") }
                        }
                        SideEffect { activity.window.decorView.postOnAnimation { drawn.countDown() } }
                    }
                }
                assertTrue(drawn.await(10, TimeUnit.SECONDS))
                idle()
                val tree = awaitLabels(listOf("Home action", "Transfer action"))
                val reference = clickable(labels(tree, "Home action").singleOrNull())
                val transfer = clickable(labels(tree, "Transfer action").singleOrNull())
                assertNotNull(reference)
                assertNotNull(transfer)
                assertEquals("Shared transfer sizing matches Home", bounds(reference).height(), bounds(transfer).height())
                assertTrue(transfer!!.performAction(AccessibilityNodeInfo.ACTION_CLICK))
                idle()
                assertEquals(1, events.get())
            } finally {
                runner.runOnMainSync { activity.finish() }
                runner.waitForIdleSync()
            }
        }
    }

    @Test fun groupedSettingsKeepCompactHelpersAndPermissionActions() {
        requireDisposableReview()
        val runner = InstrumentationRegistry.getInstrumentation()
        for (layout in layouts) {
            val activity = startActivity()
            val app = activity.application as AniCeApplication
            try {
                runner.runOnMainSync {
                    activity.setContent {
                        fixture(layout) {
                            Column(Modifier.verticalScroll(rememberScrollState()),
                                verticalArrangement = Arrangement.spacedBy(12.dp)) {
                                Text("Updates")
                                Surface(shape = MaterialTheme.shapes.small, color = MaterialTheme.colorScheme.surfaceContainer) {
                                    Column(Modifier.padding(horizontal = 12.dp, vertical = 4.dp)) {
                                        UpdateSettingsContent(false, true, UpdateStatus.Idle, null, {}, {}, {})
                                    }
                                }
                                Text("Clipboard")
                                Surface(shape = MaterialTheme.shapes.small, color = MaterialTheme.colorScheme.surfaceContainer) {
                                    Column(Modifier.padding(horizontal = 12.dp, vertical = 4.dp)) {
                                        ClipboardSettings(app.clipboard, emptyList(), grouped = true)
                                    }
                                }
                                Text("Notification sync")
                                Surface(shape = MaterialTheme.shapes.small, color = MaterialTheme.colorScheme.surfaceContainer) {
                                    Column(Modifier.padding(horizontal = 12.dp, vertical = 4.dp)) {
                                        NotificationSettings(app.notificationMirror)
                                    }
                                }
                            }
                        }
                    }
                }
                idle()
                val tree = awaitLabels(listOf("Saved on this phone. Pausing keeps saved clips.",
                    "Check for updates", "Enable notification access"))
                assertEquals(1, labels(tree, "Saved on this phone. Pausing keeps saved clips.").size)
                for (label in listOf("Check for updates", "Enable notification access")) {
                    val action = clickable(labels(tree, label).singleOrNull())
                    assertNotNull("Missing $label", action)
                    val density = minOf(activity.resources.displayMetrics.density,
                        activity.resources.displayMetrics.widthPixels / layout.width.toFloat())
                    assertTrue("$label retains 48 dp", bounds(action).height() >= (48 * density).toInt() - 1)
                }
                capture("settings-${layout.width}-${layout.scale}-${layout.dark}")
            } finally {
                runner.runOnMainSync { activity.finish() }
                runner.waitForIdleSync()
            }
        }
    }

    @Composable private fun fixture(layout: Layout, content: @Composable ColumnScope.() -> Unit) {
        val configuration = Configuration(LocalConfiguration.current).apply {
            uiMode = (uiMode and Configuration.UI_MODE_NIGHT_MASK.inv()) or
                if (layout.dark) Configuration.UI_MODE_NIGHT_YES else Configuration.UI_MODE_NIGHT_NO
        }
        val nativeDensity = LocalDensity.current
        // Expanded logical widths stay within this physical display; no device setting is changed.
        val density = minOf(nativeDensity.density,
            InstrumentationRegistry.getInstrumentation().targetContext.resources.displayMetrics.widthPixels / layout.width.toFloat())
        CompositionLocalProvider(LocalConfiguration provides configuration) {
            AniCeTheme {
                CompositionLocalProvider(LocalDensity provides Density(density, layout.scale)) {
                    Surface(Modifier.fillMaxSize()) {
                        Box(Modifier.fillMaxSize()) {
                            Column(Modifier.widthIn(max = layout.width.dp).fillMaxWidth().safeDrawingPadding().padding(12.dp),
                                verticalArrangement = Arrangement.spacedBy(8.dp), content = content)
                        }
                    }
                }
            }
        }
    }

    private fun requireDisposableReview() {
        val runner = InstrumentationRegistry.getInstrumentation()
        assumeTrue("UI fixtures never replace a paired or normal installation", runner.targetContext.packageName in setOf(
            "io.github.anisharyal09.anice.preview", "io.github.anisharyal09.anice.preview.transfer.ui.regression"))
        assumeTrue("Physical UI review needs explicit opt-in", Build.HARDWARE in setOf("ranchu", "goldfish") ||
            InstrumentationRegistry.getArguments().getString("allowPhysicalUiReview") == "true")
        check(!runner.targetContext.getSystemService(KeyguardManager::class.java).isKeyguardLocked) {
            "Unlock the phone before native UI review; the fixture does not bypass the lock screen."
        }
    }

    private fun startActivity(): MainActivity {
        val runner = InstrumentationRegistry.getInstrumentation()
        runner.uiAutomation
        val activity = runner.startActivitySync(Intent(runner.targetContext, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) as MainActivity
        runner.runOnMainSync { activity.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON) }
        return activity
    }

    private fun idle() {
        val runner = InstrumentationRegistry.getInstrumentation()
        runner.waitForIdleSync()
        runner.uiAutomation.waitForIdle(250, 5000)
    }

    private fun root(): AccessibilityNodeInfo? {
        val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
        if (Build.VERSION.SDK_INT >= 34) automation.clearCache()
        return automation.rootInActiveWindow
    }

    private fun awaitLabels(required: List<String>): AccessibilityNodeInfo? {
        val deadline = android.os.SystemClock.uptimeMillis() + 5000
        do {
            val tree = root()
            if (required.all { labels(tree, it).isNotEmpty() }) return tree
            Thread.sleep(50)
        } while (android.os.SystemClock.uptimeMillis() < deadline)
        capture("missing-fixture")
        error("Missing $required in ${root()?.packageName}:\n${describe(root())}")
    }

    private fun describe(node: AccessibilityNodeInfo?, depth: Int = 0): String {
        if (node == null || depth > 24) return ""
        return "  ".repeat(depth) + "${node.className} text=${node.text} description=${node.contentDescription}\n" +
            (0 until node.childCount).joinToString("") { describe(node.getChild(it), depth + 1) }
    }

    private fun labels(node: AccessibilityNodeInfo?, label: String): List<AccessibilityNodeInfo> {
        if (node == null) return emptyList()
        return (if (node.text?.toString() == label || node.contentDescription?.toString() == label) listOf(node) else emptyList()) +
            (0 until node.childCount).flatMap { labels(node.getChild(it), label) }
    }

    private fun clickable(node: AccessibilityNodeInfo?): AccessibilityNodeInfo? {
        var current = node
        while (current != null) {
            if (current.isClickable) return current
            current = current.parent
        }
        return null
    }

    private fun bounds(node: AccessibilityNodeInfo?): Rect {
        assertNotNull(node)
        return Rect().also { node!!.getBoundsInScreen(it) }
    }

    private fun capture(name: String) {
        val runner = InstrumentationRegistry.getInstrumentation()
        val bitmap = runner.uiAutomation.takeScreenshot()
        assertNotNull(bitmap)
        val file = File(runner.targetContext.getExternalFilesDir(null), "transfer-review/$name.png")
        check(file.parentFile!!.isDirectory || file.parentFile!!.mkdirs())
        file.outputStream().use { assertTrue(bitmap!!.compress(Bitmap.CompressFormat.PNG, 100, it)) }
        bitmap!!.recycle()
    }
}
