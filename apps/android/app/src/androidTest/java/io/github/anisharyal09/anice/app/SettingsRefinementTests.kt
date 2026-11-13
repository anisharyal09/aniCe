// SPDX-License-Identifier: GPL-3.0-or-later
// Checks beta consent and About layout on isolated emulators without submitting reports or changing live connections.
package io.github.anisharyal09.anice.app

import android.content.Intent
import android.content.res.Configuration
import android.graphics.Rect
import android.os.Build
import android.os.ParcelFileDescriptor
import android.view.accessibility.AccessibilityNodeInfo
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.platform.UriHandler
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.github.anisharyal09.anice.MainActivity
import io.github.anisharyal09.anice.ui.theme.AniCeTheme
import io.github.anisharyal09.anice.update.BetaUpdatePreference
import io.github.anisharyal09.anice.update.UpdateSettingsContent
import io.github.anisharyal09.anice.update.UpdateStatus
import java.io.File
import java.net.URI
import java.net.URLDecoder
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SettingsRefinementTests {
    @Suppress("DEPRECATION")
    @Test fun betaOptInRequiresConfirmationAndCancelOrBackPreservesTheSetting() {
        assumeEmulator()
        val runner = InstrumentationRegistry.getInstrumentation()
        runner.uiAutomation
        for (dark in listOf(false, true)) {
            val activity = runner.startActivitySync(
                Intent(runner.targetContext, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            ) as MainActivity
            val beta = mutableStateOf(false)
            val enables = AtomicInteger()
            val disables = AtomicInteger()
            try {
                val drawn = CountDownLatch(1)
                runner.runOnMainSync {
                    activity.setContent {
                        fixture(dark, 1f) {
                            Column(Modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                                Text("Updates", style = MaterialTheme.typography.titleMedium)
                                BetaUpdatePreference(beta.value) {
                                    beta.value = it
                                    if (it) enables.incrementAndGet() else disables.incrementAndGet()
                                }
                            }
                        }
                        SideEffect { activity.window.decorView.postOnAnimation { drawn.countDown() } }
                    }
                }
                assertTrue(drawn.await(10, TimeUnit.SECONDS))
                idle()
                awaitLabel("Get early builds and help test aniCe.")
                click("Include beta releases")
                awaitLabel("Try beta updates?")
                assertFalse(beta.value)
                assertEquals(0, enables.get())
                capture("beta-confirm-${if (dark) "dark" else "light"}")
                click("Not now")
                awaitNoLabel("Try beta updates?")
                awaitLabel("Get early builds and help test aniCe.")
                assertEquals(0, enables.get())
                click("Include beta releases")
                awaitLabel("Try beta updates?")
                pressBack()
                awaitNoLabel("Try beta updates?")
                assertFalse(beta.value)
                assertEquals(0, enables.get())
                click("Include beta releases")
                awaitLabel("Try beta updates?")
                click("Enable beta updates")
                awaitNoLabel("Try beta updates?")
                assertTrue(beta.value)
                awaitLabel("Turning this off keeps your installed version.")
                assertEquals(1, enables.get())
                click("Include beta releases")
                assertFalse(beta.value)
                awaitLabel("Get early builds and help test aniCe.")
                assertEquals(1, disables.get())
                awaitNoLabel("Try beta updates?")
            } finally {
                runner.runOnMainSync { activity.finish() }
                runner.waitForIdleSync()
            }
        }
    }

    @Test fun updateChecksShowAvailableAndBusyStatesWithoutLosingAccessibleActions() {
        assumeEmulator()
        val runner = InstrumentationRegistry.getInstrumentation()
        runner.uiAutomation
        val states = listOf(
            Triple<UpdateStatus, String, Boolean>(UpdateStatus.Idle, "Update v0.9.0-beta.2 is available.", true),
            Triple(UpdateStatus.UpToDate, "You’re up to date.", true),
            Triple(UpdateStatus.Failed("Could not check for updates. Try again when your connection is available."),
                "Could not check for updates.", true),
            Triple(UpdateStatus.Checking, "Checking…", false),
            Triple(UpdateStatus.Downloading(1, 10), "Downloading update…", false),
            Triple(UpdateStatus.PermissionRequired, "Allow installation in Android Settings.", false),
            Triple(UpdateStatus.Installing, "Preparing the Android installer…", false),
            Triple(UpdateStatus.AwaitingConfirmation(Intent()), "Android needs your installation confirmation.", false),
        )
        assertEquals(8, states.size)
        for (dark in listOf(false, true)) {
            for (scale in listOf(0.8f, 1f, 1.2f, 2f)) {
                val cases = if (scale == 1f) states else listOf(states[0], states[2])
                for ((index, case) in cases.withIndex()) {
                    val (status, summary, checkAllowed) = case
                    val narrow = scale != 1f
                    val activity = runner.startActivitySync(
                        Intent(runner.targetContext, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    ) as MainActivity
                    val checks = AtomicInteger()
                    try {
                        val drawn = CountDownLatch(1)
                        runner.runOnMainSync {
                            activity.setContent {
                                fixture(dark, scale) {
                                    Column(Modifier.widthIn(max = if (narrow) 300.dp else 360.dp).fillMaxWidth().padding(12.dp)) {
                                        Text("Updates", style = MaterialTheme.typography.titleMedium)
                                        UpdateSettingsContent(false, status, "v0.9.0-beta.2", {}, { checks.incrementAndGet() })
                                    }
                                }
                                SideEffect { activity.window.decorView.postOnAnimation { drawn.countDown() } }
                            }
                        }
                        assertTrue(drawn.await(10, TimeUnit.SECONDS))
                        idle()
                        awaitLabel(summary)
                        val actionLabel = if (status == UpdateStatus.Checking) "Checking…" else "Check for updates"
                        val action = clickable(find(root(), actionLabel))
                        assertNotNull(action)
                        assertEquals(checkAllowed, action!!.isEnabled)
                        val actionBounds = bounds(action)
                        assertTrue("Update check keeps a 48 dp touch target",
                            actionBounds.height() >= (48 * activity.resources.displayMetrics.density).toInt())
                        if (status != UpdateStatus.Checking) {
                            val statusBounds = bounds(find(root(), summary))
                            if (narrow) {
                                assertTrue("Narrow or large-text layouts get status above the trailing action",
                                    statusBounds.bottom <= actionBounds.top)
                                assertTrue(statusBounds.width() >= (240 * activity.resources.displayMetrics.density).toInt())
                            } else {
                                assertTrue("Status and check action must not overlap", statusBounds.right <= actionBounds.left)
                            }
                            val viewport = bounds(root())
                            assertTrue("The full update status remains onscreen", statusBounds.bottom <= viewport.bottom)
                            assertTrue("The update action remains onscreen", actionBounds.bottom <= viewport.bottom)
                        }
                        if (checkAllowed) {
                            click(actionLabel)
                            assertEquals(1, checks.get())
                        } else {
                            assertEquals(0, checks.get())
                        }
                        capture("updates-${if (dark) "dark" else "light"}-${(scale * 100).toInt()}-$index")
                    } finally {
                        runner.runOnMainSync { activity.finish() }
                        runner.waitForIdleSync()
                    }
                }
            }
        }
    }

    @Test fun aboutContactReflowsAndReportLinkContainsOnlyVersionInformation() {
        assumeEmulator()
        val runner = InstrumentationRegistry.getInstrumentation()
        runner.uiAutomation
        val cases = listOf(0.8f, 1f, 1.2f, 2f).flatMap { scale ->
            listOf(300.dp, 360.dp).map { width -> scale to width }
        }
        assertEquals(8, cases.size)
        for (dark in listOf(false, true)) {
            for ((scale, width) in cases) {
                val activity = runner.startActivitySync(
                    Intent(runner.targetContext, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                ) as MainActivity
                val opened = mutableListOf<String>()
                try {
                    val drawn = CountDownLatch(1)
                    runner.runOnMainSync {
                        activity.setContent {
                            fixture(dark, scale) {
                                CompositionLocalProvider(LocalUriHandler provides object : UriHandler {
                                    override fun openUri(uri: String) { opened.add(uri) }
                                }) {
                                    Box(Modifier.widthIn(max = width).fillMaxWidth()) { AboutScreen(activity) }
                                }
                            }
                            SideEffect { activity.window.decorView.postOnAnimation { drawn.countDown() } }
                        }
                    }
                    assertTrue(drawn.await(10, TimeUnit.SECONDS))
                    idle()
                    assertNotNull(find(root(), "Reach out"))
                    assertNull(find(root(), "Developer"))
                    val contact = bounds(find(root(), "Reach out"))
                    val profile = bounds(clickable(find(root(), "@anisharyal09")))
                    val x = bounds(clickable(find(root(), "X profile")))
                    val linkedIn = bounds(clickable(find(root(), "LinkedIn profile")))
                    val row = bounds(clickable(find(root(), "Report an issue")))
                    if (scale <= 1.2f) {
                        assertEquals("Contact name and socials must share one row when they fit",
                            profile.centerY().toFloat(), x.centerY().toFloat(), 3 * activity.resources.displayMetrics.density)
                        assertEquals(x.centerY(), linkedIn.centerY())
                    } else {
                        assertEquals("Wrapped social links must stay together on the right",
                            x.centerY(), linkedIn.centerY())
                        assertTrue(linkedIn.right >= contact.right - (4 * activity.resources.displayMetrics.density).toInt())
                    }
                    assertEquals("Contact name and social actions stay together",
                        profile.centerY().toFloat(), x.centerY().toFloat(), 3 * activity.resources.displayMetrics.density)
                    assertTrue("Links follow the name", x.left > profile.left)
                    assertTrue("Profile and social touch targets must not overlap", profile.right <= x.left)
                    assertEquals("The contact group stays at the trailing edge",
                        row.right.toFloat(), linkedIn.right.toFloat(), 4 * activity.resources.displayMetrics.density)
                    assertEquals("The contact label stays at the leading edge",
                        row.left.toFloat(), contact.left.toFloat(), 4 * activity.resources.displayMetrics.density)
                    assertTrue(x.height() >= (48 * activity.resources.displayMetrics.density).toInt())
                    assertTrue(linkedIn.height() >= (48 * activity.resources.displayMetrics.density).toInt())
                    assertTrue(x.width() >= (48 * activity.resources.displayMetrics.density).toInt())
                    assertTrue(linkedIn.width() >= (48 * activity.resources.displayMetrics.density).toInt())
                    capture("about-${if (dark) "dark" else "light"}-${(scale * 100).toInt()}-${width.value.toInt()}")
                    click("Report an issue")
                    assertEquals(1, opened.size)
                    val url = URI(opened.single())
                    assertEquals("github.com", url.host)
                    assertEquals("/anisharyal09/aniCe/issues/new", url.path)
                    val fields = url.rawQuery.split("&").associate {
                        val pair = it.split("=", limit = 2)
                        pair[0] to URLDecoder.decode(pair[1], "UTF-8")
                    }
                    assertEquals(setOf("template", "app-version", "os-version"), fields.keys)
                    assertEquals("bug_report.yml", fields["template"])
                    assertFalse(fields["app-version"].isNullOrBlank())
                    assertTrue(fields["os-version"]!!.startsWith("Android "))
                } finally {
                    runner.runOnMainSync { activity.finish() }
                    runner.waitForIdleSync()
                }
            }
        }
    }

    @Composable private fun fixture(dark: Boolean, scale: Float, content: @Composable () -> Unit) {
        val configuration = Configuration(LocalConfiguration.current).apply {
            uiMode = (uiMode and Configuration.UI_MODE_NIGHT_MASK.inv()) or
                if (dark) Configuration.UI_MODE_NIGHT_YES else Configuration.UI_MODE_NIGHT_NO
        }
        val density = LocalDensity.current
        CompositionLocalProvider(LocalConfiguration provides configuration) {
            AniCeTheme {
                CompositionLocalProvider(LocalDensity provides Density(density.density, scale)) {
                    Surface(Modifier.fillMaxSize()) {
                        Box(Modifier.fillMaxSize().safeDrawingPadding()) { content() }
                    }
                }
            }
        }
    }

    private fun assumeEmulator() {
        assumeTrue("Settings fixtures run only on an isolated emulator", Build.HARDWARE in setOf("ranchu", "goldfish"))
        assumeTrue("Settings fixtures never use the normal aniCe package",
            InstrumentationRegistry.getInstrumentation().targetContext.packageName == "io.github.anisharyal09.anice.preview")
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
    private fun find(node: AccessibilityNodeInfo?, label: String): AccessibilityNodeInfo? {
        if (node == null) return null
        if (node.text?.toString()?.contains(label) == true || node.contentDescription?.toString()?.contains(label) == true) return node
        for (i in 0 until node.childCount) { find(node.getChild(i), label)?.let { return it } }
        return null
    }
    private fun clickable(node: AccessibilityNodeInfo?): AccessibilityNodeInfo? {
        var current = node
        while (current != null) {
            if (current.isClickable) return current
            current = current.parent
        }
        return null
    }
    private fun click(label: String) {
        val action = clickable(find(root(), label))
        assertNotNull("Missing action: $label", action)
        assertTrue(action!!.performAction(AccessibilityNodeInfo.ACTION_CLICK))
        idle()
    }
    private fun pressBack() {
        val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
        ParcelFileDescriptor.AutoCloseInputStream(automation.executeShellCommand("input keyevent KEYCODE_BACK"))
            .use { it.readBytes() }
        idle()
    }
    private fun awaitLabel(label: String, timeoutMillis: Long = 5_000) {
        val deadline = System.nanoTime() + timeoutMillis * 1_000_000
        while (System.nanoTime() < deadline) {
            if (find(root(), label) != null) return
            Thread.sleep(50)
        }
        fail("Timed out waiting for \"$label\"")
    }
    private fun awaitNoLabel(label: String, timeoutMillis: Long = 5_000) {
        val deadline = System.nanoTime() + timeoutMillis * 1_000_000
        while (System.nanoTime() < deadline) {
            if (find(root(), label) == null) return
            Thread.sleep(50)
        }
        fail("Timed out waiting for \"$label\" to disappear")
    }
    private fun bounds(node: AccessibilityNodeInfo?): Rect {
        assertNotNull(node)
        return Rect().also { node!!.getBoundsInScreen(it) }
    }
    private fun capture(name: String) {
        val runner = InstrumentationRegistry.getInstrumentation()
        val bitmap = runner.uiAutomation.takeScreenshot()
        assertNotNull(bitmap)
        val file = File(runner.targetContext.getExternalFilesDir(null), "settings-review/$name.png")
        check(file.parentFile!!.isDirectory || file.parentFile!!.mkdirs())
        file.outputStream().use { assertTrue(bitmap!!.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it)) }
        bitmap!!.recycle()
    }
}
