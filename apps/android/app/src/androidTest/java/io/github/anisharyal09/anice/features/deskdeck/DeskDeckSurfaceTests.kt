// SPDX-License-Identifier: GPL-3.0-or-later
// Reviews the native deck and shortcut migration with isolated channels, without grants or ringing.
package io.github.anisharyal09.anice.features.deskdeck

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
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
import io.github.anisharyal09.anice.features.finddevice.*
import io.github.anisharyal09.anice.infrastructure.connections.*
import io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity
import io.github.anisharyal09.anice.infrastructure.pairing.PairingMethod
import io.github.anisharyal09.anice.infrastructure.pairing.PeerTrustRecord
import io.github.anisharyal09.anice.ui.EmulatorPresentationRule
import io.github.anisharyal09.anice.ui.theme.AniCeTheme
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

@RunWith(AndroidJUnit4::class)
class DeskDeckSurfaceTests {
    @get:Rule val presentation: org.junit.rules.TestRule = EmulatorPresentationRule()
    private val runner get() = InstrumentationRegistry.getInstrumentation()
    private val context get() = runner.targetContext

    @Test fun findMacUsesItsOwnReadinessFeedbackAndRequestLifecycleInTheActualDeck() {
        requirePreview()
        val restore = overridePreferences("desk_deck", mapOf("selected_peer" to "mac-a", "keep_awake_charging" to false))
        val activity = startActivity()
        val h = Harness(context)
        var connects = 0
        try {
            onMain { h.connect(findCapable = false); h.deck.start(h.peer); h.sample() }
            show(activity) {
                Fixture(false, 1f, 320) {
                    DeskDeckView(h.deck, h.power, h.find, listOf(record(h.peer)), true,
                        onConnect = { connects++ }, onPairMac = {})
                }
            }
            awaitControl("Find Mac is not available on this connection.")
            awaitControl("Find Mac", enabled = false)
            assertTrue(h.deck.readingsAreFresh)
            onMain { h.find.handle(h.channel.descriptor, FindDeviceMessage(1).encode()) }
            awaitControl("Notify Mac")
            awaitControl("Find Mac", enabled = true)
            onMain { assertTrue(h.deck.command(1)); assertTrue(h.deck.isBusy(1)) }
            click("Find Mac")
            awaitControl("Waiting for Mac")
            awaitControl("Find Mac", enabled = false)
            assertEquals(1, h.requests().size)
            assertEquals(1, h.deckCommands())
            assertEquals(0, connects)
            assertEquals(0, h.posts)
            assertNull(find(root(), "Allow Find Phone alerts"))
            awaitControl("Waiting for Mac").performAction(AccessibilityNodeInfo.ACTION_CLICK)
            idle()
            assertEquals("Disabled activation cannot send twice", 1, h.requests().size)

            onMain { h.reply(FindResult.BLOCKED) }
            awaitControl("aniCe → Settings → Permissions → Notifications")
            awaitControl("Find Mac", enabled = true)
            assertEquals("Sending…", h.deck.actionFeedback(1))
            capture(activity, "find-blocked-actual-deck")
            onMain { h.advance(4_000) }
            assertFalse(h.deck.readingsAreFresh)
            assertEquals(DeskDeckConnectionState.STALE, h.deck.connectionState)
            assertTrue(awaitControl("Find Mac").isEnabled)
            assertFalse(awaitControl("Lock Mac").isEnabled)
            click("Find Mac")
            onMain { h.reply(FindResult.SUBMITTED) }
            awaitControl("Mac submitted the notification")
            awaitControl("Find Mac", enabled = true)
            capture(activity, "find-submitted-stale-deck")

            click("Find Mac")
            onMain { h.advance(10_000) }
            awaitControl("No response received")
            awaitControl("Find Mac", enabled = true)
            assertEquals(3, h.requests().size)
            onMain { h.deck.refresh() }
            idle()
            assertEquals("Refresh cannot replay a Find request", 3, h.requests().size)
            assertEquals("Refresh cannot replay Lock Mac", 1, h.deckCommands())
            click("Find Mac")
            val retired = h.channel
            val old = h.requests().last()
            onMain { h.deck.retired(retired.descriptor); h.find.retired(retired.descriptor) }
            awaitControl("Connection closed")
            awaitControl("Find Mac", enabled = false)
            onMain { h.connect() }
            awaitControl("Find Mac", enabled = true)
            assertTrue(h.requests().isEmpty())
            onMain {
                assertEquals(DataHandling.DISCARDED, h.find.handle(retired.descriptor,
                    FindDeviceMessage(3, old.id, old.sequence, 0).encode()))
            }
            awaitControl("Connection closed")
            assertEquals(0, connects)
            assertEquals(0, h.posts)
        } finally {
            onMain { h.close(); activity.finish() }
            restore()
        }
    }

