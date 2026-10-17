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
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.github.anisharyal09.anice.MainActivity
import io.github.anisharyal09.anice.features.session.DeviceSessionCard
import io.github.anisharyal09.anice.ui.theme.AniCeTheme
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
        assertTrue(cases.size >= 9)
        for (case in cases) {
            val activity =
                runner.startActivitySync(
                    Intent(runner.targetContext, MainActivity::class.java)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                ) as MainActivity
            try {
                val drawn = CountDownLatch(1)
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
                                                title = { Text("aniCe") },
                                                actions = {
                                                    TextButton(onClick = {}) { Text("This device") }
                                                },
                                                colors =
                                                    TopAppBarDefaults.topAppBarColors(
                                                        containerColor =
                                                            MaterialTheme.colorScheme.surface
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
                                                modifier = Modifier.widthIn(max = case.width.dp),
                                                sessions = {
                                                    case.state?.let {
                                                        DeviceSessionCard(
                                                            case.name,
                                                            it,
                                                            case.status,
                                                            true,
                                                            {},
                                                            {},
                                                            {},
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
                capture(activity, case.id)
                if (case.state == ConnectionState.SECURED) {
                    assertTrue(findText(root, "Connected") != null || findText(root, "Secured") != null)
                    val tools = findText(root, "Connection details") ?: findText(root, "More")
                    assertNotNull("Missing accessible More action", tools)

                }
            } finally {
                runner.runOnMainSync { activity.finish() }
                runner.waitForIdleSync()
            }
        }
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
        val name: String = "Anish’s MacBook Air",
        val width: Int = 360,
    )
}
