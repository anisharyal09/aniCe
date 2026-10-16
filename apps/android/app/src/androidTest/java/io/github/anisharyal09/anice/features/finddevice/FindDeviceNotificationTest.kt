// SPDX-License-Identifier: GPL-3.0-or-later
// Verifies native ringing, Stop/delete callbacks, independent expiry and rejection of unadmitted service intents.
package io.github.anisharyal09.anice.features.finddevice

import android.app.NotificationManager
import android.content.Intent
import android.media.AudioManager
import android.os.SystemClock
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.github.anisharyal09.anice.AniCeApplication
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.util.UUID

@RunWith(AndroidJUnit4::class)
class FindDeviceNotificationTest {
    private val app get() = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as AniCeApplication

    @Test fun stopAndNativeDeleteReleaseAudioWithoutChangingVibrateModeOrAlarmVolume() = runBlocking(Dispatchers.Main) {
        assumeTrue(app.findDeviceNotification.permitted())
        val native = app.findDeviceNotification
        val manager = app.getSystemService(NotificationManager::class.java)
        val audio = app.getSystemService(AudioManager::class.java)
        val mode = audio.ringerMode
        val volume = audio.getStreamVolume(AudioManager.STREAM_ALARM)
        for (ordinarySwipe in listOf(false, true)) {
            val id = "find-device-" + UUID.randomUUID()
            try {
                assertEquals(FindResult.SUBMITTED, native.post(id, "Paired Mac"))
                val ring = requireNotNull(native.request(id))
                assertTrue(ring.started)
                val delivered = withTimeout(5000) {
                    var found = manager.activeNotifications.singleOrNull { it.id == FindDeviceNotification.ID }
                    while (found == null) { delay(50); found = manager.activeNotifications.singleOrNull { it.id == FindDeviceNotification.ID } }
                    found
                }
                val notification = delivered.notification
                assertEquals(id, notification.extras.getString(FindDeviceNotification.EXTRA_IDENTIFIER))
                assertNotNull(notification.deleteIntent)
                assertEquals(notification.deleteIntent, notification.actions.single().actionIntent)
                assertTrue(notification.timeoutAfter in 1L..60000L)
                assertFalse(audio.isStreamMute(AudioManager.STREAM_ALARM))
                delay(1500)
                assertSame(ring, native.request(id))
                // The system sends deleteIntent on swipe/Clear all; send the exact native broadcast token.
                (if (ordinarySwipe) notification.deleteIntent else notification.actions.single().actionIntent).send()
                withTimeout(5000) { while (native.request(id) != null || manager.activeNotifications.any { it.id == FindDeviceNotification.ID }) delay(50) }
                assertEquals(mode, audio.ringerMode)
                assertEquals(volume, audio.getStreamVolume(AudioManager.STREAM_ALARM))
            } finally { native.clear(id) }
        }
    }
    @Test fun nativeTimeoutRunsFullSixtySecondsAndDoesNotExtendForDuplicateServiceStarts() = runBlocking(Dispatchers.Main) {
        assumeTrue("Requires an uninterrupted device; opt in with -e findDeviceTimeout true",
            InstrumentationRegistry.getArguments().getString("findDeviceTimeout") == "true")
        assumeTrue(app.findDeviceNotification.permitted())
        val native = app.findDeviceNotification
        val audio = app.getSystemService(AudioManager::class.java)
        val mode = audio.ringerMode
        val volume = audio.getStreamVolume(AudioManager.STREAM_ALARM)
        val id = "find-device-" + UUID.randomUUID()
        val start = SystemClock.elapsedRealtime()
        try {
            assertEquals(FindResult.SUBMITTED, native.post(id, "Paired Mac"))
            val ring = requireNotNull(native.request(id))
            assertTrue(ring.started)
            delay(1500)
            app.startService(Intent(app, FindDeviceRingService::class.java).putExtra(FindDeviceNotification.EXTRA_IDENTIFIER, id))
            assertEquals(FindResult.BUSY, native.post("find-device-" + UUID.randomUUID(), "Other device"))
            withTimeout(63000) { while (native.request(id) != null) delay(100) }
            val elapsed = SystemClock.elapsedRealtime() - start
            assertTrue("Native expiry ended early: $elapsed ms", elapsed >= 59000)
            val manager = app.getSystemService(NotificationManager::class.java)
            withTimeout(3000) { while (manager.activeNotifications.any { it.id == FindDeviceNotification.ID }) delay(50) }
            assertEquals(mode, audio.ringerMode)
            assertEquals(volume, audio.getStreamVolume(AudioManager.STREAM_ALARM))
            val next = "find-device-" + UUID.randomUUID()
            try { assertEquals(FindResult.SUBMITTED, native.post(next, "Paired Mac")) } finally { native.clear(next) }
        } finally { native.clear(id) }
    }
    @Test fun unadmittedServiceIntentCannotStartRinging() = runBlocking(Dispatchers.Main) {
        app.startService(Intent(app, FindDeviceRingService::class.java).putExtra(FindDeviceNotification.EXTRA_IDENTIFIER, "stale-unadmitted"))
        delay(500)
        assertNull(app.findDeviceNotification.request("stale-unadmitted"))
    }
}
