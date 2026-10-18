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
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.github.anisharyal09.anice.MainActivity
import io.github.anisharyal09.anice.ui.theme.AniCeTheme
import kotlinx.coroutines.*
import java.io.File
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ClipboardSurfaceTests {
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
                                ClipboardSettings(owner, emptyList(), showHistory = false)
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
                val automaticControl = enclosingCheckbox(automatic)
                val historyControl = enclosingCheckbox(keeping)
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

    private fun enclosingCheckbox(node: AccessibilityNodeInfo?): AccessibilityNodeInfo? {
        // A disabled row can expose its label separately; checkbox semantics belong to its enclosing row.
        var current = node
        while (current != null) { if (current.isCheckable) return current; current = current.parent }
        return null
    }
}
