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
        assertEquals((1L..9L).toSet(), kinds)
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

    @Test fun selectedAppsSortAboveUnselectedAppsWithAlphabeticalOrderWithinGroups() {
        val choices = listOf(
            NotificationAppChoice("com.zebra", "Zebra"),
            NotificationAppChoice("com.beta", "Beta"),
            NotificationAppChoice("com.charlie", "Charlie"),
            NotificationAppChoice("com.alpha", "alpha"),
        )
        val ordered = sortNotificationAppChoices(choices, setOf("com.charlie", "com.alpha"))
        assertEquals(listOf("com.alpha", "com.charlie", "com.beta", "com.zebra"), ordered.map { it.packageName })
    }

    @Test fun appSearchMatchesLabelsAndPackageNamesWithoutCaseOrWhitespaceSensitivity() {
        val apps = listOf(
            NotificationAppChoice("com.example.chat", "Chat App"),
            NotificationAppChoice("com.example.music", "Music"),
        )
        assertEquals(listOf("com.example.chat"), filterNotificationAppChoices(apps, "  CHAT ").map { it.packageName })
        assertEquals(listOf("com.example.music"), filterNotificationAppChoices(apps, "EXAMPLE.MUSIC").map { it.packageName })
        assertEquals(apps, filterNotificationAppChoices(apps, "  "))
    }

    @Test fun incomingCallOptInIncludesCallStyleFromUnselectedSystemSourcesOnly() {
        val selected = setOf("com.example.chat")
        assertTrue(notificationPackageEligible(
            "com.android.server.telecom", "io.anice", "com.example.sms", selected,
            incomingCall = true, mirrorIncomingCalls = true,
        ))
        assertFalse(notificationPackageEligible(
            "com.android.server.telecom", "io.anice", "com.example.sms", selected,
            incomingCall = true, mirrorIncomingCalls = false,
        ))
        assertFalse(notificationPackageEligible(
            "com.android.server.telecom", "io.anice", "com.example.sms", selected,
            incomingCall = false, mirrorIncomingCalls = true,
        ))
        assertFalse(notificationPackageEligible(
            "io.anice", "io.anice", "com.example.sms", selected,
            incomingCall = true, mirrorIncomingCalls = true,
        ))
        assertFalse(notificationPackageEligible(
            "com.example.sms", "io.anice", "com.example.sms", selected,
            incomingCall = true, mirrorIncomingCalls = true,
        ))
    }

    @Test fun simCallRingsAggregateAcrossActiveSubscriptions() {
        assertTrue(hasRingingPhoneCall(listOf(0, 1, 2), 1))
        assertFalse(hasRingingPhoneCall(listOf(0, 2), 1))
        assertFalse(hasRingingPhoneCall(emptyList(), 1))
    }

    @Test fun incomingCallRecognitionRequiresKnownCallStyleAndIncomingType() {
        assertTrue(isIncomingCallStyle("android.app.Notification\$CallStyle", 1))
        assertTrue(isIncomingCallStyle("androidx.core.app.NotificationCompat\$CallStyle", 1))
        assertFalse(isIncomingCallStyle("android.app.Notification\$CallStyle", 2))
        assertFalse(isIncomingCallStyle("android.app.Notification\$CallStyle", null))
        assertFalse(isIncomingCallStyle("com.example.CustomCallNotification", 1))
        assertFalse(isIncomingCallStyle(null, 1))
    }

    @Test fun incomingCallRecognitionCoversActionableSystemCallsWithoutMirroringMissedCalls() {
        assertTrue(isIncomingCallNotification(
            null, null, "call", false, listOf("Answer", "Decline"),
        ))
        assertTrue(isIncomingCallNotification(
            null, 1, null, true, emptyList(),
        ))
        assertTrue(isIncomingCallNotification(
            "android.app.Notification\$CallStyle", 1, null, false, emptyList(),
        ))
        assertTrue(isIncomingCallNotification(
            "android.app.Notification\$CallStyle", null, null, true, emptyList(),
        ))
        assertTrue(isIncomingCallNotification(
            "android.app.Notification\$CallStyle", null, null, false, listOf("Answer", "Decline"),
        ))
        assertFalse(isIncomingCallNotification(
            "android.app.Notification\$CallStyle", null, null, false, emptyList(),
        ))
        assertTrue(isIncomingCallNotification(
            null, null, "call", true, emptyList(),
        ))
        assertFalse(isIncomingCallNotification(
            null, null, "call", false, listOf("Call back", "Message"),
        ))
        assertFalse(isIncomingCallNotification(
            null, null, "call", false, listOf("Mute", "Hang up"),
        ))
        assertFalse(isIncomingCallNotification(
            null, null, "msg", true, listOf("Answer", "Decline"),
        ))
        assertFalse(isIncomingCallNotification(
            "android.app.Notification\$CallStyle", 2, "call", true, listOf("Answer", "Decline"),
        ))
    }

    @Test fun sourceAppIconsTravelOverLanOnly() {
        assertTrue(sendsSourceIcons("lan"))
        assertFalse(sendsSourceIcons("ble"))
        assertFalse(sendsSourceIcons("unknown"))
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
