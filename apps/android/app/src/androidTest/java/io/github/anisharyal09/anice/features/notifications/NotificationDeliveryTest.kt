// SPDX-License-Identifier: GPL-3.0-or-later
// Exercises notification resynchronization under capacity refusal using isolated channels and synthetic alerts.
package io.github.anisharyal09.anice.features.notifications

import android.app.Notification
import android.os.Process
import android.service.notification.StatusBarNotification
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.github.anisharyal09.anice.infrastructure.connections.ChannelDescriptor
import io.github.anisharyal09.anice.infrastructure.connections.SecuredChannel
import io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity
import io.github.anisharyal09.anice.infrastructure.session.Cbor
import io.github.anisharyal09.anice.infrastructure.session.SessionBackpressure
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.util.UUID

@RunWith(AndroidJUnit4::class)
class NotificationDeliveryTest {
    private class Channel : SecuredChannel {
        override val descriptor = ChannelDescriptor(UUID.randomUUID().toString(), "ble",
            DeviceIdentity(DeviceIdentity.newId(), "Test Mac", "macos", "test", "a".repeat(64)))
        var blocked = true
        var attempts = 0
        var refuseEnd = false
        val sent = mutableListOf<NotificationWireMessage>()
        override suspend fun sendData(bytes: ByteArray) {
            attempts++
            val message = NotificationWireMessage.decode(bytes)!!
            if (blocked || refuseEnd && message.kind == 5L) throw SessionBackpressure()
            sent += message
        }
    }

    @Test fun capacityRestorationResendsOnlyLatestActiveStateAndNeverPolls() = runBlocking {
        withContext(Dispatchers.Main) {
            val context = InstrumentationRegistry.getInstrumentation().targetContext
            val owner = NotificationMirrorController(context)
            val channel = Channel()
            val packageName = "io.github.anice.notification.fixture"
            owner.preferences.setSelected(packageName, true)
            fun alert(title: String) = StatusBarNotification(packageName, packageName, 1, null,
                Process.myUid(), Process.myPid(), 0, Notification.Builder(context, "fixture")
                    .setSmallIcon(android.R.drawable.ic_dialog_info).setContentTitle(title).build(),
                Process.myUserHandle(), System.currentTimeMillis())
            try {
                owner.accessChanged(true)
                owner.available(channel)
                owner.handle(channel.descriptor, NotificationWireMessage.of(1, Cbor.Integer(8)).encode())
                owner.notificationPosted(alert("old"))
                owner.notificationPosted(alert("latest"))
                delay(50)
                val attempts = channel.attempts
                delay(50)
                assertEquals("Capacity refusal must wait for an event", attempts, channel.attempts)
                channel.blocked = false
                owner.capacityAvailable(channel.descriptor)
                withTimeout(2000) { while (channel.sent.none { it.kind == 5L }) delay(5) }
                assertTrue(channel.sent.any { it.kind == 1L })
                val records = channel.sent.filter { it.kind == 2L }
                assertEquals(listOf("latest"), records.map { it.text(6) })
                assertTrue(records.all { it.text(0).isNotEmpty() })
                channel.blocked = true
                val record = records.single()
                val requests = List(40) { UUID.randomUUID().toString() }
                for (request in requests) {
                    owner.handle(channel.descriptor, NotificationWireMessage.of(6,
                        Cbor.Text(request), Cbor.Text(record.text(1)), Cbor.Text(record.text(2)),
                        Cbor.Integer(record.number(3)), Cbor.Integer(-1), Cbor.Text("")).encode())
                }
                delay(50)
                channel.blocked = false
                owner.capacityAvailable(channel.descriptor)
                withTimeout(2000) { while (channel.sent.count { it.kind == 7L } < 32) delay(5) }
                val results = channel.sent.filter { it.kind == 7L }
                assertEquals(requests.takeLast(32).toSet(), results.map { it.text(0) }.toSet())
                assertTrue(results.all { it.number(1) == 2L })
                channel.blocked = true
                owner.notificationRemoved(alert("latest"))
                delay(20)
                val count = channel.sent.size
                channel.blocked = false
                owner.capacityAvailable(channel.descriptor)
                withTimeout(2000) { while (channel.sent.drop(count).none { it.kind == 5L }) delay(5) }
                assertFalse(channel.sent.drop(count).any { it.kind == 2L })
            } finally {
                owner.retired(channel.descriptor)
                owner.accessChanged(false)
                owner.preferences.setSelected(packageName, false)
            }
        }
    }

    @Test fun incompleteSnapshotAndRetiredCapacityCannotCompleteOrReplayOldState() = runBlocking {
        withContext(Dispatchers.Main) {
            val context = InstrumentationRegistry.getInstrumentation().targetContext
            val owner = NotificationMirrorController(context)
            val old = Channel().apply { blocked = false; refuseEnd = true }
            try {
                owner.available(old)
                owner.handle(old.descriptor, NotificationWireMessage.of(1, Cbor.Integer(8)).encode())
                withTimeout(2000) { while (old.sent.none { it.kind == 4L }) delay(5) }
                assertFalse(old.sent.any { it.kind == 5L })
                val previous = old.attempts
                delay(50)
                assertEquals(previous, old.attempts)
                owner.retired(old.descriptor)
                old.refuseEnd = false
                owner.capacityAvailable(old.descriptor)
                delay(20)
                assertFalse(old.sent.any { it.kind == 5L })
                val fresh = Channel().apply { blocked = false }
                owner.available(fresh)
                owner.handle(fresh.descriptor, NotificationWireMessage.of(1, Cbor.Integer(8)).encode())
                withTimeout(2000) { while (fresh.sent.none { it.kind == 5L }) delay(5) }
                assertEquals(1, fresh.sent.count { it.kind == 4L })
                owner.retired(fresh.descriptor)
            } finally { owner.retired(old.descriptor) }
        }
    }
}
