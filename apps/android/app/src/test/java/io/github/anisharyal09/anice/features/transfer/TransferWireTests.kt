// SPDX-License-Identifier: GPL-3.0-or-later
// Verifies independent transfer wire fixtures, canonical encoding and strict boundary enforcement.
package io.github.anisharyal09.anice.features.transfer

import io.github.anisharyal09.anice.infrastructure.session.SessionException
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class TransferWireTests {
    private val root get() = JSONObject(javaClass.classLoader!!.getResource("transfer/transfer-vectors.json")!!.readText())
    private fun hex(text: String) = text.chunked(2).map { it.toInt(16).toByte() }.toByteArray()

    @Test
    fun independentFixtureInventoriesAndCanonicalEncoding() {
        val good = root.getJSONArray("valid")
        val bad = root.getJSONArray("invalid")
        assertTrue("Valid inventory floor failed: ${good.length()}", good.length() >= 12)
        assertTrue("Invalid inventory floor failed: ${bad.length()}", bad.length() >= 20)

        for (i in 0 until good.length()) {
            val row = good.getJSONObject(i)
            val bytes = hex(row.getString("bytesHex"))
            val message = TransferMessage.decode(bytes)
            assertNotNull("Failed to decode valid fixture ${row.getString("name")}", message)
            assertEquals("Kind mismatch for ${row.getString("name")}", row.getLong("kind"), message!!.kind)
            assertArrayEquals("Canonical roundtrip mismatch for ${row.getString("name")}", bytes, message.encode())
        }

        for (i in 0 until bad.length()) {
            val row = bad.getJSONObject(i)
            val bytes = hex(row.getString("bytesHex"))
            try {
                TransferMessage.decode(bytes)
                fail("Accepted invalid fixture: ${row.getString("name")}")
            } catch (_: TransferWireException) {
            } catch (_: SessionException) {
            }
        }
    }
}
