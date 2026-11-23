// SPDX-License-Identifier: GPL-3.0-or-later
// Checks tile registration and native clipboard layouts using isolated synthetic content.
package io.github.anisharyal09.anice.features.clipboard

import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.service.quicksettings.TileService
import android.content.res.Configuration
import android.graphics.Bitmap
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.view.InputDevice
import android.view.MotionEvent
import android.view.PixelCopy
import android.view.accessibility.AccessibilityNodeInfo
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.github.anisharyal09.anice.MainActivity
import io.github.anisharyal09.anice.ui.theme.AniCeTheme
import io.github.anisharyal09.anice.ui.AniCeSegmentedControl
import kotlinx.coroutines.*
import java.io.File
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.Rule
import io.github.anisharyal09.anice.ui.EmulatorPresentationRule
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ClipboardSurfaceTests {
    @get:Rule val presentation: org.junit.rules.TestRule = EmulatorPresentationRule()

    @Test fun capacityChoicesStayAvailableInGroupedSettingsAndPausedHistory() {
        assumeEmulator()
        val runner = InstrumentationRegistry.getInstrumentation()
        runner.uiAutomation
        val directory = File(runner.targetContext.cacheDir, "clipboard-capacity-${UUID.randomUUID()}")
        val storage = ClipboardHistoryFile(File(directory, "history.json"))
        val rows = (0..2).map { index ->
            ClipboardHistoryEntry(UUID.randomUUID().toString(), "Capacity fixture $index", "phone", index.toLong())
        }
        storage.save(rows, enabled = false, capacity = 20)
        val native = object : NativeClipboard {
            override fun read(): ClipboardSample? = error("Capacity changes must not read the clipboard")
            override fun token(): String? = null
            override fun write(text: String, sensitive: Boolean): Boolean = error("Capacity changes must not write the clipboard")
            override fun observe(enabled: Boolean, changed: () -> Unit) {}
        }
        val owner = runBlocking { withContext(Dispatchers.Main) {
            ClipboardController(native, history = ClipboardHistory(storage)).also {
                withTimeout(5000) { while (it.history.entries.size != 3) delay(1) }
            }
        } }
        val activity = runner.startActivitySync(Intent(runner.targetContext, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) as MainActivity
        try {
            for (dark in listOf(false, true)) {
                for (scale in listOf(0.8f, 1.2f)) {
                    for (grouped in listOf(false, true)) {
                        render(activity, dark, scale) {
                            Column(Modifier.widthIn(max = 300.dp).fillMaxWidth()
                                .verticalScroll(rememberScrollState()).padding(12.dp),
                                verticalArrangement = Arrangement.spacedBy(8.dp)) {
                                if (grouped) ClipboardSettings(owner, emptyList(), grouped = true)
                                else ClipboardHistoryView(owner)
                            }
                        }
                        val picker = awaitAction("History capacity")
                        assertNotNull("Compact Settings and History must both expose capacity", picker)
                        val area = android.graphics.Rect().also(picker::getBoundsInScreen)
                        assertTrue(area.height() >= (48 * activity.resources.displayMetrics.density).toInt())
                        for (value in listOf(50, 100, 20)) {
                            click("History capacity")
                            for (option in listOf(20, 50, 100)) awaitAction("$option items")
                            click("$value items")
                            runBlocking { withContext(Dispatchers.Main) {
                                withTimeout(5000) { while (owner.history.capacity != value) delay(1) }
                                assertFalse("Choosing a count must not enable collection", owner.history.enabled)
                                assertEquals(rows, owner.history.entries)
                            } }
                            assertEquals(value, storage.load()!!.capacity)
                            assertFalse(storage.load()!!.enabled)
                        }
                    }
                }
            }
            assertFalse(owner.busy)
        } finally {
            runner.runOnMainSync { owner.invalidate(); activity.finish() }
            storage.delete(); assertTrue(directory.delete())
        }
    }

    @Test fun themedSegmentsKeepAccessibleTargetsAndIndependentNativeHoverFeedback() {
        assumeEmulator()
        val runner = InstrumentationRegistry.getInstrumentation()
        runner.uiAutomation
        val activity = runner.startActivitySync(Intent(runner.targetContext, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) as MainActivity
        try {
            for (dark in listOf(false, true)) {
                for (scale in listOf(0.8f, 1.2f)) {
                    for (direction in listOf(LayoutDirection.Ltr, LayoutDirection.Rtl)) {
                        val selected = mutableStateOf(false)
                        var changes = 0
                        render(activity, dark, scale) {
                            CompositionLocalProvider(LocalLayoutDirection provides direction) {
                                Column(Modifier.widthIn(max = 300.dp).fillMaxWidth().padding(12.dp)) {
                                    AniCeSegmentedControl(
                                        options = listOf(false to "Share", true to "History"),
                                        selected = selected.value,
                                        onSelected = { selected.value = it; changes++ },
                                        modifier = Modifier.fillMaxWidth(),
                                    )
                                }
                            }
                        }
                        val share = awaitAction("Share")
                        val history = awaitAction("History")
                        assertTrue(share.isSelected); assertFalse(history.isSelected)
                        val area = android.graphics.Rect().also(history::getBoundsInScreen)
                        assertTrue(area.height() >= (48 * activity.resources.displayMetrics.density).toInt())
                        val before = snapshot(activity)
                        val shareArea = android.graphics.Rect().also(share::getBoundsInScreen)
                        val selectedInk = pixel(activity, before, shareArea)
                        val mutedInk = pixel(activity, before, area)
                        assertNotEquals("Selection must retain its own filled, themed face", selectedInk, mutedInk)
                        before.recycle()
                        hover(area, MotionEvent.ACTION_HOVER_ENTER)
                        frames(activity, 12)
                        val hovered = snapshot(activity)
                        assertNotEquals("Native hover must visibly tint the inactive segment",
                            mutedInk, pixel(activity, hovered, area))
                        hovered.recycle()
                        assertEquals(0, changes); assertFalse(selected.value)
                        hover(area, MotionEvent.ACTION_HOVER_EXIT)
                        click("History")
                        assertTrue(selected.value); assertEquals(1, changes)
                        assertTrue(awaitAction("History").isSelected)
                        click("History")
                        assertEquals("Reselecting must not repeat the owner action", 1, changes)
                        click("Share")
                        assertFalse(selected.value); assertEquals(2, changes)
                    }
                }
            }
        } finally {
            runner.runOnMainSync { activity.finish() }
        }
    }

    @Suppress("DEPRECATION") // The flags overload remains available on the minimum API level.
    @Test fun tileIsSystemBoundAndLaunchesOnlyExplicitClipboardMode() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val component = ComponentName(context, ClipboardTileService::class.java)
        val service = context.packageManager.getServiceInfo(component, PackageManager.GET_META_DATA)
        assertTrue(service.exported)
        assertEquals("android.permission.BIND_QUICK_SETTINGS_TILE", service.permission)
        assertTrue(service.metaData.getBoolean(TileService.META_DATA_ACTIVE_TILE))
        val handlers = context.packageManager.queryIntentServices(Intent(TileService.ACTION_QS_TILE).setPackage(context.packageName), 0)
        assertEquals(listOf(component.className), handlers.map { it.serviceInfo.name })
        val launch = SendToMacActivity.clipboardIntent(context)
        assertEquals(ComponentName(context, SendToMacActivity::class.java), launch.component)
        assertEquals("io.github.anisharyal09.anice.action.SEND_CLIPBOARD", launch.action)
        assertTrue(launch.flags and Intent.FLAG_ACTIVITY_NEW_TASK != 0)
        assertNull(launch.extras); assertNull(launch.clipData); assertNull(launch.data)
    }

    @Suppress("DEPRECATION") // Boolean checked-state access remains available on API 29–35.
    @Test fun preferencesAndHistoryRenderInBothThemesWithoutClipboardReads() {
        assumeTrue("Synthetic layouts run only on an isolated emulator", Build.HARDWARE in setOf("ranchu", "goldfish"))
        val runner = InstrumentationRegistry.getInstrumentation()
        val directory = File(runner.targetContext.cacheDir, "clipboard-ui-${UUID.randomUUID()}")
        val storage = ClipboardHistoryFile(File(directory, "history.json"))
        val now = System.currentTimeMillis()
        storage.save(listOf(
            ClipboardHistoryEntry(UUID.randomUUID().toString(), "A project update copied on the phone, with enough text to wrap onto another line.", "phone", now),
            ClipboardHistoryEntry(UUID.randomUUID().toString(), "https://example.com/notes", "mac", now - 60_000),
            ClipboardHistoryEntry(UUID.randomUUID().toString(), "Earlier notes 👋", "phone", now - 86_400_000)))
        var reads = 0
        val native = object : NativeClipboard {
            override fun read(): ClipboardSample? { reads++; return null }
            override fun token(): String? = null
            override fun write(text: String, sensitive: Boolean): Boolean = error("Layout must not write clipboard content")
            override fun observe(enabled: Boolean, changed: () -> Unit) {}
        }
        val owner = runBlocking { withContext(Dispatchers.Main) {
            ClipboardController(native, history = ClipboardHistory(storage)).also {
                withTimeout(5000) { while (!it.history.enabled) delay(1) }
            }
        } }
        val activity = runner.startActivitySync(Intent(runner.targetContext, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) as MainActivity
        try {
            for (dark in listOf(false, true)) {
                val drawn = CountDownLatch(1)
                runner.runOnMainSync { activity.setContent {
                    val configuration = Configuration(LocalConfiguration.current).apply {
                        uiMode = (uiMode and Configuration.UI_MODE_NIGHT_MASK.inv()) or
                            if (dark) Configuration.UI_MODE_NIGHT_YES else Configuration.UI_MODE_NIGHT_NO
                    }
                    CompositionLocalProvider(LocalConfiguration provides configuration) {
                        AniCeTheme { Surface(Modifier.fillMaxSize()) {
                            Column(Modifier.verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                                ClipboardSettings(owner, emptyList(), showHistory = true)
                                HorizontalDivider()
                                ClipboardHistoryView(owner)
                            }
                        } }
                    }
                    SideEffect { activity.window.decorView.postOnAnimation { activity.window.decorView.postOnAnimation { drawn.countDown() } } }
                } }
                assertTrue(drawn.await(10, TimeUnit.SECONDS)); runner.waitForIdleSync()
                runner.uiAutomation.waitForIdle(250, 5000)
                val root = runner.uiAutomation.rootInActiveWindow
                val view = activity.window.decorView
                val bitmap = Bitmap.createBitmap(view.width, view.height, Bitmap.Config.ARGB_8888)
                val copied = CountDownLatch(1); var result = PixelCopy.ERROR_UNKNOWN
                // Capture this window's buffer rather than a possibly stale compositor transition.
                PixelCopy.request(activity.window, bitmap, { result = it; copied.countDown() }, Handler(Looper.getMainLooper()))
                assertTrue(copied.await(10, TimeUnit.SECONDS)); assertEquals(PixelCopy.SUCCESS, result)
                val output = File(runner.targetContext.getExternalFilesDir(null), "clipboard-review/history-${if (dark) "dark" else "light"}.png")
                check(output.parentFile!!.isDirectory || output.parentFile!!.mkdirs())
                output.outputStream().use { assertTrue(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) }; bitmap.recycle()
                val automatic = find(root, "Automatic clipboard sharing")
                val keeping = find(root, "Keep clipboard history")
                assertNotNull("Missing automatic preference; window=${root?.packageName}", automatic)
                val automaticControl = enclosingCheckable(automatic)
                val historyControl = enclosingCheckable(keeping)
                assertNotNull("Automatic preference must expose checkable state", automaticControl)
                assertNotNull("History preference must expose checkable state", historyControl)
                assertFalse(automaticControl!!.isChecked); assertTrue(historyControl!!.isChecked)
                assertNotNull(find(root, "3 of 20")); assertNotNull(find(root, "From Mac")); assertNotNull(find(root, "From phone"))
            }
            assertEquals(0, reads); assertFalse(owner.busy)
        } finally {
            runner.runOnMainSync { owner.invalidate(); activity.finish() }
            storage.delete(); assertTrue(directory.delete())
        }
    }

    private fun find(node: AccessibilityNodeInfo?, text: String): AccessibilityNodeInfo? {
        if (node == null) return null
        if (node.text?.toString()?.contains(text) == true || node.contentDescription?.toString()?.contains(text) == true) return node
        for (i in 0 until node.childCount) { find(node.getChild(i), text)?.let { return it } }
        return null
    }

    private fun enclosingCheckable(node: AccessibilityNodeInfo?): AccessibilityNodeInfo? {
        // A disabled row can expose its label separately; checkable semantics belong to its enclosing row.
        var current = node
        while (current != null) { if (current.isCheckable) return current; current = current.parent }
        return null
    }

    private fun assumeEmulator() {
        assumeTrue("Only isolated emulator clipboard fixtures", Build.HARDWARE in setOf("ranchu", "goldfish"))
        assumeTrue(InstrumentationRegistry.getInstrumentation().targetContext.packageName == "io.github.anisharyal09.anice.preview")
    }

    private fun render(activity: MainActivity, dark: Boolean, scale: Float, content: @Composable () -> Unit) {
        val runner = InstrumentationRegistry.getInstrumentation()
        val drawn = CountDownLatch(1)
        runner.runOnMainSync { activity.setContent {
            val configuration = Configuration(LocalConfiguration.current).apply {
                uiMode = (uiMode and Configuration.UI_MODE_NIGHT_MASK.inv()) or
                    if (dark) Configuration.UI_MODE_NIGHT_YES else Configuration.UI_MODE_NIGHT_NO
            }
            val density = LocalDensity.current.density
            CompositionLocalProvider(LocalConfiguration provides configuration) {
                AniCeTheme {
                    CompositionLocalProvider(LocalDensity provides Density(density, scale)) {
                        Surface(Modifier.fillMaxSize()) {
                            Box(Modifier.fillMaxSize().safeDrawingPadding()) { content() }
                        }
                    }
                }
            }
            SideEffect { activity.window.decorView.postOnAnimation {
                activity.window.decorView.postOnAnimation { drawn.countDown() }
            } }
        } }
        assertTrue(drawn.await(10, TimeUnit.SECONDS))
        runner.waitForIdleSync()
        runner.uiAutomation.waitForIdle(250, 5000)
    }

    private fun root(): AccessibilityNodeInfo? {
        val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
        if (Build.VERSION.SDK_INT >= 34) automation.clearCache()
        return automation.rootInActiveWindow
    }

    private fun action(node: AccessibilityNodeInfo?, label: String): AccessibilityNodeInfo? {
        if (node == null) return null
        if (node.text?.toString()?.contains(label) == true || node.contentDescription?.toString()?.contains(label) == true) {
            var enclosing: AccessibilityNodeInfo? = node
            while (enclosing != null) {
                // Android deliberately omits clickability on an already selected native tab.
                if (enclosing.isClickable || enclosing.isSelected) return enclosing
                enclosing = enclosing.parent
            }
        }
        for (i in 0 until node.childCount) { action(node.getChild(i), label)?.let { return it } }
        return null
    }

    private fun click(label: String) {
        val node = awaitAction(label)
        val runner = InstrumentationRegistry.getInstrumentation()
        if (node.isClickable) {
            assertTrue(node.performAction(AccessibilityNodeInfo.ACTION_CLICK))
        } else {
            val area = android.graphics.Rect().also(node::getBoundsInScreen)
            ParcelFileDescriptor.AutoCloseInputStream(runner.uiAutomation.executeShellCommand(
                "input tap ${area.centerX()} ${area.centerY()}"
            )).use { it.readBytes() }
        }
        runner.waitForIdleSync()
        runner.uiAutomation.waitForIdle(250, 5000)
    }

    private fun awaitAction(label: String): AccessibilityNodeInfo {
        val deadline = SystemClock.uptimeMillis() + 5000
        while (SystemClock.uptimeMillis() < deadline) {
            action(root(), label)?.let { return it }
            SystemClock.sleep(50)
        }
        error("Missing clipboard action: $label; active package=${root()?.packageName}")
    }

    private fun frames(activity: MainActivity, count: Int) {
        val drawn = CountDownLatch(count)
        val view = activity.window.decorView
        view.post(object : Runnable {
            override fun run() {
                drawn.countDown()
                if (drawn.count > 0) view.postOnAnimation(this)
            }
        })
        assertTrue(drawn.await(10, TimeUnit.SECONDS))
    }

    private fun hover(area: android.graphics.Rect, action: Int) {
        val now = SystemClock.uptimeMillis()
        val properties = MotionEvent.PointerProperties().apply { id = 0; toolType = MotionEvent.TOOL_TYPE_MOUSE }
        val coordinates = MotionEvent.PointerCoords().apply { x = area.centerX().toFloat(); y = area.centerY().toFloat() }
        val event = MotionEvent.obtain(now, now, action, 1, arrayOf(properties), arrayOf(coordinates),
            0, 0, 1f, 1f, 0, 0, InputDevice.SOURCE_MOUSE, 0)
        try { assertTrue(InstrumentationRegistry.getInstrumentation().uiAutomation.injectInputEvent(event, true)) }
        finally { event.recycle() }
    }

    private fun snapshot(activity: MainActivity): Bitmap {
        val view = activity.window.decorView
        val bitmap = Bitmap.createBitmap(view.width, view.height, Bitmap.Config.ARGB_8888)
        val copied = CountDownLatch(1)
        var result = PixelCopy.ERROR_UNKNOWN
        PixelCopy.request(activity.window, bitmap, { result = it; copied.countDown() }, Handler(Looper.getMainLooper()))
        assertTrue(copied.await(10, TimeUnit.SECONDS)); assertEquals(PixelCopy.SUCCESS, result)
        return bitmap
    }

    private fun pixel(activity: MainActivity, bitmap: Bitmap, area: android.graphics.Rect): Int {
        val origin = IntArray(2).also(activity.window.decorView::getLocationOnScreen)
        val inset = (6 * activity.resources.displayMetrics.density).toInt()
        return bitmap.getPixel(area.left - origin[0] + inset, area.centerY() - origin[1])
    }
}
