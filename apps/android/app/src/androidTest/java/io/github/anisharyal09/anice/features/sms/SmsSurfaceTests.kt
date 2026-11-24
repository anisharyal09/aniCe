// SPDX-License-Identifier: GPL-3.0-or-later
// Checks SMS receiver boundaries and isolated native SIM-permission recovery controls.
package io.github.anisharyal09.anice.features.sms

import android.Manifest
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.provider.Telephony
import android.content.res.Configuration
import android.os.Build
import android.graphics.Bitmap
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
import io.github.anisharyal09.anice.ui.EmulatorPresentationRule
import io.github.anisharyal09.anice.ui.theme.AniCeTheme
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SmsSurfaceTests {
    @get:Rule val presentation: org.junit.rules.TestRule = EmulatorPresentationRule()

    @Test fun simPermissionHasItsOwnAccessibleActionAndGrantedRowsStayQuiet() {
        val runner = InstrumentationRegistry.getInstrumentation()
        assumeTrue(Build.HARDWARE in setOf("ranchu", "goldfish"))
        assumeTrue(runner.targetContext.packageName == "io.github.anisharyal09.anice.preview")
        runner.uiAutomation
        val activity = runner.startActivitySync(Intent(runner.targetContext, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) as MainActivity
        val allowed = mutableStateOf(false)
        val showGranted = mutableStateOf(false)
        val refused = mutableStateOf(false)
        var requests = 0
        var settings = 0
        try {
            for (dark in listOf(false, true)) {
                for (scale in listOf(0.8f, 1.2f)) {
                    val drawn = CountDownLatch(1)
                    runner.runOnMainSync {
                        allowed.value = false; showGranted.value = false; refused.value = false
                        activity.setContent {
                            val configuration = Configuration(LocalConfiguration.current).apply {
                                uiMode = (uiMode and Configuration.UI_MODE_NIGHT_MASK.inv()) or
                                    if (dark) Configuration.UI_MODE_NIGHT_YES else Configuration.UI_MODE_NIGHT_NO
                            }
                            val density = LocalDensity.current.density
                            CompositionLocalProvider(LocalConfiguration provides configuration) {
                                AniCeTheme {
                                    CompositionLocalProvider(LocalDensity provides Density(density, scale)) {
                                        Surface(Modifier.fillMaxSize()) {
                                            Column(Modifier.safeDrawingPadding().widthIn(max = 300.dp)
                                                .fillMaxWidth().padding(12.dp)) {
                                                SmsSimPermissionRow(
                                                    allowed = allowed.value,
                                                    showGranted = showGranted.value,
                                                    refused = refused.value,
                                                    request = { requests++ },
                                                    openSettings = { settings++ },
                                                )
                                            }
                                        }
                                    }
                                }
                            }
                            SideEffect { activity.window.decorView.postOnAnimation {
                                activity.window.decorView.postOnAnimation { drawn.countDown() }
                            } }
                        }
                    }
                    assertTrue(drawn.await(10, TimeUnit.SECONDS))
                    val action = awaitNode("Allow SIM selection")
                    val bounds = android.graphics.Rect().also(action::getBoundsInScreen)
                    assertTrue(bounds.height() >= (48 * activity.resources.displayMetrics.density).toInt())
                    capture(activity, "sim-missing-${if (dark) "dark" else "light"}-${(scale * 100).toInt()}")
                    val before = requests
                    assertTrue(action.performAction(AccessibilityNodeInfo.ACTION_CLICK))
                    idle()
                    assertEquals(before + 1, requests)
                    assertEquals(0, settings)
                    assertNull(find(root(), "Open Messages setup"))
                    runner.runOnMainSync { refused.value = true }
                    val settingsBefore = settings
                    assertTrue(awaitNode("Open app settings").performAction(AccessibilityNodeInfo.ACTION_CLICK))
                    idle()
                    assertEquals(settingsBefore + 1, settings)
                    assertEquals(before + 1, requests)
                    capture(activity, "sim-denied-${if (dark) "dark" else "light"}-${(scale * 100).toInt()}")
                    runner.runOnMainSync { allowed.value = true }
                    idle()
                    awaitAbsent("SIM selection")
                    assertNull(find(root(), "Allow SIM selection"))
                    runner.runOnMainSync { showGranted.value = true }
                    awaitNode("SIM selection")
                    awaitNode("Allowed")
                    awaitNode("Phone state access: choose an active SIM for SMS replies.")
                    assertNull(find(root(), "Allow SIM selection"))
                    capture(activity, "sim-permission-${if (dark) "dark" else "light"}-${(scale * 100).toInt()}")
                    settings = 0
                }
            }
        } finally {
            runner.runOnMainSync { activity.finish() }
        }
    }
    @Test fun receivedBroadcastRequiresSystemPermissionAndStatusReceiverStaysInternal() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val receiver = ComponentName(context, SmsReceiver::class.java)
        val info = context.packageManager.getReceiverInfo(receiver, 0)
        assertTrue(info.exported)
        assertEquals(Manifest.permission.BROADCAST_SMS, info.permission)
        val handlers = context.packageManager.queryBroadcastReceivers(
            Intent(Telephony.Sms.Intents.SMS_RECEIVED_ACTION).setPackage(context.packageName), 0)
        assertEquals(listOf(receiver.className), handlers.map { it.activityInfo.name })
        val status = context.packageManager.getReceiverInfo(ComponentName(context, SmsStatusReceiver::class.java), 0)
        assertFalse(status.exported)
    }

    @Test fun platformDecoderAcceptsStatusReportIndicationWithoutChangingText() {
        // SMS-DELIVER, +1555, GSM7 "hello", fixed service-centre timestamp; TP-SRI is set.
        val hex = "00240491515500006201910000000005E8329BFD06"
        val pdu = hex.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
        val intent = Intent(Telephony.Sms.Intents.SMS_RECEIVED_ACTION)
            .putExtra("format", "3gpp").putExtra("pdus", arrayOf(pdu))
        val messages = Telephony.Sms.Intents.getMessagesFromIntent(intent)
        assertEquals(1, messages.size)
        assertEquals("hello", messages.single().messageBody)
        assertEquals("+1555", messages.single().originatingAddress)
        assertNotNull(smsReceivedEvent(messages.map { SmsReceivedPart(it.originatingAddress, it.timestampMillis, it.messageBody) }))
    }

    @Test fun smsPermissionsAreDeclared() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val declared = context.packageManager.getPackageInfo(context.packageName, PackageManager.GET_PERMISSIONS)
            .requestedPermissions?.toSet().orEmpty()
        assertTrue(declared.containsAll(listOf(Manifest.permission.RECEIVE_SMS, Manifest.permission.READ_SMS,
            Manifest.permission.SEND_SMS, Manifest.permission.READ_PHONE_STATE)))
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

    private fun awaitNode(label: String): AccessibilityNodeInfo {
        val deadline = android.os.SystemClock.uptimeMillis() + 5000
        while (android.os.SystemClock.uptimeMillis() < deadline) {
            find(root(), label)?.let { node ->
                var action: AccessibilityNodeInfo? = node
                while (action != null) {
                    if (action.isClickable) return action
                    action = action.parent
                }
                return node
            }
            android.os.SystemClock.sleep(50)
        }
        error("Missing SIM-permission control: $label")
    }

    private fun idle() {
        val runner = InstrumentationRegistry.getInstrumentation()
        runner.waitForIdleSync()
        runner.uiAutomation.waitForIdle(250, 5000)
    }

    private fun awaitAbsent(label: String) {
        val deadline = android.os.SystemClock.uptimeMillis() + 5000
        while (android.os.SystemClock.uptimeMillis() < deadline) {
            if (find(root(), label) == null) return
            android.os.SystemClock.sleep(50)
        }
        error("SIM-permission control remained visible: $label")
    }

    private fun capture(activity: MainActivity, name: String) {
        val runner = InstrumentationRegistry.getInstrumentation()
        val view = activity.window.decorView
        val bitmap = Bitmap.createBitmap(view.width, view.height, Bitmap.Config.ARGB_8888)
        val latch = CountDownLatch(1)
        var result = PixelCopy.ERROR_UNKNOWN
        PixelCopy.request(activity.window, bitmap, { result = it; latch.countDown() }, Handler(Looper.getMainLooper()))
        assertTrue(latch.await(10, TimeUnit.SECONDS))
        assertEquals(PixelCopy.SUCCESS, result)
        val file = File(runner.targetContext.getExternalFilesDir(null), "sms-review/$name.png")
        check(file.parentFile!!.isDirectory || file.parentFile!!.mkdirs())
        file.outputStream().use { assertTrue(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) }
        bitmap.recycle()
    }
}