    @Test fun findCardAndPeerChoicesReflowAcrossThemesWidthsAndTextSizes() {
        requirePreview()
        val restoreDeck = overridePreferences("desk_deck", mapOf("selected_peer" to "mac-a", "keep_awake_charging" to false))
        val restoreAppearance = overridePreferences("appearance", mapOf("mode" to "System"))
        try {
            for (dark in listOf(false, true)) for (scale in listOf(0.8f, 1.2f)) for (width in listOf(280, 640)) {
                val activity = startActivity()
                val h = Harness(context)
                val other = h.peer.copy(deviceId = "mac-b", fingerprint = "fingerprint-b",
                    deviceName = "Second studio Mac with a long name")
                try {
                    onMain { h.connect(); h.deck.start(h.peer); h.sample() }
                    show(activity) {
                        Fixture(dark, scale, width) {
                            Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                                Text("Mac Desk Deck", style = MaterialTheme.typography.titleMedium)
                                DeskDeckView(h.deck, h.power, h.find, listOf(record(h.peer), record(other)), true,
                                    onConnect = {}, onPairMac = {}, modifier = Modifier.weight(1f))
                            }
                        }
                    }
                    val ready = awaitControl("Find Mac")
                    val density = minOf(activity.resources.displayMetrics.density,
                        activity.resources.displayMetrics.widthPixels / width.toFloat())
                    assertTrue(ready.isEnabled)
                    assertTrue(bounds(ready).height() >= (48 * density).toInt() - 1)
                    assertTrue(bounds(root()).contains(bounds(ready)))
                    val id = "${if (dark) "dark" else "light"}-${(scale * 100).toInt()}-$width"
                    capture(activity, "find-ready-$id")
                    click("Find Mac")
                    onMain { h.reply(FindResult.BLOCKED); h.advance(4_000) }
                    awaitControl("aniCe → Settings → Permissions → Notifications")
                    val guidance = awaitControl("Find Mac", enabled = true)
                    assertTrue(bounds(root()).contains(bounds(guidance)))
                    capture(activity, "find-recovery-$id")
                    click(other.deviceName)
                    assertFalse(h.find.canFind(other))
                    awaitControl("Connect this Mac to send an alert")
                    awaitControl("Find Mac", enabled = false)
                    assertNull("Another peer must not inherit permission feedback",
                        find(root(), "aniCe → Settings → Permissions → Notifications"))
                    capture(activity, "find-other-peer-$id")
                    click(h.peer.deviceName)
                    awaitControl("aniCe → Settings → Permissions → Notifications")
                    awaitControl("Find Mac", enabled = true)
                    assertEquals("Selection never sends another request", 1, h.channels.sumOf { channel ->
                        channel.sent.count { FindDeviceMessage.decode(it)?.kind == 2L }
                    })
                } finally { onMain { h.close(); activity.finish() } }
            }
        } finally { restoreDeck(); restoreAppearance() }
    }

    @Test fun findPhonePermissionRecoveryRetainsIndependentLocalActionsAndNativeReceiverIdentity() {
        requirePreview()
        val activity = startActivity()
        val allowed = mutableStateOf(false)
        val showGranted = mutableStateOf(false)
        val requestable = mutableStateOf(true)
        var requests = 0
        var settings = 0
        try {
            show(activity) {
                Fixture(true, 1.2f, 280) {
                    Column(Modifier.fillMaxWidth().padding(12.dp)) {
                        FindPhonePermissionRow(allowed.value, showGranted.value, requestable.value,
                            request = { requests++ }, openSettings = { settings++ })
                    }
                }
            }
            val action = awaitControl("Allow Find Phone alerts")
            assertTrue(bounds(action).height() >= (48 * activity.resources.displayMetrics.density).toInt() - 1)
            click("Allow Find Phone alerts")
            assertEquals(1, requests)
            assertEquals(0, settings)
            runner.runOnMainSync { requestable.value = false }
            click("Notification settings")
            assertEquals(1, requests)
            assertEquals(1, settings)
            capture(activity, "find-phone-permission-denied")
            runner.runOnMainSync { allowed.value = true }
            awaitAbsent("Find Phone notifications")
            runner.runOnMainSync { showGranted.value = true }
            awaitControl("Find Phone notifications")
            awaitControl("Receive Find Phone ringing requests")
            assertNull(find(root(), "Notification settings"))
            assertNull(find(root(), "Allow Find Phone alerts"))
            capture(activity, "find-phone-permission-granted")

            val service = context.packageManager.getServiceInfo(ComponentName(context, FindDeviceRingService::class.java), 0)
            assertFalse(service.exported)
            assertEquals(ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK, service.foregroundServiceType)
            val receiver = context.packageManager.getReceiverInfo(ComponentName(context, FindDeviceDismissReceiver::class.java), 0)
            assertFalse(receiver.exported)
            assertEquals("anice_find_device", FindDeviceNotification.CHANNEL)
            val intent = findPhoneNotificationSettingsIntent(context)
            assertEquals(context.packageName, intent.getStringExtra(android.provider.Settings.EXTRA_APP_PACKAGE))
        } finally { runner.runOnMainSync { activity.finish() } }
    }

    @Test fun nativeLauncherMigratesOneDeskDeckShortcutAndKeepsEmptyFavouritesAfterRestart() {
        requirePreview()
        val restore = overridePreferences("ui_preferences", mapOf(
            "favourite_features" to "Files,FindDevice,DeskDeck,Clipboard",
            "feature_order" to "Files,FindDevice,Clipboard,DeskDeck",
        ))
        var activity: MainActivity? = null
        try {
            activity = startActivity()
            click("Favourites")
            awaitControl("Mac Desk Deck")
            assertEquals(1, count(root(), "Mac Desk Deck"))
            assertNull(find(root(), "Find Device"))
            capture(activity, "favourites-migrated-native-shell")
            val prefs = context.getSharedPreferences("ui_preferences", Context.MODE_PRIVATE)
            assertEquals("Files,DeskDeck,Clipboard", prefs.getString("favourite_features", null))
            assertEquals("Files,DeskDeck,Clipboard", prefs.getString("feature_order", null))
            click("Mac Desk Deck")
            awaitControl("Pair a Mac to use Desk Deck")
            click("Back")
            awaitControl("Your selected shortcuts")
            assertNotNull(find(root(), "Mac Desk Deck"))
            click("Features")
            awaitControl("Open a feature")
            assertNull(find(root(), "Find Device"))
            capture(activity, "features-without-standalone-find")
            val current = activity
            runner.runOnMainSync { current.finish() }
            activity = null
            idle()
            assertTrue(prefs.edit().putString("favourite_features", "").commit())
            activity = startActivity()
            click("Favourites")
            awaitControl("No favourites yet")
            assertNull(find(root(), "Mac Desk Deck"))
            assertEquals("", prefs.getString("favourite_features", null))
        } finally {
            activity?.let { current -> runner.runOnMainSync { current.finish() } }
            restore()
        }
    }

    @Test fun nativePermissionsKeepsFindPhoneRecoveryOutsideTheDeckWithoutRequestingAccess() {
        requirePreview()
        val app = context.applicationContext as io.github.anisharyal09.anice.AniCeApplication
        val allowed = app.findDeviceNotification.permitted()
        val activity = startActivity()
        try {
            click("Settings")
            click("Permissions")
            reveal("Find Phone notifications")
            assertNotNull(find(root(), "Find Phone notifications"))
            assertNotNull(find(root(), "Receive Find Phone ringing requests from your Mac"))
            if (!allowed) {
                reveal("Allow Find Phone alerts")
                assertNotNull(find(root(), "Allow Find Phone alerts"))
            }
            capture(activity, "find-phone-native-permissions")
            assertEquals("Viewing recovery never grants permission", allowed, app.findDeviceNotification.permitted())
            assertNull(app.findDevice.incomingAlert)
        } finally { runner.runOnMainSync { activity.finish() } }
    }

    @Test fun statusDetailsStayInlineOnPhoneAndAudioOutputCardSwitchesRoutesAndShowsPingMac() {
        requirePreview()
        val restoreDeck = overridePreferences("desk_deck", mapOf("selected_peer" to "mac-a", "keep_awake_charging" to false))
        val restoreAppearance = overridePreferences("appearance", mapOf("mode" to "System"))
        val speakerID = UUID.randomUUID().toString()
        val airpodsID = UUID.randomUUID().toString()
        val catalogRevision = UUID.randomUUID().toString()
        try {
            for (dark in listOf(false, true)) {
                val activity = startActivity()
                val h = Harness(context)
                try {
                    onMain {
                        h.connect(version = 5, actions = 41)
                        h.deck.start(h.peer)
                        h.sample(version = 5, actions = 41, outputRouteID = speakerID)
                        h.outputCatalog(catalogRevision, listOf(
                            DeskDeckOutputRoute(speakerID, "MacBook Pro Speakers"),
                            DeskDeckOutputRoute(airpodsID, "AirPods Pro (USB-C)"),
                        ))
                    }
                    show(activity) {
                        Fixture(dark, 1f, 412) {
                            Column(Modifier.fillMaxSize().padding(horizontal = 4.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                                Text("Mac Desk Deck", style = MaterialTheme.typography.titleMedium)
                                DeskDeckView(h.deck, h.power, h.find, listOf(record(h.peer)), true,
                                    onConnect = {}, onPairMac = {}, modifier = Modifier.weight(1f))
                            }
                        }
                    }
                    val density = minOf(activity.resources.displayMetrics.density,
                        activity.resources.displayMetrics.widthPixels / 412f)
                    val details = awaitControl("Details")
                    val detailsBounds = bounds(details)
                    val liveSummary = awaitControl("Live ·")
                    val summaryBounds = bounds(liveSummary)
                    assertTrue("Details must stay inline with status summary on phone",
                        detailsBounds.top <= summaryBounds.bottom && detailsBounds.left >= summaryBounds.left)
                    assertTrue("Details must keep 48dp minimum height", detailsBounds.height() >= (48 * density).toInt() - 1)
                    assertTrue("Details height must stay single-row", detailsBounds.height() < (72 * density).toInt())

                    awaitControl("Find Mac")
                    awaitControl("Ping Mac")
                    capture(activity, "desk-deck-top-${if (dark) "dark" else "light"}")

                    reveal("Mac output volume")
                    val selector = awaitControl("MacBook Pro Speakers")
                    awaitControl("2 Mac outputs · tap to switch")
                    awaitControl("35%")
                    val refreshOutputs = awaitControl("Refresh output devices")
                    assertTrue(bounds(selector).height() >= (48 * density).toInt() - 1)
                    assertTrue(bounds(refreshOutputs).height() >= (48 * density).toInt() - 1)
                    assertTrue(bounds(root()).contains(bounds(selector)))
                    capture(activity, "desk-deck-v5-${if (dark) "dark" else "light"}")

                    if (!dark) {
                        click("MacBook Pro Speakers")
                        awaitControl("AirPods Pro (USB-C)")
                        capture(activity, "desk-deck-v5-menu-light")
                        click("AirPods Pro (USB-C)")
                        val commands = h.channels.flatMap { c -> c.sent.mapNotNull(DeskDeckMessage::decode).filter { it.kind == 4L } }
                        assertTrue("Selecting an output route sends action 10 for the chosen route",
                            commands.any { it.action == 10L && it.target == airpodsID && it.revision == catalogRevision })
                    }
                } finally { onMain { h.close(); activity.finish() } }
            }

            val compactActivity = startActivity()
            val compactHarness = Harness(context)
            try {
                onMain {
                    compactHarness.connect(version = 5, actions = 41)
                    compactHarness.deck.start(compactHarness.peer)
                    compactHarness.sample(version = 5, actions = 41, outputRouteID = speakerID)
                    compactHarness.outputCatalog(catalogRevision, listOf(
                        DeskDeckOutputRoute(speakerID, "MacBook Pro Speakers"),
                        DeskDeckOutputRoute(airpodsID, "AirPods Pro (USB-C)"),
                    ))
                    compactHarness.close()
                }
                show(compactActivity) {
                    Fixture(false, 1.2f, 280) {
                        Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            Text("Mac Desk Deck", style = MaterialTheme.typography.titleMedium)
                            DeskDeckView(compactHarness.deck, compactHarness.power, compactHarness.find,
                                listOf(record(compactHarness.peer)), true, onConnect = {}, onPairMac = {}, modifier = Modifier.weight(1f))
                        }
                    }
                }
                val compactDensity = minOf(compactActivity.resources.displayMetrics.density,
                    compactActivity.resources.displayMetrics.widthPixels / 280f)
                val connectButton = awaitControl("Connect")
                val detailsButton = awaitControl("Details")
                assertTrue(bounds(root()).contains(bounds(connectButton)))
                assertTrue(bounds(root()).contains(bounds(detailsButton)))
                assertTrue(bounds(detailsButton).height() >= (48 * compactDensity).toInt() - 1)
                awaitControl("Ping Mac")
                reveal("Mac output volume")
                awaitControl("Output device")
                awaitControl("Output volume")
                capture(compactActivity, "desk-deck-v5-compact-light")
            } finally { onMain { compactHarness.close(); compactActivity.finish() } }
        } finally { restoreDeck(); restoreAppearance() }
    }

    private class Harness(context: Context) {
        val peer = DeviceIdentity("mac-a", "Studio Mac with a long device name", "macos", "key", "fingerprint-a")
        private var time = 1_000L
        private data class Timer(val deadline: Long, val wake: CompletableDeferred<Unit>)
        private val timers = mutableListOf<Timer>()
        private suspend fun wait(millis: Long) {
            val timer = Timer(time + millis, CompletableDeferred())
            timers.add(timer)
            try { timer.wake.await() } finally { timers.remove(timer) }
        }
        var posts = 0
        val find = FindDeviceController(object : FindDeviceNotifying {
            override suspend fun post(identifier: String, peerName: String): FindResult { posts++; return FindResult.SUBMITTED }
            override fun clear(identifier: String) {}
        }, now = { time }, wait = ::wait)
        val deck = DeskDeckController(clock = { time }, wait = ::wait)
        val power = DevicePowerController(context)
        val channels = mutableListOf<Channel>()
        lateinit var channel: Channel
        class Channel(peer: DeviceIdentity) : SecuredChannel {
            override val descriptor = ChannelDescriptor(UUID.randomUUID().toString(), "lan", peer)
            val sent = mutableListOf<ByteArray>()
            override suspend fun sendData(bytes: ByteArray) { sent.add(bytes) }
        }
        suspend fun connect(findCapable: Boolean = true, version: Long = 3, actions: Long = 9) {
            channel = Channel(peer).also { channels.add(it) }
            deck.available(channel)
            find.available(channel)
            deck.handle(channel.descriptor, DeskDeckMessage(kind = 1, version = version, actions = actions).encode())
            if (findCapable) find.handle(channel.descriptor, FindDeviceMessage(1).encode())
        }
        suspend fun sample(version: Long = 3, actions: Long = 9, outputRouteID: String = "") {
            val subscription = channel.sent.mapNotNull(DeskDeckMessage::decode).last { it.kind == 2L }.subscription
            val gib = 1_073_741_824L
            deck.handle(channel.descriptor, DeskDeckMessage(
                kind = 3, version = version, subscription = subscription, sequence = 1,
                cpuPercent = 12, memoryUsed = 8 * gib, memoryTotal = 16 * gib, thermalState = 0, actions = actions,
                memoryActive = 4 * gib, memoryWired = 2 * gib, memoryCompressed = gib,
                memoryApp = 3 * gib, memoryCached = 5 * gib, memoryFree = 3 * gib, memorySwap = 0,
                outputRouteID = outputRouteID,
                outputSupported = true, outputTarget = UUID.randomUUID().toString(),
                outputRevision = UUID.randomUUID().toString(), outputLevel = 35,
                powerState = 3, powerPercent = 72, powerSource = 2,
            ).encode())
        }
        suspend fun outputCatalog(catalogRevision: String, routes: List<DeskDeckOutputRoute>) {
            val subscription = channel.sent.mapNotNull(DeskDeckMessage::decode).last { it.kind == 2L }.subscription
            deck.handle(channel.descriptor, DeskDeckMessage(
                kind = 12, version = 5, subscription = subscription,
                page = 0, pageCount = 1, catalogRevision = catalogRevision, outputRoutes = routes,
            ).encode())
        }
        fun requests() = channel.sent.mapNotNull(FindDeviceMessage::decode).filter { it.kind == 2L }
        fun deckCommands() = channels.sumOf { c -> c.sent.mapNotNull(DeskDeckMessage::decode).count { it.kind == 4L } }
        suspend fun reply(result: FindResult) {
            val request = requests().last()
            find.handle(channel.descriptor, FindDeviceMessage(3, request.id, request.sequence, result.ordinal.toLong()).encode())
        }
        fun advance(millis: Long) {
            time += millis
            timers.filter { it.deadline <= time }.toList().forEach { it.wake.complete(Unit) }
        }
        fun close() {
            deck.stop()
            channels.forEach { deck.retired(it.descriptor); find.retired(it.descriptor) }
        }
    }

    @Composable private fun Fixture(dark: Boolean, scale: Float, width: Int, content: @Composable () -> Unit) {
        val configuration = Configuration(LocalConfiguration.current).apply {
            uiMode = (uiMode and Configuration.UI_MODE_NIGHT_MASK.inv()) or
                if (dark) Configuration.UI_MODE_NIGHT_YES else Configuration.UI_MODE_NIGHT_NO
        }
        val realDensity = LocalDensity.current.density
        val fittedDensity = minOf(realDensity, context.resources.displayMetrics.widthPixels / width.toFloat())
        CompositionLocalProvider(LocalConfiguration provides configuration) {
            AniCeTheme {
                CompositionLocalProvider(LocalDensity provides Density(fittedDensity, scale)) {
                    Surface(Modifier.fillMaxSize()) {
                        // Surface propagates its minimum width; a separate Box makes the requested viewport real.
                        Box(Modifier.fillMaxSize().safeDrawingPadding()) {
                            Box(Modifier.width(width.dp).heightIn(max = if (width >= 600) 480.dp else 720.dp)
                                .padding(12.dp)) { content() }
                        }
                    }
                }
            }
        }
    }
    private fun record(peer: DeviceIdentity) = PeerTrustRecord(peer, "local", PairingMethod.QR, 1, byteArrayOf(), active = true)
    private fun requirePreview() {
        assumeTrue(Build.HARDWARE in setOf("ranchu", "goldfish"))
        assumeTrue(context.packageName == "io.github.anisharyal09.anice.preview")
        runner.uiAutomation
    }
    private fun startActivity() = runner.startActivitySync(
        Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) as MainActivity
    private fun onMain(block: suspend () -> Unit) { runner.runOnMainSync { runBlocking { block() } } }
    private fun show(activity: MainActivity, content: @Composable () -> Unit) {
        val drawn = CountDownLatch(1)
        runner.runOnMainSync {
            activity.setContent {
                content()
                SideEffect { activity.window.decorView.postOnAnimation {
                    activity.window.decorView.postOnAnimation { drawn.countDown() }
                } }
            }
        }
        assertTrue(drawn.await(10, TimeUnit.SECONDS))
        idle()
    }
    private fun idle() { runner.waitForIdleSync(); runner.uiAutomation.waitForIdle(250, 5_000) }
    private fun root(): AccessibilityNodeInfo? {
        if (Build.VERSION.SDK_INT >= 34) runner.uiAutomation.clearCache()
        return runner.uiAutomation.rootInActiveWindow
    }
    private fun find(node: AccessibilityNodeInfo?, label: String): AccessibilityNodeInfo? {
        if (node == null) return null
        if (node.text?.toString()?.contains(label) == true || node.contentDescription?.toString()?.contains(label) == true) return node
        for (i in 0 until node.childCount) find(node.getChild(i), label)?.let { return it }
        return null
    }
    private fun findText(node: AccessibilityNodeInfo?, label: String): AccessibilityNodeInfo? {
        if (node == null) return null
        if (node.text?.toString()?.contains(label) == true) return node
        for (i in 0 until node.childCount) findText(node.getChild(i), label)?.let { return it }
        return null
    }
    private fun count(node: AccessibilityNodeInfo?, label: String): Int {
        if (node == null) return 0
        return (if (node.text?.toString() == label || node.contentDescription?.toString() == label) 1 else 0) +
            (0 until node.childCount).sumOf { count(node.getChild(it), label) }
    }
    private fun awaitControl(label: String, enabled: Boolean? = null): AccessibilityNodeInfo {
        val deadline = android.os.SystemClock.uptimeMillis() + 5_000
        do {
            val tree = root()
            // Start at visible text rather than a neighbouring star whose description contains the row label.
            (findText(tree, label) ?: find(tree, label))?.takeIf { it.isVisibleToUser }?.let { node ->
                var current: AccessibilityNodeInfo? = node
                while (current != null) {
                    if (current.isClickable) break
                    current = current.parent
                }
                val control = current ?: node
                if (enabled == null || control.isEnabled == enabled) return control
            }
            android.os.SystemClock.sleep(50)
        } while (android.os.SystemClock.uptimeMillis() < deadline)
        error("Missing deck control: $label enabled=$enabled\n${describe(root())}")
    }
    private fun click(label: String) {
        assertTrue("Cannot activate $label", awaitControl(label).performAction(AccessibilityNodeInfo.ACTION_CLICK))
        idle()
    }
    private fun reveal(label: String) {
        fun scrollable(node: AccessibilityNodeInfo?): AccessibilityNodeInfo? {
            if (node == null) return null
            if (node.isScrollable) return node
            for (i in 0 until node.childCount) scrollable(node.getChild(i))?.let { return it }
            return null
        }
        repeat(8) {
            val tree = root()
            if (find(tree, label)?.let { it.isVisibleToUser && bounds(tree).contains(bounds(it)) } == true) return
            val scroll = requireNotNull(scrollable(tree)) { "Missing scroll container for $label" }
            if (!scroll.performAction(AccessibilityNodeInfo.ACTION_SCROLL_FORWARD)) {
                error("Cannot reveal $label\n${describe(tree)}")
            }
            idle()
        }
        error("Could not reveal $label\n${describe(root())}")
    }
    private fun awaitAbsent(label: String) {
        val deadline = android.os.SystemClock.uptimeMillis() + 5_000
        do {
            if (find(root(), label) == null) return
            android.os.SystemClock.sleep(50)
        } while (android.os.SystemClock.uptimeMillis() < deadline)
        error("Deck control remained visible: $label")
    }
    private fun bounds(node: AccessibilityNodeInfo?) = Rect().also { node?.getBoundsInScreen(it) }
    private fun describe(node: AccessibilityNodeInfo?, depth: Int = 0): String {
        if (node == null || depth > 24) return ""
        return "  ".repeat(depth) + "${node.className} ${node.text} ${node.contentDescription} enabled=${node.isEnabled} clickable=${node.isClickable} actions=${node.actionList}\n" +
            (0 until node.childCount).joinToString("") { describe(node.getChild(it), depth + 1) }
    }
    private fun capture(activity: MainActivity, name: String) {
        val view = activity.window.decorView
        val bitmap = Bitmap.createBitmap(view.width, view.height, Bitmap.Config.ARGB_8888)
        val copied = CountDownLatch(1)
        var result = PixelCopy.ERROR_UNKNOWN
        PixelCopy.request(activity.window, bitmap, { result = it; copied.countDown() }, Handler(Looper.getMainLooper()))
        assertTrue(copied.await(10, TimeUnit.SECONDS))
        assertEquals(PixelCopy.SUCCESS, result)
        val file = File(context.getExternalFilesDir(null), "desk-deck-review/$name.png")
        check(file.parentFile!!.isDirectory || file.parentFile!!.mkdirs())
        file.outputStream().use { assertTrue(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) }
        bitmap.recycle()
    }
    private fun overridePreferences(name: String, values: Map<String, Any>): () -> Unit {
        val preferences = context.getSharedPreferences(name, Context.MODE_PRIVATE)
        val saved = preferences.all.filterKeys { it in values }
        fun write(next: Map<String, Any?>) {
            val edit = preferences.edit()
            values.keys.forEach { key ->
                when (val value = next[key]) {
                    null -> edit.remove(key)
                    is String -> edit.putString(key, value)
                    is Boolean -> edit.putBoolean(key, value)
                    else -> error("Unexpected fixture preference")
                }
            }
            assertTrue(edit.commit())
        }
        write(values)
        return { write(saved) }
    }
}
