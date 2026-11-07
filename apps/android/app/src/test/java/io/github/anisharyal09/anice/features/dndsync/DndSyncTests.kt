// SPDX-License-Identifier: GPL-3.0-or-later
package io.github.anisharyal09.anice.features.dndsync

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class DndSyncTests {
    private fun hex(text: String) = text.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
    @Test fun sharedFixturesRoundTripAndRejectMalformedRecords() {
        val root = JSONObject(javaClass.classLoader!!.getResource("dnd-sync-vectors.json")!!.readText())
        val valid = root.getJSONArray("valid")
        repeat(valid.length()) { i ->
            val bytes = hex(valid.getJSONObject(i).getString("bytesHex"))
            assertArrayEquals(bytes, DndSyncMessage.decode(bytes)!!.encode())
        }
        val invalid = root.getJSONArray("invalid")
        repeat(invalid.length()) { i ->
            assertThrows(Exception::class.java) { DndSyncMessage.decode(hex(invalid.getJSONObject(i).getString("bytesHex"))) }
        }
    }
    @Test fun remoteEchoDuplicateAndOppositeUserChangeAreDistinct() {
        val guard = DndEchoGuard()
        guard.baseline(false)
        guard.applying(true, 100)
        assertFalse(guard.changed(false, 101)) // A redundant callback must not consume the expected effect.
        assertFalse(guard.changed(true, 102))
        assertFalse(guard.changed(true, 103))
        assertTrue(guard.changed(false, 104))
        guard.applying(true, 105)
        assertTrue(guard.changed(true, 15_106)) // Expired markers cannot swallow later user changes.
    }
    @Test fun unexpectedNativeTransitionClearsTheExpectedRemoteEffect() {
        val guard = DndEchoGuard()
        guard.baseline(true)
        guard.applying(true, 0)
        assertTrue(guard.changed(false, 1))
        assertTrue(guard.changed(true, 2))
    }
}
