// SPDX-License-Identifier: GPL-3.0-or-later
// Verifies independent transfer wire fixtures, canonical encoding and strict boundary enforcement.
package io.github.anisharyal09.anice.features.transfer

import io.github.anisharyal09.anice.infrastructure.session.SessionException
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class TransferWireTests {
    @Test fun chunk512RequiresItsOwnCapabilityAndBudget() {
        val batch = java.util.UUID.randomUUID().toString(); val file = java.util.UUID.randomUUID().toString()
        val chunk = TransferMessage.chunk(batch, file, 0, ByteArray(524288))
        val encoded = chunk.encode(524288)
        assertTrue(encoded.size <= 524416)
        assertEquals(524288, TransferMessage.decode(encoded, 524288)!!.bytes(3).size)
        try { TransferMessage.decode(encoded, 262016); fail("Legacy budget accepted 512 KiB") }
        catch (_: TransferWireException) { }
        try { TransferMessage.capability(3, 524288, 8).encode(524288); fail("Capability 3 exceeded its original bound") }
        catch (_: TransferWireException) { }
        assertEquals(4L, TransferMessage.decode(TransferMessage.capability(4, 524288, 8).encode(524288), 524288)!!.number(0))
        try { TransferMessage.chunk(batch, file, 0, ByteArray(524289)).encode(524288); fail("Oversized chunk accepted") }
        catch (_: TransferWireException) { }
    }

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

    @Test
    fun chunkSlicingMatchesCanonicalEncodingAndOwnsItsBytes() {
        val batch = "11111111-1111-4111-8111-111111111111"
        val file = "22222222-2222-4222-8222-222222222222"
        val source = ByteArray(262016 + 8) { (it % 251).toByte() }
        val expected = ByteArray(262016) { (it % 251).toByte() }
        val sliced = TransferMessage.chunkFrom(batch, file, 4096L, source, 262016)
        // A reused read buffer frames exactly as an owning copy would.
        assertEquals(TransferMessage.chunk(batch, file, 4096L, expected), sliced)
        val wire = sliced.encode(262016)
        assertArrayEquals(TransferMessage.chunk(batch, file, 4096L, expected).encode(262016), wire)
        java.util.Arrays.fill(source, 0)
        // The node copies on construction, so the next read cannot reach an already framed chunk.
        assertArrayEquals(expected, TransferMessage.decode(wire, 262016)!!.bytes(3))
        assertArrayEquals(wire, sliced.encode(262016))
        try {
            sliced.encode()
            fail("Standard limit accepted a large LAN chunk")
        } catch (_: TransferWireException) {}
        try {
            TransferMessage.chunkFrom(batch, file, 0L, source, 0).encode(262016)
            fail("Empty chunk accepted")
        } catch (_: TransferWireException) {}
        assertThrows(IndexOutOfBoundsException::class.java) {
            TransferMessage.chunkFrom(batch, file, 0L, ByteArray(8), 9)
        }
    }
}
