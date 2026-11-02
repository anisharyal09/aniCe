// SPDX-License-Identifier: GPL-3.0-or-later
// Verifies Phone-to-Mac input codecs against independent positive and negative fixtures.
package io.github.anisharyal09.anice.features.phoneinput

import io.github.anisharyal09.anice.infrastructure.session.Cbor
import io.github.anisharyal09.anice.infrastructure.session.SessionCbor
import io.github.anisharyal09.anice.infrastructure.session.SessionException
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class PhoneInputWireTests {
    private fun hex(value: String) =
        value.chunked(2).map { it.toInt(16).toByte() }.toByteArray()

    @Test fun independentFixturesRoundTripAndRejectMalformedBounds() {
        val root =
            JSONObject(
                javaClass.classLoader!!
                    .getResource("phone-input/phone-input-vectors.json")!!
                    .readText(),
            )
        val valid = root.getJSONArray("valid")
        val invalid = root.getJSONArray("invalid")
        assertEquals(13, valid.length())
        assertTrue(invalid.length() >= 31)

        for (index in 0 until valid.length()) {
            val row = valid.getJSONObject(index)
            val bytes = hex(row.getString("bytesHex"))
            assertArrayEquals(row.getString("name"), bytes, PhoneInputMessage.decode(bytes)!!.encode())
        }

        for (index in 0 until invalid.length()) {
            val row = invalid.getJSONObject(index)
            try {
                PhoneInputMessage.decode(hex(row.getString("bytesHex")))
                fail(row.getString("name"))
            } catch (_: PhoneInputWireException) {
            } catch (_: SessionException) {
            }
        }
    }

    @Test fun unrelatedDataRemainsAvailableToOtherHandlers() {
        assertNull(
            PhoneInputMessage.decode(
                SessionCbor.encode(Cbor.Array(listOf(Cbor.Text("other feature")))),
            ),
        )
    }
}
