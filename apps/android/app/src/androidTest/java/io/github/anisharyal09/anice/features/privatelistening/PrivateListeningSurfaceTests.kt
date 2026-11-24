// SPDX-License-Identifier: GPL-3.0-or-later
// Renders buffering choices and local diagnostics in synthetic emulator layouts without native capture or playback.
package io.github.anisharyal09.anice.features.privatelistening

import android.content.Intent
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.Rect
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
import androidx.compose.material3.Text
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
import io.github.anisharyal09.anice.infrastructure.session.Cbor
import io.github.anisharyal09.anice.ui.theme.AniCeTheme
import io.github.anisharyal09.anice.ui.AniCeActionButton
import io.github.anisharyal09.anice.ui.EmulatorPresentationRule
import kotlinx.coroutines.runBlocking
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.Rule

class PrivateListeningSurfaceTests {
    @get:Rule val presentation: org.junit.rules.TestRule = EmulatorPresentationRule()

    @Suppress("DEPRECATION") // Compose exposes non-tab selection through checked state on API 29–36.
    @Test fun bufferChoicesReflowAcrossThemesWidthsAndTextScalesWithoutStartingAudio() {
        val runner = InstrumentationRegistry.getInstrumentation()
        assumeTrue("Synthetic layouts run only on an isolated emulator",
            Build.HARDWARE in setOf("ranchu", "goldfish") &&
                runner.targetContext.packageName == "io.github.anisharyal09.anice.preview.listening.ui.regression")
        lateinit var controller: PrivateListeningController
        lateinit var reverse: PhoneAudioController
        var ticket: PrivateListeningRequest? = null
        var reverseTicket: PhoneAudioRequest? = null
        var starts = 0
        var closedOutputs = 0
        runner.runOnMainSync {
            controller = PrivateListeningController(automaticTicks = false)
            reverse = PhoneAudioController(automaticTicks = false)
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
        runner.runOnMainSync {
            controller.available(channel)
            reverse.available(channel)
            reverse.startService = { request, grant ->
                checkNotNull(grant.consume())
                reverseTicket = request
                reverse.serviceAttached(request, this, object : PhoneAudioCaptureControl {
                    override fun start() { reverse.capturePrepared(request) }
                    override fun close() {}
                })
            }
            reverse.stopService = { request -> reverse.serviceDestroyed(request, this) }
            runBlocking { reverse.handle(channel.descriptor,
                PhoneAudioMessage.from(PrivateListeningMessage.capability(true)).encode()) }
        }
        val activity = runner.startActivitySync(Intent(runner.targetContext, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) as MainActivity
        try {
            for (state in listOf("idle", "forward", "reverse")) {
            val active = state == "forward"
            if (active) runner.runOnMainSync {
                controller.setConsent(true)
                controller.setBufferProfile(ListeningBufferProfile.LOWER_DELAY)
                runBlocking { controller.handle(channel.descriptor, PrivateListeningMessage.start(
                    "01234567-89ab-4cde-8fab-0123456789ac").encode()) }
                assertTrue(controller.active)
                assertNotNull(controller.diagnostics)
                assertEquals(ListeningBufferProfile.LOWER_DELAY, controller.bufferProfile)
            }
            if (state == "reverse") runner.runOnMainSync {
                controller.stop()
                ticket?.let { controller.serviceDestroyed(it, this) }
                reverse.begin(PhoneAudioGrant(-1, Any()))
                runBlocking {
                    val request = requireNotNull(reverseTicket)
                    reverse.handle(channel.descriptor, PhoneAudioMessage(2, listOf(
                        Cbor.Text(request.id), Cbor.Integer(0))).encode())
                }
                assertTrue(reverse.active)
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
                                             PrivateListeningView(controller, reverse)
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
                 val expectedStatus = if (state == "reverse") "Sending this phone's audio to Fixture Mac."
                     else if (active) "Listening to Fixture Mac." else
                    "Connect LAN and enable receiving for your Mac."
                val deadline = android.os.SystemClock.uptimeMillis() + 5000
                var root = runner.uiAutomation.rootInActiveWindow
                while (find(root, expectedStatus) == null && android.os.SystemClock.uptimeMillis() < deadline) {
                    Thread.sleep(25)
                    root = runner.uiAutomation.rootInActiveWindow
                }
                assertNotNull("Accessibility must reflect the current fixture; active=$active theme=$dark width=$width scale=$scale package=${root?.packageName} tree=${describe(root)}",
                    find(root, expectedStatus))
                 if (state != "reverse") {
                     val balanced = radio(find(root, "Balanced"))
                     val lower = radio(find(root, "Lower delay"))
                     assertNotNull("Balanced must expose a checkable selection row", balanced)
                     assertNotNull("Lower delay must expose a checkable selection row", lower)
                     assertEquals(!active, balanced!!.isChecked)
                     assertEquals(active, lower!!.isChecked)
                     assertEquals(!active, balanced.isEnabled)
                     assertEquals(!active, lower.isEnabled)
                 }
                 if (active) {
                     assertActionTarget(find(root, "Stop listening"), activity)
                 } else if (state == "reverse") {
                     val stop = requireNotNull(clickable(find(root, "Stop phone audio")))
                     assertActionTarget(stop, activity)
                     val heading = requireNotNull(find(root, "Send phone audio to Mac"))
                     assertTrue("Stop follows active heading", bounds(stop).top > bounds(heading).bottom)
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
                     "private-listening-review/$state-${if (dark) "dark" else "light"}-$width-$scale.png")
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
                 reverse.stop()
                assertFalse(controller.active)
                assertNull(controller.diagnostics)
                assertEquals(1, closedOutputs)
            }
        } finally {
             runner.runOnMainSync { controller.invalidate(); reverse.invalidate(); activity.finish() }
        }
    }

    @Test fun compactActionMatchesHomeAndCheckboxLabelTogglesOnlyOnce() {
        val runner = InstrumentationRegistry.getInstrumentation()
        assumeTrue("Only isolated emulator UI fixtures", Build.HARDWARE in setOf("ranchu", "goldfish") &&
            runner.targetContext.packageName == "io.github.anisharyal09.anice.preview.listening.ui.regression")
        val activity = runner.startActivitySync(Intent(runner.targetContext, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) as MainActivity
        var clicks = 0
        var toggles = 0
        try {
            runner.runOnMainSync {
                activity.setContent {
                    AniCeTheme {
                        var checked by remember { mutableStateOf(false) }
                        Column(Modifier.fillMaxSize().safeDrawingPadding().padding(12.dp)) {
                            androidx.compose.material3.OutlinedButton(onClick = {},
                                shape = androidx.compose.material3.MaterialTheme.shapes.small,
                                contentPadding = PaddingValues(horizontal = 10.dp, vertical = 2.dp),
                                modifier = Modifier.defaultMinSize(minHeight = 32.dp)) { Text("Home action") }
                            AniCeActionButton(onClick = { clicks++ }) { Text("Listening action") }
                            io.github.anisharyal09.anice.ui.AutomaticConnectionToggle(
                                checked = checked, enabled = true, label = "Allow audio",
                                onCheckedChange = { checked = it; toggles++ })
                        }
                    }
                }
            }
            runner.waitForIdleSync()
            runner.uiAutomation.waitForIdle(200, 5000)
            val root = runner.uiAutomation.rootInActiveWindow
            val home = requireNotNull(clickable(find(root, "Home action")))
            val listening = requireNotNull(clickable(find(root, "Listening action")))
            assertEquals(bounds(home).height(), bounds(listening).height())
            assertActionTarget(listening, activity)
            assertTrue(listening.performAction(AccessibilityNodeInfo.ACTION_CLICK))
            val row = requireNotNull(clickable(find(root, "Allow audio")))
            assertTrue(row.isCheckable)
            assertTrue(row.performAction(AccessibilityNodeInfo.ACTION_CLICK))
            runner.waitForIdleSync()
            assertEquals(1, clicks)
            assertEquals(1, toggles)
        } finally { runner.runOnMainSync { activity.finish() } }
    }

    private fun bounds(node: AccessibilityNodeInfo) = Rect().also { node.getBoundsInScreen(it) }

    private fun clickable(node: AccessibilityNodeInfo?): AccessibilityNodeInfo? {
        var current = node
        while (current != null) {
            if (current.isClickable) return current
            current = current.parent
        }
        return null
    }

    private fun assertActionTarget(node: AccessibilityNodeInfo?, activity: MainActivity) {
        val action = requireNotNull(clickable(node))
        val density = activity.resources.displayMetrics.density
        assertTrue("Action retains a 48 dp interaction area", bounds(action).height() >= (48 * density).toInt() - 1)
        assertTrue("Action fits the physical viewport", bounds(action).right <= activity.window.decorView.width)
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
