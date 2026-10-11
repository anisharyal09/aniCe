// SPDX-License-Identifier: GPL-3.0-or-later
// Presents device routes through existing pairing, discovery and connection owners.
package io.github.anisharyal09.anice.app

import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import io.github.anisharyal09.anice.features.discovery.*
import io.github.anisharyal09.anice.features.pairing.*
import io.github.anisharyal09.anice.features.session.*
import io.github.anisharyal09.anice.infrastructure.connections.CompanionProbe

@Composable
internal fun DevicesScreen(pairing: PairingViewModel, discovery: DiscoveryViewModel, session: SessionViewModel, navigation: AppNavigation, nearbyOwner: CompanionProbe, automaticAfterPairing: Boolean, onAutomatic: (Boolean)->Unit) {
when (navigation.route) {
                        DeviceRoute.Pairing -> {
                            PairingScreen(pairing, nearbyOwner.available, automaticAfterPairing, onAutomatic)
                        }
                        DeviceRoute.Discovery -> DiscoveryScreen(discovery)
                        DeviceRoute.Overview -> {
                            if (pairing.peers.isEmpty()) HomeScreen(false, onPair = { navigation.route = DeviceRoute.Pairing }, sessions = {})
                            else HomeScreen(true, onPair = { navigation.route = DeviceRoute.Pairing }, sessions = {
                                if (pairing.busy) TextButton(onClick = { navigation.route = DeviceRoute.Pairing }) { Text("Review pairing") }
                                SessionPanel(session, pairing.peers,
                                    onDiscoveryCheck = { navigation.route = DeviceRoute.Discovery }, focusedPeer = navigation.focusedPeer,
                                    onFocusConsumed = { navigation.focusedPeer = null })
                            })
                        }
                    }

}
