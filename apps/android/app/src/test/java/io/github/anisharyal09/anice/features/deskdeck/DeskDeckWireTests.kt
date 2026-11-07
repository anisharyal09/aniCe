// SPDX-License-Identifier: GPL-3.0-or-later
// Verifies shared Desk Deck and device-power fixtures against the Android codecs.
package io.github.anisharyal09.anice.features.deskdeck

import io.github.anisharyal09.anice.infrastructure.session.SessionException
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class DeskDeckWireTests {
    private fun hex(text: String) = text.chunked(2).map { it.toInt(16).toByte() }.toByteArray()

    @Test fun catalogChangeRequiresAVersionTwoSubscriptionAndRevision() {
        val subscription = "00000000-0000-0000-0000-000000000001"
        val revision = "00000000-0000-0000-0000-000000000002"
        val changed = DeskDeckMessage(kind = 10, version = 2, subscription = subscription, catalogRevision = revision)
        assertEquals(changed, DeskDeckMessage.decode(changed.encode()))
        assertThrows(DeskDeckWireException::class.java) {
            DeskDeckMessage(kind = 10, version = 1, subscription = subscription, catalogRevision = revision).encode()
        }
        assertThrows(DeskDeckWireException::class.java) {
            DeskDeckMessage(kind = 10, version = 2, subscription = subscription, catalogRevision = "not-a-uuid").encode()
        }
    }

    @Test fun sharedDeskDeckFixturesRoundTripAndRejectMalformedRecords() {
        val root = JSONObject(javaClass.classLoader!!.getResource("desk-deck-vectors.json")!!.readText())
        val valid = root.getJSONArray("valid")
        val invalid = root.getJSONArray("invalid")
        assertTrue(valid.length() >= 4)
        assertTrue(invalid.length() >= 2)
        val versions = mutableSetOf<Long>()

        for (index in 0 until valid.length()) {
            val row = valid.getJSONObject(index)
            val bytes = hex(row.getString("bytesHex"))
            val message = try {
                DeskDeckMessage.decode(bytes) ?: error("${row.getString("name")} was not Desk Deck")
            } catch (error: Exception) {
                throw AssertionError("${row.getString("name")} could not be decoded", error)
            }
            assertArrayEquals(row.getString("name"), bytes, message.encode())
            versions += message.version
        }
        assertEquals(setOf(1L, 2L, 3L, 4L), versions)

        for (index in 0 until invalid.length()) {
            val row = invalid.getJSONObject(index)
            try {
                DeskDeckMessage.decode(hex(row.getString("bytesHex")))
                fail("Accepted ${row.getString("name")}")
            } catch (_: DeskDeckWireException) {
            } catch (_: SessionException) {
            }
        }
    }

    @Test fun versionThreeMemorySeparatesCacheAndOtherResidentPages() {
        val sample = DeskDeckMessage(kind = 3, version = 3,
            subscription = "00000000-0000-0000-0000-000000000001", sequence = 1,
            memoryActive = 100, memoryWired = 20, memoryCompressed = 5, memoryTotal = 200,
            memoryApp = 100, memoryCached = 30, memoryFree = 25, memorySwap = 40)
        val decoded = DeskDeckMessage.decode(sample.encode())!!
        assertEquals(145L, decoded.memoryUsed)
        assertEquals(20L, decoded.memoryUsed - decoded.memoryApp - decoded.memoryWired - decoded.memoryCompressed)
        assertEquals(30L, decoded.memoryCached)
        assertEquals(40L, decoded.memorySwap)
    }

    @Test fun versionFourShortcutActionsRequireOpaqueEmptyPayload() {
        val subscription = "00000000-0000-0000-0000-000000000001"
        val valid = DeskDeckMessage(kind = 4, version = 4, subscription = subscription,
            commandId = 1, action = 9)
        assertEquals(valid, DeskDeckMessage.decode(valid.encode()))
        assertThrows(DeskDeckWireException::class.java) {
            valid.copy(target = "/Applications/anything.app").encode()
        }
        assertThrows(DeskDeckWireException::class.java) {
            valid.copy(version = 3).encode()
        }
        assertThrows(DeskDeckWireException::class.java) {
            valid.copy(action = 10).encode()
        }
    }

    @Test fun sharedDevicePowerFixturesPreserveUnknownPercentage() {
        val root = JSONObject(javaClass.classLoader!!.getResource("device-power-vectors.json")!!.readText())
        val valid = root.getJSONArray("valid")
        val invalid = root.getJSONArray("invalid")
        for (index in 0 until valid.length()) {
            val row = valid.getJSONObject(index)
            val bytes = hex(row.getString("bytesHex"))
            val message = DevicePowerMessage.decode(bytes) ?: error("${row.getString("name")} was not power data")
            assertArrayEquals(row.getString("name"), bytes, message.encode())
            if (row.getString("name") == "battery-percent-unknown") assertEquals(-1L, message.percent)
            assertNull(DeskDeckMessage.decode(bytes))
        }
        for (index in 0 until invalid.length()) {
            val row = invalid.getJSONObject(index)
            try {
                DevicePowerMessage.decode(hex(row.getString("bytesHex")))
                fail("Accepted ${row.getString("name")}")
            } catch (_: DevicePowerWireException) {
            } catch (_: SessionException) {
            }
        }
    }
}
