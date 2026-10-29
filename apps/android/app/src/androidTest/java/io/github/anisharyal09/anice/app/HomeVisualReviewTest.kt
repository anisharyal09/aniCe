// SPDX-License-Identifier: GPL-3.0-or-later
// Exercises native home layout and accessibility fixtures through an opt-in visual review.
package io.github.anisharyal09.anice.app

import io.github.anisharyal09.anice.infrastructure.connections.ConnectionState
import android.content.Intent
import android.content.res.Configuration
import android.graphics.Bitmap
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.PixelCopy
import android.view.accessibility.AccessibilityNodeInfo
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.github.anisharyal09.anice.MainActivity
import io.github.anisharyal09.anice.R
import io.github.anisharyal09.anice.features.session.DeviceSessionCard
import io.github.anisharyal09.anice.ui.theme.AniCeTheme
import java.util.concurrent.atomic.AtomicInteger
import android.graphics.Rect
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

/** Isolated presentation fixtures: no trust writes, radio operations, or live connection claims. */
@RunWith(AndroidJUnit4::class)
class HomeVisualReviewTest {
    @OptIn(ExperimentalMaterial3Api::class)
    @Test
    fun nativePresentationStates() {
        assumeTrue(
            "Presentation fixtures run only on an isolated emulator",
            Build.HARDWARE in setOf("ranchu", "goldfish"),
        )
        val runner = InstrumentationRegistry.getInstrumentation()
        runner.uiAutomation
        val cases =
            listOf(
                Review("secured-dark", true, ConnectionState.SECURED, ""),
                Review("secured-light", false, ConnectionState.SECURED, ""),
                Review("compact-home", false, ConnectionState.SECURED, "", compact = true),
                Review(
                    "disconnected",
                    false,
                    ConnectionState.DISCONNECTED,
                    "Open Allow connections on your Mac, then connect here.",
                ),
                Review("connecting", true, ConnectionState.CONNECTING, "Finding your trusted Mac…"),
                Review("failed", true, ConnectionState.FAILED, "Turn on Bluetooth, then retry."),
                Review(
                    "permission",
                    false,
                    ConnectionState.FAILED,
                    "Bluetooth access is needed. Allow it in app settings, then retry.",
                ),
                Review("empty", false, null, ""),
                Review("high-activity", true, ConnectionState.SECURED, "", highActivity = true, compact = true),
                Review(
                    "large-text-long-name",
                    true,
                    ConnectionState.FAILED,
                    "Allow Bluetooth access in app settings, then retry.",
                    fontScale = 2f,
                    name = "Alexandra’s MacBook Pro for work and travel",
                ),
                Review(
                    "expanded",
                    false,
                    ConnectionState.SECURED,
                    "Connection check received.",
                    width = 640,
                ),
            )
        assertTrue(cases.size >= 11)
        for (case in cases) {
            val activity =
                runner.startActivitySync(
                    Intent(runner.targetContext, MainActivity::class.java)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                ) as MainActivity
            try {
                val drawn = CountDownLatch(1)
                val disconnects = AtomicInteger()
                val details = AtomicInteger()
                val reviews = AtomicInteger()
                runner.runOnMainSync {
                    activity.setContent {
                        val configuration =
                            Configuration(LocalConfiguration.current).apply {
                                uiMode =
                                    (uiMode and Configuration.UI_MODE_NIGHT_MASK.inv()) or
                                        if (case.dark) Configuration.UI_MODE_NIGHT_YES
                                        else Configuration.UI_MODE_NIGHT_NO
                            }
                        val density = LocalDensity.current
                        CompositionLocalProvider(
                            LocalConfiguration provides configuration,
                            LocalDensity provides Density(density.density, case.fontScale),
                        ) {
                            key(case.id) {
                                AniCeTheme {
                                    Scaffold(
                                        topBar = {
                                            TopAppBar(
                                                title = { Text("aniCe", style = MaterialTheme.typography.titleSmall) },
                                                expandedHeight = maxOf(48.dp, (24 * LocalDensity.current.fontScale + 16).dp),
                                                actions = {
                                                    IconButton(onClick = {}) {
                                                        Icon(painterResource(R.drawable.ic_about), contentDescription = "About aniCe", modifier = Modifier.size(18.dp))
                                                    }
                                                },
                                                colors =
                                                    TopAppBarDefaults.topAppBarColors(
                                                        containerColor =
                                                            MaterialTheme.colorScheme.background
                                                    ),
                                            )
                                        }
                                    ) { padding ->
                                        Box(
                                            Modifier.fillMaxSize().padding(padding),
                                            contentAlignment = Alignment.TopCenter,
                                        ) {
                                            HomeScreen(
                                                hasTrustedDevices = case.state != null,
                                                onPair = {},
                                                showRecentHeading = case.highActivity,
                                                modifier = Modifier.widthIn(max = case.width.dp),
                                                attention = {
                                                    if (case.highActivity) PendingRequestRow("Incoming files", "3 files from Fixture Mac") { reviews.incrementAndGet() }
                                                },
                                                activities = {
                                                    if (case.highActivity) {
                                                        Text("Now playing", style = MaterialTheme.typography.titleSmall)
                                                        Text("Sending files · 42%", style = MaterialTheme.typography.bodyMedium)
                                                    }
                                                },
                                                recentActivity = {
                                                    if (case.highActivity) Text("Recent clipboard activity", style = MaterialTheme.typography.bodySmall)
                                                },
                                                sessions = {
                                                    case.state?.let {
                                                        DeviceSessionCard(
                                                            case.name,
                                                            it,
                                                            case.status,
                                                            true,
                                                            {},
                                                            { disconnects.incrementAndGet() },
                                                            { details.incrementAndGet() },
                                                            compact = case.compact,
                                                        )
                                                    }
                                                },
                                            )
                                        }
                                    }
                                }
                            }
                        }
                        SideEffect {
                            activity.window.decorView.postOnAnimation {
                                activity.window.decorView.postOnAnimation { drawn.countDown() }
                            }
                        }
                    }
                }
                assertTrue("Fixture did not draw: ${case.id}", drawn.await(10, TimeUnit.SECONDS))
                runner.waitForIdleSync()
                runner.uiAutomation.waitForIdle(250, 5000)
                val root = runner.uiAutomation.rootInActiveWindow
                assertNotNull("Missing native accessibility tree: ${case.id}", root)
                val expected = if (case.state == null) "No devices paired yet" else case.name
                assertTrue("Missing device context: ${case.id}", findText(root, expected) != null)
                assertEquals("Recent heading must match available activity", case.highActivity, findText(root, "Recent") != null)
                capture(activity, case.id)
                if (case.highActivity) {
                    val request = clickableAncestor(findText(root, "Incoming files"))
                    assertNotNull("Pending request row must be actionable", request)
                    assertTrue(request!!.performAction(AccessibilityNodeInfo.ACTION_CLICK))
                    runner.waitForIdleSync()
                    assertEquals("A request row must open exactly once", 1, reviews.get())
                    assertEquals(0, disconnects.get())
                    assertEquals(0, details.get())
                    val requestBounds = Rect()
                    val currentBounds = Rect()
                    val recentBounds = Rect()
                    request.getBoundsInScreen(requestBounds)
                    findText(root, "Now playing")!!.getBoundsInScreen(currentBounds)
                    findText(root, "Recent clipboard activity")!!.getBoundsInScreen(recentBounds)
                    assertTrue("Incoming decisions must precede current work", requestBounds.bottom <= currentBounds.top)
                    assertTrue("Recent activity must follow current work", currentBounds.bottom <= recentBounds.top)
                }

                if (case.state == ConnectionState.SECURED) {
                    assertTrue(findText(root, "Connected") != null || findText(root, "Secured") != null)
                    val tools = if (case.compact) clickableAncestor(findText(root, case.name))
                        else findText(root, "Connection details") ?: findText(root, "More")
                    assertNotNull("Missing accessible More action", tools)
                    val action = clickableAncestor(findText(root, "Disconnect"))
                    assertNotNull("Missing independent Disconnect action", action)
                    val bounds = Rect()
                    action!!.getBoundsInScreen(bounds)
                    assertTrue("Disconnect target must remain at least 48 dp",
                        bounds.height() >= (48 * activity.resources.displayMetrics.density).toInt())
                    assertTrue(action.performAction(AccessibilityNodeInfo.ACTION_CLICK))
                    runner.waitForIdleSync()
                    assertEquals(1, disconnects.get())
                    assertEquals(0, details.get())
                    val device = clickableAncestor(findText(runner.uiAutomation.rootInActiveWindow, case.name))
                    assertNotNull("Device name row must be actionable", device)
                    assertTrue(device!!.performAction(AccessibilityNodeInfo.ACTION_CLICK))
                    runner.waitForIdleSync()
                    assertEquals(1, details.get())
                    assertEquals(1, disconnects.get())
                }
            } finally {
                runner.runOnMainSync { activity.finish() }
                runner.waitForIdleSync()
            }
        }
    }

