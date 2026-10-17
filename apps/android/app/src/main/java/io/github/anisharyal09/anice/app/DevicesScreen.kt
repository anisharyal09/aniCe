// SPDX-License-Identifier: GPL-3.0-or-later
// Presents device routes through existing pairing, discovery and connection owners.
package io.github.anisharyal09.anice.app

import androidx.compose.material3.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.foundation.layout.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import io.github.anisharyal09.anice.features.discovery.*
import io.github.anisharyal09.anice.features.pairing.*
import io.github.anisharyal09.anice.features.session.*
import io.github.anisharyal09.anice.infrastructure.connections.CompanionProbe

@Composable
internal fun DevicesScreen(pairing: PairingViewModel, discovery: DiscoveryViewModel, session: SessionViewModel, navigation: AppNavigation, nearbyOwner: CompanionProbe, automaticAfterPairing: Boolean, onAutomatic: (Boolean)->Unit) {
    when (navigation.route) {
        DeviceRoute.Pairing -> PairingScreen(pairing, nearbyOwner.available, automaticAfterPairing, onAutomatic)
        DeviceRoute.Discovery -> DiscoveryScreen(discovery)
        DeviceRoute.Overview -> {
            if (navigation.destination == AppDestination.Home) {
                HomeScreen(pairing.peers.isNotEmpty(), onPair = navigation::pair, attention = {
                    if (session.media.compactVisible || navigation.mediaDetails) {
                        io.github.anisharyal09.anice.features.nowplaying.MediaView(session.media, showPlayerSelector = false, compactVolume = true, open = { navigation.openFeature(AppFeature.Playback) })
                        if (navigation.mediaDetails) TextButton(onClick = { navigation.mediaDetails = false }) { Text("Done") }
                    }
                    if (pairing.peers.isNotEmpty()) io.github.anisharyal09.anice.features.transfer.TransferView(session.transfer, open = { navigation.openFeature(AppFeature.Files) })
                }, sessions = {
                    if (pairing.busy) TextButton(onClick = navigation::pair) { Text("Review pairing") }
                    SessionPanel(session, pairing.peers, overview = true, compact = true, onOpenDevice = navigation::openDevice,
                        onDiscoveryCheck = { navigation.destination = AppDestination.Devices; navigation.route = DeviceRoute.Discovery },
                        focusedPeer = navigation.focusedPeer, onFocusConsumed = { navigation.focusedPeer = null })
                })
            } else {
                Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp),
                    verticalArrangement = Arrangement.spacedBy(16.dp)) {
                    Text("Connections", style = MaterialTheme.typography.titleSmall)
                    if (pairing.peers.isEmpty()) Text("No devices paired yet", style = MaterialTheme.typography.bodySmall)
                    SessionPanel(session, pairing.peers,
                        onDiscoveryCheck = { navigation.route = DeviceRoute.Discovery }, focusedPeer = navigation.focusedPeer,
                        onFocusConsumed = { navigation.focusedPeer = null })
                    HorizontalDivider()
                    TextButton(onClick = { navigation.settingsRoute = SettingsRoute.Identity; navigation.destination = AppDestination.Settings },
                        modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) {
                        Text("This device", Modifier.weight(1f))
                        Icon(androidx.compose.ui.res.painterResource(io.github.anisharyal09.anice.R.drawable.ic_chevron_forward), contentDescription = null, modifier = Modifier.size(18.dp))
                    }
                    TextButton(onClick = navigation::pair,
                        modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) {
                        Text("Add device", Modifier.weight(1f))
                        Icon(androidx.compose.ui.res.painterResource(io.github.anisharyal09.anice.R.drawable.ic_chevron_forward), contentDescription = null, modifier = Modifier.size(18.dp))
                    }
                }
            }
        }
    }
}
