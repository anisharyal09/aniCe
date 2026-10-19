// SPDX-License-Identifier: GPL-3.0-or-later
// Probes shared SMS relay fixtures and strict canonical validation.
package io.github.anisharyal09.anice.features.sms

import io.github.anisharyal09.anice.infrastructure.session.*
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class SmsWireTests {
    private fun fixtures(name: String) = JSONObject(javaClass.classLoader!!.getResource("sms/sms-vectors.json")!!.readText()).getJSONArray(name)
    private fun hex(text: String) = text.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
    private fun request() = UUID.randomUUID().toString()
    private fun stream() = UUID.randomUUID().toString()
    private fun digest(text: String) = java.security.MessageDigest.getInstance("SHA-256").digest(text.toByteArray(Charsets.UTF_8))

    @Test fun sharedFixturesStayCanonicalWithinInventoryFloors() {
        val good = fixtures("valid")
        val bad = fixtures("invalid")
        assertTrue(good.length() >= 55)
        assertTrue(bad.length() >= 85)
        val kinds = mutableSetOf<Long>()
        for (i in 0 until good.length()) {
            val row = good.getJSONObject(i)
            val bytes = hex(row.getString("bytesHex"))
            val message = SmsWireMessage.decode(bytes)!!
            assertArrayEquals(bytes, message.encode())
            assertEquals(row.getInt("kind").toLong(), message.kind)
            kinds += message.kind
        }
        assertEquals((1L..18L).toSet(), kinds)
        for (i in 0 until bad.length()) {
            val row = bad.getJSONObject(i)
            val name = row.getString("name")
            val bytes = hex(row.getString("bytesHex"))
            if (name == "wrong-tag") { assertNull(SmsWireMessage.decode(bytes)); continue }
            try { SmsWireMessage.decode(bytes); fail(name) } catch (_: SmsWireException) {} catch (_: SessionException) {}
        }
        assertNull(SmsWireMessage.decode(SessionCbor.encode(Cbor.Array(listOf(Cbor.Text("aniCe other"), Cbor.Integer(1))))))
    }

    @Test fun everyKindRoundTripsAtDocumentedBounds() {
        val id = request()
        val messageId = "sms:9"
        val rows = listOf(
            SmsWireMessage.of(1, number(24576), number(8), number(50), number(50)),
            SmsWireMessage.of(2, text(id)),
            SmsWireMessage.of(3, text(id), text("42"), text("+15551234567"), text("s".repeat(160)), number(9007199254740991L), number(0)),
            SmsWireMessage.of(4, text(id), number(6)),
            SmsWireMessage.of(5, text(id), text("addr:+15551234567"), number(9007199254740991L), text("live:" + "a".repeat(32)), number(50)),
            SmsWireMessage.of(6, text(stream()), text(""), text("live:" + "b".repeat(32)), text("42"), text("+15551234567"), number(0), number(1), flag(true), number(24576), number(8), data(digest("x"))),
            SmsWireMessage.of(7, text(stream()), number(7), data(ByteArray(3072))),
            SmsWireMessage.of(8, text(stream())),
            SmsWireMessage.of(9, text(stream()), number(0)),
            SmsWireMessage.of(10, text(id), number(0), number(0), text("")),
            SmsWireMessage.of(11, text(id), text("42"), text("+15551234567"), number(24576), number(8), data(digest("x")), number(2147483647L)),
            SmsWireMessage.of(12, text(id), number(0), data(byteArrayOf(1))),
            SmsWireMessage.of(13, text(id)),
            SmsWireMessage.of(14, text(id), number(0), text(messageId), number(9007199254740991L)),
            SmsWireMessage.of(15, text(id)),
            SmsWireMessage.of(16, text(id), number(0), Cbor.Array(listOf(Cbor.Array(listOf(number(0), number(0), text(""), flag(true)))))),
            SmsWireMessage.of(17, text(id), text("otp"), number(0), text(""), number(50)),
            SmsWireMessage.of(18, text(id), number(0), number(9007199254740991L), text("mms:7")),
        )
        for (row in rows) assertArrayEquals(row.encode(), SmsWireMessage.decode(row.encode())!!.encode())
        assertEquals((1L..18L).toSet(), rows.map { it.kind }.toSet())
    }

    @Test fun strictValidationRejectsSemanticViolations() {
        fun rejected(name: String, row: SmsWireMessage) {
            try { row.encode(); fail(name) } catch (_: SmsWireException) {}
        }
        val id = request()
        val stream = stream()
        val digest = digest("x")
        rejected("capability-floor", SmsWireMessage.of(1, number(24575), number(8), number(50), number(50)))
        rejected("request-empty", SmsWireMessage.of(2, text("")))
        rejected("request-uppercase", SmsWireMessage.of(2, text(id.uppercase())))
        rejected("thread-empty", SmsWireMessage.of(3, text(id), text(""), text("+1"), text(""), number(0), number(0)))
        rejected("address-long", SmsWireMessage.of(3, text(id), text("1"), text("a".repeat(65)), text(""), number(0), number(0)))
        rejected("result-out-of-range", SmsWireMessage.of(4, text(id), number(7)))
        rejected("limit-zero", SmsWireMessage.of(5, text(id), text("1"), number(0), text(""), number(0)))
        rejected("cursor-bogus", SmsWireMessage.of(5, text(id), text("1"), number(0), text("bogus"), number(1)))
        rejected("direction-2", SmsWireMessage.of(6, text(stream), text(""), text("sms:1"), text("1"), text("+1"), number(0), number(2), flag(false), number(1), number(1), data(digest)))
        rejected("unread-int", SmsWireMessage.of(6, text(stream), text(""), text("sms:1"), text("1"), text("+1"), number(0), number(0), number(1), number(1), number(1), data(digest)))
        rejected("fragment-math", SmsWireMessage.of(6, text(stream), text(""), text("sms:1"), text("1"), text("+1"), number(0), number(0), flag(false), number(3073), number(1), data(digest)))
        rejected("digest-short", SmsWireMessage.of(6, text(stream), text(""), text("sms:1"), text("1"), text("+1"), number(0), number(0), flag(false), number(5), number(1), data(ByteArray(31))))
        rejected("live-short", SmsWireMessage.of(6, text(stream), text(""), text("live:" + "a".repeat(31)), text("1"), text("+1"), number(0), number(0), flag(false), number(5), number(1), data(digest)))
        rejected("fragment-empty", SmsWireMessage.of(7, text(stream), number(0), data(ByteArray(0))))
        rejected("fragment-overflow", SmsWireMessage.of(7, text(stream), number(0), data(ByteArray(3073))))
        rejected("fragment-index", SmsWireMessage.of(7, text(stream), number(8), data(byteArrayOf(1))))
        rejected("result-7", SmsWireMessage.of(9, text(stream), number(7)))
        rejected("next-overflow", SmsWireMessage.of(10, text(id), number(0), number(9007199254740992L), text("")))
        rejected("send-math", SmsWireMessage.of(11, text(id), text("1"), text("+1"), number(24577), number(9), data(digest), number(0)))
        rejected("send-subscription-overflow", SmsWireMessage.of(11, text(id), text("1"), text("+1"), number(5), number(1), data(digest), number(2147483648L)))
        rejected("send-result-id-on-failure", SmsWireMessage.of(14, text(id), number(5), text("sms:10"), number(0)))
        rejected("send-result-bad-id", SmsWireMessage.of(14, text(id), number(0), text("mms:"), number(0)))
        rejected("sim-label-long", SmsWireMessage.of(16, text(id), number(0), Cbor.Array(listOf(Cbor.Array(listOf(number(1), number(0), text("x".repeat(41)), flag(true)))))))
        rejected("sim-entry-shape", SmsWireMessage.of(16, text(id), number(0), Cbor.Array(listOf(Cbor.Array(listOf(number(1), number(0), text("a"), flag(true), number(0)))))))
        rejected("search-query-short", SmsWireMessage.of(17, text(id), text("a"), number(0), text(""), number(10)))
        rejected("unknown-kind", SmsWireMessage.of(19, text(id)))
    }

    @Test fun trailingNonMinimalTruncatedAndOversizedBytesAreRejected() {
        val row = SmsWireMessage.of(4, text(request()), number(0))
        val bytes = row.encode()
        try { SmsWireMessage.decode(bytes + byteArrayOf(0)); fail("trailing") } catch (_: SmsWireException) {} catch (_: SessionException) {}
        val nonMinimal = bytes.copyOf(bytes.size + 1).also { bytes.copyInto(it); it[bytes.size - 1] = 24; it[bytes.size] = 0 }
        try { SmsWireMessage.decode(nonMinimal); fail("nonminimal") } catch (_: SmsWireException) {} catch (_: SessionException) {}
        try { SmsWireMessage.decode(bytes.copyOf(bytes.size - 1)); fail("truncated") } catch (_: SmsWireException) {} catch (_: SessionException) {}
        assertNull(SmsWireMessage.decode(ByteArray(4001)))
    }
}