    private fun clickableAncestor(node: AccessibilityNodeInfo?): AccessibilityNodeInfo? {
        var current = node
        repeat(8) {
            if (current?.isClickable == true) return current
            current = current?.parent
        }
        return null
    }

    private fun findText(
        node: AccessibilityNodeInfo?,
        text: String,
        depth: Int = 0,
    ): AccessibilityNodeInfo? {
        if (node == null || depth > 32) return null
        if (
            node.text?.toString()?.contains(text) == true ||
                node.contentDescription?.toString()?.contains(text) == true
        )
            return node
        for (i in 0 until node.childCount) {
            findText(node.getChild(i), text, depth + 1)?.let {
                return it
            }
        }
        return null
    }

    private fun capture(activity: MainActivity, id: String) {
        val runner = InstrumentationRegistry.getInstrumentation()
        val view = activity.window.decorView
        val bitmap = Bitmap.createBitmap(view.width, view.height, Bitmap.Config.ARGB_8888)
        val copied = CountDownLatch(1)
        var result = PixelCopy.ERROR_UNKNOWN
        // Copy this fixture's window buffer; a display screenshot can retain the previous activity
        // while SurfaceFlinger is completing its transition even after accessibility has updated.
        PixelCopy.request(
            activity.window,
            bitmap,
            {
                result = it
                copied.countDown()
            },
            Handler(Looper.getMainLooper()),
        )
        assertTrue("Fixture capture timed out: $id", copied.await(10, TimeUnit.SECONDS))
        assertEquals("Fixture capture failed: $id", PixelCopy.SUCCESS, result)
        val file = File(runner.targetContext.getExternalFilesDir(null), "home-review/$id.png")
        file.parentFile!!.mkdirs()
        file.outputStream().use { assertTrue(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) }
        bitmap.recycle()
    }

    private data class Review(
        val id: String,
        val dark: Boolean,
        val state: ConnectionState?,
        val status: String,
        val fontScale: Float = 1f,
        val highActivity: Boolean = false,
        val compact: Boolean = false,
        val name: String = "Anish’s MacBook Air",
        val width: Int = 360,
    )
}
