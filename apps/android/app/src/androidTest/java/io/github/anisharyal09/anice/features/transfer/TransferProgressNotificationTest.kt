// SPDX-License-Identifier: GPL-3.0-or-later
// Checks native receive-progress notices on isolated emulators without sending files or touching production state.
package io.github.anisharyal09.anice.features.transfer

import android.Manifest
import android.app.Notification
import android.app.NotificationManager
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.ParcelFileDescriptor
import android.graphics.Bitmap
import androidx.test.platform.app.InstrumentationRegistry
import io.github.anisharyal09.anice.AniCeApplication
import io.github.anisharyal09.anice.MainActivity
import io.github.anisharyal09.anice.ui.EmulatorPresentationRule
import java.io.File
import java.util.UUID
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.Rule
import org.junit.rules.TestRule

class TransferProgressNotificationTest {
    @get:Rule val presentation: TestRule = EmulatorPresentationRule()
    @Test fun receivingLargeFilesShowsNativeProgressAndCancelWithoutACompletionAlert() = runBlocking(Dispatchers.Main) {
        val runner = InstrumentationRegistry.getInstrumentation()
        val context = runner.targetContext
        assumeTrue(Build.HARDWARE in setOf("ranchu", "goldfish"))
        assumeTrue(context.packageName.startsWith("io.github.anisharyal09.anice.preview"))
        val hadPermission = Build.VERSION.SDK_INT < 33 ||
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        if (!hadPermission) {
            ParcelFileDescriptor.AutoCloseInputStream(runner.uiAutomation.executeShellCommand(
                "pm grant ${context.packageName} android.permission.POST_NOTIFICATIONS"
            )).use { it.readBytes() }
        }
        val manager = context.getSystemService(NotificationManager::class.java)
        val owner = TransferController(dispatcher = Dispatchers.Main.immediate)
        val native = TransferNotification(context, owner, isForeground = { true })
        val total = 512L * 1024 * 1024
        val file = TransferFile(UUID.randomUUID().toString(), "large.bin", total, ByteArray(32))
        val batch = TransferBatch(UUID.randomUUID().toString(), listOf(file), total, "Test Mac")
        try {
            owner.receiving = true
            owner.backgroundAllowed = true
            owner.currentBatch = batch
            val positions = listOf(0L, total / 4, total / 2, total - 1)
            assertEquals(4, positions.size)
            for (bytes in positions) {
                owner.state = TransferState.Transferring(batch, 1, file.name, bytes, total, bytes, 0.0)
                native.update(force = true)
                val expected = (bytes.toDouble() / total * 1000).toInt()
                val notice = withTimeout(5000) {
                    var found = manager.activeNotifications.singleOrNull { it.id == TransferNotification.NOTIFICATION_ID }
                    while (found?.notification?.extras?.getInt(Notification.EXTRA_PROGRESS) != expected) {
                        delay(50)
                        found = manager.activeNotifications.singleOrNull { it.id == TransferNotification.NOTIFICATION_ID }
                    }
                    requireNotNull(found).notification
                }
                assertEquals("Receiving from Test Mac", notice.extras.getString(Notification.EXTRA_TITLE))
                assertEquals(1000, notice.extras.getInt(Notification.EXTRA_PROGRESS_MAX))
                assertFalse(notice.extras.getBoolean(Notification.EXTRA_PROGRESS_INDETERMINATE))
                assertEquals(Notification.CATEGORY_PROGRESS, notice.category)
                assertEquals(Notification.VISIBILITY_PRIVATE, notice.visibility)
                assertTrue(notice.flags and Notification.FLAG_ONGOING_EVENT != 0)
                assertEquals("Cancel transfer", notice.actions.single().title.toString())
                assertTrue(notice.extras.getCharSequence(Notification.EXTRA_BIG_TEXT)?.contains(file.name) == true)
                assertNull(notice.sound)
            }
            owner.state = TransferState.Completed(batch.id, 1, total)
            native.update(force = true)
            withTimeout(5000) {
                while (manager.activeNotifications.any { it.id == TransferNotification.NOTIFICATION_ID }) delay(50)
            }
            assertFalse(owner.isBusy)
        } finally {
            // Revoking POST_NOTIFICATIONS would kill this instrumentation process, so an isolated
            // preview emulator keeps the granted permission after the test.
            owner.dismiss()
            manager.cancel(TransferNotification.NOTIFICATION_ID)
        }
    }

