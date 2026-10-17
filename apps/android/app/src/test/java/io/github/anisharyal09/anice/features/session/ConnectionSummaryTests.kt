// SPDX-License-Identifier: GPL-3.0-or-later
// Verifies that device summaries require encrypted readiness and preserve independent transport outcomes.
package io.github.anisharyal09.anice.features.session

import io.github.anisharyal09.anice.infrastructure.connections.ConnectionState
import org.junit.Assert.*
import org.junit.Test

class ConnectionSummaryTests {
    @Test fun staleSelectionCannotOfferControlsForAnotherActivePeer() {
        assertFalse(canConnectToPeer(ConnectionState.DISCONNECTED, ConnectionState.SECURED, true, false))
        assertFalse(canConnectToPeer(ConnectionState.CONNECTING, ConnectionState.FAILED, false, true))
        assertTrue(canConnectToPeer(ConnectionState.SECURED, ConnectionState.DISCONNECTED, true, false))
        assertTrue(canConnectToPeer(ConnectionState.DISCONNECTED, ConnectionState.SECURED, false, true))
        assertTrue(canConnectToPeer(ConnectionState.FAILED, ConnectionState.DISCONNECTED, false, false))
    }
    @Test fun onlyReadyTransportsAppearConnected() {
        val states = ConnectionState.entries
        assertEquals(4, states.size)
        var connected = 0
        var unready = 0
        for (ble in states) for (lan in states) {
            val result = connectionSummary(ble, lan)
            if (ble == ConnectionState.SECURED || lan == ConnectionState.SECURED) {
                connected++
                assertEquals(ConnectionState.SECURED, result.state)
                assertEquals("Disconnect", result.action)
                assertEquals(ble == ConnectionState.SECURED, result.text.contains("Bluetooth"))
                assertEquals(lan == ConnectionState.SECURED, result.text.contains("Local network"))
            } else {
                unready++
                assertFalse(result.text.startsWith("Connected"))
                assertNotEquals(ConnectionState.SECURED, result.state)
            }
        }
        assertEquals(7, connected)
        assertEquals(9, unready)
    }

    @Test fun secondaryFailureNeverReplacesReadyChannelOrCancelAction() {
        assertEquals("Connected · Local network",
            connectionSummary(ConnectionState.FAILED, ConnectionState.SECURED).text)
        assertEquals("Connected · Bluetooth",
            connectionSummary(ConnectionState.SECURED, ConnectionState.FAILED).text)
        assertEquals("Cancel", connectionSummary(ConnectionState.FAILED, ConnectionState.CONNECTING).action)
        assertEquals("Cancel", connectionSummary(ConnectionState.CONNECTING, ConnectionState.DISCONNECTED, true).action)
        assertEquals("Retry", connectionSummary(ConnectionState.FAILED, ConnectionState.DISCONNECTED).action)
        assertEquals("Connect", connectionSummary(ConnectionState.DISCONNECTED, ConnectionState.DISCONNECTED).action)
        val waiting = connectionSummary(ConnectionState.FAILED, ConnectionState.DISCONNECTED, true)
        assertEquals("Waiting nearby", waiting.text)
        assertEquals("Disconnect", waiting.action)
        assertEquals("Disconnect", connectionSummary(ConnectionState.DISCONNECTED, ConnectionState.SECURED, true).action)
    }
    @Test fun primaryPeerListRequiresReadinessAndFallsBackWhenNoneAreConnected() {
        val peers = listOf(Triple("a", ConnectionState.SECURED, ConnectionState.FAILED),
            Triple("b", ConnectionState.CONNECTING, ConnectionState.DISCONNECTED),
            Triple("c", ConnectionState.DISCONNECTED, ConnectionState.SECURED))
        assertEquals(listOf("a", "c"), primaryPeers(peers) { connectionSummary(it.second, it.third).state == ConnectionState.SECURED }.map { it.first })
        assertEquals(peers, primaryPeers(peers) { false })
        assertEquals(peers, primaryPeers(peers) { true })
        assertTrue(primaryPeers(emptyList<String>()) { true }.isEmpty())
    }

}
