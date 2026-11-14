// SPDX-License-Identifier: GPL-3.0-or-later
// Checks native receive-progress notices on isolated emulators without sending files or touching production state.
package io.github.anisharyal09.anice.features.transfer

import android.Manifest
import android.app.Notification
import android.app.NotificationManager
import android.content.pm.PackageManager
import android.os.Build
import android.os.ParcelFileDescriptor
import androidx.test.platform.app.InstrumentationRegistry
import java.util.UUID
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test

class TransferProgressNotificationTest {
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
}