    @Test fun nativeProgressRefreshesReplacementActionsAndReviewOpensOnlyTheOriginalJob() = runBlocking {
        val runner = InstrumentationRegistry.getInstrumentation()
        val context = runner.targetContext
        assumeTrue(Build.HARDWARE in setOf("ranchu", "goldfish"))
        assumeTrue(context.packageName == "io.github.anisharyal09.anice.preview")
        if (Build.VERSION.SDK_INT >= 33 && context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED) {
            ParcelFileDescriptor.AutoCloseInputStream(runner.uiAutomation.executeShellCommand(
                "pm grant ${context.packageName} android.permission.POST_NOTIFICATIONS")).use { it.readBytes() }
        }
        val app = context.applicationContext as AniCeApplication
        val owner = app.transfer
        val manager = context.getSystemService(NotificationManager::class.java)
        lateinit var native: TransferNotification
        fun batch(name: String): TransferBatch {
            val file = TransferFile(UUID.randomUUID().toString(), name, 512L * 1024 * 1024, ByteArray(32))
            return TransferBatch(UUID.randomUUID().toString(), listOf(file), file.size, "Preview Mac")
        }
        fun set(batch: TransferBatch, receiving: Boolean) {
            runner.runOnMainSync {
                owner.receiving = receiving
                owner.currentBatch = batch
                owner.backgroundAllowed = true
                owner.state = TransferState.Transferring(batch, 1, batch.files[0].name,
                    batch.totalBytes / 2, batch.totalBytes, batch.totalBytes / 2, 0.0)
            }
        }
        suspend fun notice(name: String): Notification = withTimeout(5_000) {
            while (true) {
                val found = manager.activeNotifications.singleOrNull { it.id == TransferNotification.NOTIFICATION_ID }?.notification
                if (found?.extras?.getCharSequence(Notification.EXTRA_BIG_TEXT)?.contains(name) == true) return@withTimeout found
                delay(50)
            }
            @Suppress("UNREACHABLE_CODE") error("No progress notice")
        }
        val activity = runner.startActivitySync(Intent(context, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) as MainActivity
        try {
            runner.runOnMainSync {
                owner.dismiss()
                native = TransferNotification(context, owner, isForeground = { true })
            }
            val first = batch("Review receive.bin")
            set(first, true)
            runner.runOnMainSync { native.update(force = true) }
            val old = notice(first.files[0].name)
            val replacement = batch("Review send.bin")
            set(replacement, false)
            runner.runOnMainSync { native.update() }
            val current = notice(replacement.files[0].name)
            assertEquals("Sending to Preview Mac", current.extras.getString(Notification.EXTRA_TITLE))
            old.actions.single().actionIntent.send()
            delay(200)
            assertEquals(replacement.id, owner.currentBatch?.id)
            current.contentIntent.send()
            runner.waitForIdleSync()
            try {
                withTimeout(5_000) {
                    while (runner.uiAutomation.rootInActiveWindow?.let { hasText(it, "Sending Review send.bin to Preview Mac") } != true) delay(50)
                }
            } catch (error: TimeoutCancellationException) {
                capture("transfer-review-navigation-failure")
                throw AssertionError("Review did not open transfer: requested=${owner.openWorkspaceRequest}, busy=${owner.isBusy}", error)
            }
            capture("transfer-review-current-job")
            assertEquals(replacement.id, owner.currentBatch?.id)
            runner.runOnMainSync { owner.workspaceOpened() }
            old.contentIntent.send()
            delay(100)
            assertFalse(owner.openWorkspaceRequest)
            current.actions.single().actionIntent.send()
            withTimeout(5_000) { while (owner.state != TransferState.Cancelled) delay(50) }
            assertNull(owner.currentBatch)
            runner.runOnMainSync { native.update(force = true) }
            withTimeout(5_000) {
                while (manager.activeNotifications.any { it.id == TransferNotification.NOTIFICATION_ID }) delay(50)
            }
        } finally {
            runner.runOnMainSync { owner.dismiss(); owner.workspaceOpened() }
            manager.cancel(TransferNotification.NOTIFICATION_ID)
            runner.runOnMainSync { activity.finish() }
        }
    }

    @Test fun nativeShadeRendersExpandedFileContextAcrossThemesAndTextSizes() = runBlocking {
        val runner = InstrumentationRegistry.getInstrumentation()
        val context = runner.targetContext
        assumeTrue(Build.HARDWARE in setOf("ranchu", "goldfish"))
        assumeTrue(context.packageName == "io.github.anisharyal09.anice.preview")
        if (Build.VERSION.SDK_INT >= 33 && context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED) {
            shell("pm grant ${context.packageName} android.permission.POST_NOTIFICATIONS")
        }
        val night = shell("settings get secure ui_night_mode").trim()
        val scale = shell("settings get system font_scale").trim()
        val owner = TransferController(dispatcher = Dispatchers.Main.immediate)
        val native = TransferNotification(context, owner)
        val manager = context.getSystemService(NotificationManager::class.java)
        val file = TransferFile(UUID.randomUUID().toString(), "Preview document with a long name.pdf", 512L * 1024 * 1024, ByteArray(32))
        val batch = TransferBatch(UUID.randomUUID().toString(), listOf(file), file.size, "Preview Mac")
        try {
            for (dark in listOf(false, true)) for (size in listOf(0.8f, 1.2f)) {
                shell("cmd uimode night ${if (dark) "yes" else "no"}")
                shell("settings put system font_scale $size")
                runner.runOnMainSync {
                    owner.currentBatch = batch
                    owner.receiving = true
                    owner.backgroundAllowed = true
                    owner.state = TransferState.Transferring(batch, 1, file.name, file.size / 2, file.size, file.size / 2, 0.0)
                    native.update(force = true)
                }
                delay(150)
                shell("cmd statusbar expand-notifications")
                runner.uiAutomation.waitForIdle(250, 5_000)
                withTimeout(5_000) {
                    while (runner.uiAutomation.rootInActiveWindow?.let { hasText(it, "Receiving from Preview Mac") } != true) delay(50)
                }
                fun expand(node: android.view.accessibility.AccessibilityNodeInfo?): Boolean {
                    if (node == null) return false
                    if (node.text?.toString()?.contains("Receiving from Preview Mac") == true) {
                        var current: android.view.accessibility.AccessibilityNodeInfo? = node
                        repeat(6) {
                            val container = current
                            fun button(child: android.view.accessibility.AccessibilityNodeInfo?): android.view.accessibility.AccessibilityNodeInfo? {
                                if (child == null) return null
                                if (child.contentDescription?.toString()?.contains("Expand") == true) return child
                                for (index in 0 until child.childCount) button(child.getChild(index))?.let { return it }
                                return null
                            }
                            button(container)?.let { return it.performAction(android.view.accessibility.AccessibilityNodeInfo.ACTION_CLICK) }
                            current = container?.parent
                        }
                    }
                    return (0 until node.childCount).any { expand(node.getChild(it)) }
                }
                expand(runner.uiAutomation.rootInActiveWindow)
                runner.uiAutomation.waitForIdle(250, 5_000)
                withTimeout(5_000) {
                    while (runner.uiAutomation.rootInActiveWindow?.let { hasText(it, "Preview document with a long name.pdf") } != true) delay(50)
                }
                capture("transfer-shade-${if (dark) "dark" else "light"}-${(size * 100).toInt()}")
                shell("cmd statusbar collapse")
            }
        } finally {
            runner.runOnMainSync { owner.dismiss() }
            manager.cancel(TransferNotification.NOTIFICATION_ID)
            shell("cmd statusbar collapse")
            shell("cmd uimode night " + when (night) { "2" -> "yes"; "1" -> "no"; else -> "auto" })
            if (scale == "null") shell("settings delete system font_scale") else shell("settings put system font_scale $scale")
        }
    }

    private fun shell(command: String): String = ParcelFileDescriptor.AutoCloseInputStream(
        InstrumentationRegistry.getInstrumentation().uiAutomation.executeShellCommand(command)
    ).use { String(it.readBytes()) }

    private fun hasText(node: android.view.accessibility.AccessibilityNodeInfo?, text: String): Boolean {
        if (node == null) return false
        if (node.text?.toString()?.contains(text) == true || node.contentDescription?.toString()?.contains(text) == true) return true
        return (0 until node.childCount).any { hasText(node.getChild(it), text) }
    }

    private fun capture(name: String) {
        val runner = InstrumentationRegistry.getInstrumentation()
        val bitmap = requireNotNull(runner.uiAutomation.takeScreenshot())
        val file = File(runner.targetContext.getExternalFilesDir(null), "notification-review/$name.png")
        check(file.parentFile!!.isDirectory || file.parentFile!!.mkdirs())
        file.outputStream().use { assertTrue(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) }
        bitmap.recycle()
    }
}
