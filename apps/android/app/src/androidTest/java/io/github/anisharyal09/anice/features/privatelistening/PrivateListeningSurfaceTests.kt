// SPDX-License-Identifier: GPL-3.0-or-later
// Renders buffering choices and local diagnostics in synthetic emulator layouts without native capture or playback.
package io.github.anisharyal09.anice.features.privatelistening

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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Surface
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.test.platform.app.InstrumentationRegistry
import io.github.anisharyal09.anice.MainActivity
import io.github.anisharyal09.anice.infrastructure.connections.ChannelDescriptor
import io.github.anisharyal09.anice.infrastructure.connections.SecuredChannel
import io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity
import io.github.anisharyal09.anice.ui.theme.AniCeTheme
import kotlinx.coroutines.runBlocking
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test

class PrivateListeningSurfaceTests {
    @Suppress("DEPRECATION") // Compose exposes non-tab selection through checked state on API 29–36.
    @Test fun bufferChoicesReflowAcrossThemesWidthsAndTextScalesWithoutStartingAudio() {
        val runner = InstrumentationRegistry.getInstrumentation()
        assumeTrue("Synthetic layouts run only on an isolated emulator",
            Build.HARDWARE in setOf("ranchu", "goldfish") &&
                runner.targetContext.packageName == "io.github.anisharyal09.anice.preview.listening.ui.regression")
        lateinit var controller: PrivateListeningController
        var ticket: PrivateListeningRequest? = null
        var starts = 0
        var closedOutputs = 0
        runner.runOnMainSync {
            controller = PrivateListeningController(automaticTicks = false)
            controller.loadLocalFingerprint = { "b".repeat(64) }
            controller.startupAllowed = { true }
            controller.startService = { request ->
                starts++
                ticket = request
                controller.serviceAttached(request, this, object : PrivateListeningOutput {
                    override fun offer(message: PrivateListeningMessage) = true
                    override fun pause() {}
                    override suspend fun resume() {}
                    override fun close() { closedOutputs++ }
                })
                controller.ready(request)
                controller.playbackHealth(request, ListeningPlaybackHealth(10, 4800, 1920, 2, false,
                    targetFrames = 1920, nativeQueuedFrames = 960, nativeBufferFrames = 11724,
                    nativeWriteLimitFrames = 960, droppedPackets = 3,
                    routeType = android.media.AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
                    gapRecoveries = 1, rebufferCount = 1, maximumArrivalGapMillis = 45))
            }
        }
        val channel = object : SecuredChannel {
            override val descriptor = ChannelDescriptor("visual-listening", "lan", DeviceIdentity(
                "01234567-89ab-4cde-8fab-0123456789ab", "Fixture Mac", "macos", "fixture-key", "a".repeat(64)))
            override suspend fun sendData(bytes: ByteArray) {}
        }
        val activity = runner.startActivitySync(Intent(runner.targetContext, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) as MainActivity
        try {
            for (active in listOf(false, true)) {
            if (active) runner.runOnMainSync {
                controller.available(channel)
                controller.setConsent(true)
                controller.setBufferProfile(ListeningBufferProfile.LOWER_DELAY)
                runBlocking { controller.handle(channel.descriptor, PrivateListeningMessage.start(
                    "01234567-89ab-4cde-8fab-0123456789ac").encode()) }
                assertTrue(controller.active)
                assertNotNull(controller.diagnostics)
                assertEquals(ListeningBufferProfile.LOWER_DELAY, controller.bufferProfile)
            }
            for (dark in listOf(false, true)) for (width in listOf(300, 400)) for (scale in listOf(0.8f, 1.2f)) {
                val drawn = CountDownLatch(1)
                runner.runOnMainSync {
                    activity.setContent {
                        val configuration = Configuration(LocalConfiguration.current).apply {
                            uiMode = (uiMode and Configuration.UI_MODE_NIGHT_MASK.inv()) or
                                if (dark) Configuration.UI_MODE_NIGHT_YES else Configuration.UI_MODE_NIGHT_NO
                        }
                        val density = LocalDensity.current
                        CompositionLocalProvider(LocalConfiguration provides configuration,
                            LocalDensity provides Density(density.density, scale)) {
                            AniCeTheme {
                                Surface(Modifier.fillMaxSize()) {
                                    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.TopCenter) {
                                        Column(Modifier.width(width.dp).verticalScroll(rememberScrollState())
                                            .padding(16.dp)) {
                                            PrivateListeningView(controller)
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
                assertTrue(drawn.await(10, TimeUnit.SECONDS))
                runner.waitForIdleSync()
                runner.uiAutomation.waitForIdle(200, 5000)
                // Compose can publish the previous content's accessibility tree after the new frame.
                val expectedStatus = if (active) "Listening to Fixture Mac." else
                    "Connect LAN and enable receiving for your Mac."
                val deadline = android.os.SystemClock.uptimeMillis() + 5000
                var root = runner.uiAutomation.rootInActiveWindow
                while (find(root, expectedStatus) == null && android.os.SystemClock.uptimeMillis() < deadline) {
                    Thread.sleep(25)
                    root = runner.uiAutomation.rootInActiveWindow
                }
                assertNotNull("Accessibility must reflect the current fixture; active=$active theme=$dark width=$width scale=$scale package=${root?.packageName} tree=${describe(root)}",
                    find(root, expectedStatus))
                assertNotNull(find(root, "Balanced"))
                assertNotNull(find(root, "Lower delay"))
                val balanced = radio(find(root, "Balanced"))
                val lower = radio(find(root, "Lower delay"))
                assertNotNull("Balanced must expose a checkable selection row", balanced)
                assertNotNull("Lower delay must expose a checkable selection row", lower)
                assertEquals(!active, balanced!!.isChecked)
                assertEquals(active, lower!!.isChecked)
                assertEquals(!active, balanced.isEnabled)
                assertEquals(!active, lower.isEnabled)
                if (active) {
                    assertNotNull(find(root, "Stop listening"))
                }
                val view = activity.window.decorView
                val bitmap = Bitmap.createBitmap(view.width, view.height, Bitmap.Config.ARGB_8888)
                val copied = CountDownLatch(1)
                var result = PixelCopy.ERROR_UNKNOWN
                PixelCopy.request(activity.window, bitmap, { result = it; copied.countDown() },
                    Handler(Looper.getMainLooper()))
                assertTrue(copied.await(10, TimeUnit.SECONDS))
                assertEquals(PixelCopy.SUCCESS, result)
                val path = File(runner.targetContext.getExternalFilesDir(null),
                    "private-listening-review/${if (active) "active" else "idle"}-${if (dark) "dark" else "light"}-$width-$scale.png")
                check(path.parentFile!!.isDirectory || path.parentFile!!.mkdirs())
                path.outputStream().use { assertTrue(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) }
                val artifactRoot = InstrumentationRegistry.getArguments().getString("additionalTestOutputDir")
                    ?: "/sdcard/Android/media/${runner.targetContext.packageName}/additional_test_output"
                val artifact = File(artifactRoot, "private-listening-review/${path.name}")
                check(artifact.parentFile!!.isDirectory || artifact.parentFile!!.mkdirs())
                artifact.outputStream().use { assertTrue(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) }
                bitmap.recycle()
            }
            }
            assertEquals(1, starts) // Only a fake service ticket was created for the active layout.
            runner.runOnMainSync {
                controller.stop()
                ticket?.let { controller.serviceDestroyed(it, this) }
                assertFalse(controller.active)
                assertNull(controller.diagnostics)
                assertEquals(1, closedOutputs)
            }
        } finally {
            runner.runOnMainSync { controller.invalidate(); activity.finish() }
        }
    }

    private fun find(node: AccessibilityNodeInfo?, text: String): AccessibilityNodeInfo? {
        if (node == null) return null
        if (node.text?.toString()?.contains(text) == true ||
            node.contentDescription?.toString()?.contains(text) == true) return node
        for (index in 0 until node.childCount) find(node.getChild(index), text)?.let { return it }
        return null
    }

    private fun radio(node: AccessibilityNodeInfo?): AccessibilityNodeInfo? {
        var current = node
        while (current != null) {
            if (current.isCheckable) return current
            current = current.parent
        }
        return null
    }

    private fun describe(node: AccessibilityNodeInfo?, depth: Int = 0): String {
        if (node == null || depth > 12) return ""
        return "${node.text}:${node.className} " +
            (0 until node.childCount).joinToString(" ") { describe(node.getChild(it), depth + 1) }
    }
}
