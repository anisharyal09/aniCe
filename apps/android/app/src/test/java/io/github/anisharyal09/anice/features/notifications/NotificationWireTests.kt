// SPDX-License-Identifier: GPL-3.0-or-later
// Verifies notification DATA fixtures, field bounds and Android app filtering.
package io.github.anisharyal09.anice.features.notifications

import io.github.anisharyal09.anice.infrastructure.session.Cbor
import io.github.anisharyal09.anice.infrastructure.session.SessionException
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class NotificationWireTests {
    private fun hex(value: String) = value.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
    private fun fixtures(name: String) = JSONObject(
        javaClass.classLoader!!.getResource("notifications/notification-vectors.json")!!.readText()
    ).getJSONArray(name)

    @Test fun sharedFixturesStayCanonicalAndRejectMalformedRecords() {
        val valid = fixtures("valid")
        val invalid = fixtures("invalid")
        assertTrue(valid.length() >= 12)
        assertTrue(invalid.length() >= 15)
        val kinds = mutableSetOf<Long>()
        for (index in 0 until valid.length()) {
            val row = valid.getJSONObject(index)
            val bytes = hex(row.getString("bytesHex"))
            val message = NotificationWireMessage.decode(bytes)!!
            assertArrayEquals(bytes, message.encode())
            if (row.has("kind")) kinds += row.getLong("kind")
        }
        assertEquals((1L..8L).toSet(), kinds)
        for (index in 0 until invalid.length()) {
            val row = invalid.getJSONObject(index)
            val name = row.getString("name")
            val bytes = hex(row.getString("bytesHex"))
            if (name == "wrong-tag" || name == "record-over-limit") {
                assertNull(name, NotificationWireMessage.decode(bytes))
            } else {
                try {
                    NotificationWireMessage.decode(bytes)
                    fail(name)
                } catch (_: NotificationWireException) {
                } catch (_: SessionException) {
                }
            }
        }
    }

    @Test fun maximumNotificationFitsStandardDataRecord() {
        val actions = Cbor.Array((0L until NotificationWireMessage.MAX_ACTIONS).map { index ->
            Cbor.Array(listOf(Cbor.Integer(index), Cbor.Text("A".repeat(48)), Cbor.Text("R".repeat(48))))
        })
        val row = NotificationWireMessage.of(
            2, Cbor.Text(""), Cbor.Text("a".repeat(64)), Cbor.Text("01234567-89ab-4cde-8fab-0123456789ab"),
            Cbor.Integer(NotificationWireMessage.MAX_SEQUENCE), Cbor.Text("p".repeat(255)), Cbor.Text("a".repeat(128)),
            Cbor.Text("t".repeat(512)), Cbor.Text("b".repeat(1024)), actions,
        ).encode()
        assertTrue(row.size <= 4000)
        assertNotNull(NotificationWireMessage.decode(row))
    }

    @Test fun appFilteringExcludesAniCeSmsAndUnselectedPackages() {
        val selected = setOf("com.example.mail", "com.example.chat", "com.example.sms")
        assertTrue(notificationPackageEligible("com.example.mail", "io.anice", "com.example.sms", selected))
        assertFalse(notificationPackageEligible("io.anice", "io.anice", "com.example.sms", selected))
        assertFalse(notificationPackageEligible("com.example.sms", "io.anice", "com.example.sms", selected))
        assertFalse(notificationPackageEligible("com.example.other", "io.anice", "com.example.sms", selected))
    }

    @Test fun utf8TruncationDoesNotSplitCodePoints() {
        assertEquals("a😀", notificationText("a😀é", 5))
        assertEquals("", notificationText("😀", 3))
        val bad = NotificationWireMessage.of(
            7, Cbor.Text("21234567-89ab-4cde-8fab-0123456789ab"), Cbor.Integer(4),
        )
        try {
            bad.encode()
            fail("invalid result code")
        } catch (_: NotificationWireException) {
        }
        assertNull(NotificationWireMessage.decode(ByteArray(4001)))
    }
}
