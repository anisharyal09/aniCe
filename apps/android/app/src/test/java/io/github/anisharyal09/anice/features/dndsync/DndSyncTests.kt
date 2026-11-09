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
    @Test fun duplicateSystemBroadcastsDoNotBecomeNewChanges() {
        val deduplicator = DndChangeDeduplicator()
        deduplicator.baseline(false)
        assertFalse(deduplicator.changed(false))
        assertTrue(deduplicator.changed(true))
        assertFalse(deduplicator.changed(true))
        assertTrue(deduplicator.changed(false))
    }
}
