// SPDX-License-Identifier: GPL-3.0-or-later
// Projects independent transport readiness into device-level presentation without owning a connection.
package io.github.anisharyal09.anice.features.session

internal data class ConnectionSummary(val state: ConnectionState, val text: String, val action: String)

internal fun canConnectToPeer(bluetooth: ConnectionState, lan: ConnectionState,
    bluetoothSelected: Boolean, lanSelected: Boolean): Boolean =
    (bluetooth !in listOf(ConnectionState.CONNECTING, ConnectionState.SECURED) || bluetoothSelected) &&
        (lan !in listOf(ConnectionState.CONNECTING, ConnectionState.SECURED) || lanSelected)

internal fun connectionSummary(
    bluetooth: ConnectionState,
    lan: ConnectionState,
    waitingNearby: Boolean = false,
): ConnectionSummary {
    val secured = buildList {
        if (bluetooth == ConnectionState.SECURED) add("Bluetooth")
        if (lan == ConnectionState.SECURED) add("Local network")
    }
    return when {
        secured.isNotEmpty() -> ConnectionSummary(ConnectionState.SECURED,
            "Connected · ${secured.joinToString(" + ")}", "Disconnect")
        bluetooth == ConnectionState.CONNECTING || lan == ConnectionState.CONNECTING ->
            ConnectionSummary(ConnectionState.CONNECTING, "Connecting", "Cancel")
        waitingNearby -> ConnectionSummary(ConnectionState.DISCONNECTED, "Waiting nearby", "Disconnect")
        bluetooth == ConnectionState.FAILED || lan == ConnectionState.FAILED ->
            ConnectionSummary(ConnectionState.FAILED, "Connection failed", "Retry")
        else -> ConnectionSummary(ConnectionState.DISCONNECTED, "Disconnected", "Connect")
    }
}

internal fun <T> primaryPeers(peers: List<T>, connected: (T) -> Boolean): List<T> =
    peers.filter(connected).ifEmpty { peers }
