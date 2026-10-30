// SPDX-License-Identifier: GPL-3.0-or-later
// Presents feature destinations and favourites using application-owned feature state.
package io.github.anisharyal09.anice.app

import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.dp
import io.github.anisharyal09.anice.R
import io.github.anisharyal09.anice.features.finddevice.FindDeviceController
import io.github.anisharyal09.anice.infrastructure.pairing.PeerTrustRecord

@Composable
fun FeaturesScreen(session: io.github.anisharyal09.anice.features.session.SessionViewModel, peers: List<PeerTrustRecord>, navigation: AppNavigation, favouritesOnly: Boolean = false) {
    val findDevice = session.findDevice
    val panel = navigation.featurePanel
    if (!favouritesOnly && panel == AppFeature.Sms) {
        Column(Modifier.fillMaxSize().padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            TextButton(onClick = navigation::closeFeature) {
                Icon(painterResource(R.drawable.ic_back), contentDescription = null, modifier = Modifier.size(16.dp))
                Spacer(Modifier.width(6.dp))
                Text("Back to ${navigation.featureOrigin.label}")
            }
            Text(panel.label, style = MaterialTheme.typography.titleMedium)
            io.github.anisharyal09.anice.features.sms.SmsView(session.sms, peers, Modifier.weight(1f))
        }
    } else if (!favouritesOnly && (panel == AppFeature.Playback || panel == AppFeature.Files || panel == AppFeature.Clipboard)) {
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            TextButton(onClick = navigation::closeFeature) {
                Icon(painterResource(R.drawable.ic_back), contentDescription = null, modifier = Modifier.size(16.dp))
                Spacer(Modifier.width(6.dp))
                Text("Back to ${navigation.featureOrigin.label}")
            }
            Text(panel.label, style = MaterialTheme.typography.titleMedium)
            if (panel == AppFeature.Playback) io.github.anisharyal09.anice.features.nowplaying.MediaView(session.media)
            else if (panel == AppFeature.Clipboard) io.github.anisharyal09.anice.features.clipboard.ClipboardView(session.clipboard, peers)
            else if (panel == AppFeature.Sms) io.github.anisharyal09.anice.features.sms.SmsView(session.sms, peers)
            else io.github.anisharyal09.anice.features.transfer.TransferView(session.transfer)
        }
    } else if (!favouritesOnly && navigation.findDetails) {
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            TextButton(onClick = navigation::closeFeature) {
                Icon(painterResource(R.drawable.ic_back), contentDescription = null, modifier = Modifier.size(16.dp))
                Spacer(Modifier.width(6.dp))
                Text("Back to ${navigation.featureOrigin.label}")
            }
            Text(AppFeature.FindDevice.label, style = MaterialTheme.typography.titleMedium)
            io.github.anisharyal09.anice.features.finddevice.FindDeviceView(findDevice, peers)
        }
    } else {
        val features = if (favouritesOnly) AppFeature.favourites(navigation.favouriteFeatures) else AppFeature.entries
        LazyColumn(contentPadding = PaddingValues(horizontal = 16.dp, vertical = 16.dp)) {
            item {
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text(if (favouritesOnly) "Favourites" else "Features", style = MaterialTheme.typography.titleMedium)
                    Text(if (favouritesOnly) "Your selected shortcuts. Edit them with the stars in Features." else "Open a feature, or star it for quick access.",
                        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    if (favouritesOnly && features.isEmpty()) Column(Modifier.padding(top = 8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text("No favourites yet", style = MaterialTheme.typography.titleSmall)
                        Text("Choose the features you want to keep close.", style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                        TextButton(onClick = { navigation.select(AppDestination.Features, peers.isEmpty()) },
                            contentPadding = PaddingValues(horizontal = 8.dp, vertical = 0.dp), modifier = Modifier.heightIn(min = 48.dp)) {
                            Text("Choose favourites")
                        }
                    }
                }
                Spacer(Modifier.height(12.dp))
            }
            items(features, key = { it.name }) { feature ->
                FeatureEntry(feature, AppFeature.favourites(navigation.favouriteFeatures).contains(feature),
                    status = featureStatus(feature, session, peers),
                    onFavourite = { navigation.favouriteFeatures = feature.toggled(navigation.favouriteFeatures) },
                    onClick = { navigation.openFeature(feature) })
            }
        }
    }
}

@Composable
internal fun FeatureEntry(feature: AppFeature, favourite: Boolean, status: String, onFavourite: () -> Unit, onClick: () -> Unit) {
    val icon = when (feature) { AppFeature.Playback -> R.drawable.ic_media_play; AppFeature.Files -> R.drawable.ic_file_send; AppFeature.FindDevice -> R.drawable.ic_find_device; AppFeature.Clipboard -> R.drawable.ic_clipboard; AppFeature.Sms -> R.drawable.ic_sms }
    Column(Modifier.fillMaxWidth()) {
        Row(
            Modifier.fillMaxWidth().heightIn(min = 72.dp)
                .clickable(role = Role.Button, onClickLabel = "Open ${feature.label}", onClick = onClick)
                .padding(vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Icon(painterResource(icon), contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(20.dp))
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(feature.label, style = MaterialTheme.typography.bodyMedium)
                Text(status, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1, overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis)
            }
            // The star owns its click independently of the enclosing row’s open action.
            IconButton(onClick = onFavourite, modifier = Modifier.semantics {
                contentDescription = (if (favourite) "Remove " else "Add ") + feature.label + (if (favourite) " from favourites" else " to favourites")
            }) {
                Icon(painterResource(if (favourite) R.drawable.ic_star_filled else R.drawable.ic_star), contentDescription = null,
                    tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(18.dp))
            }
            Icon(painterResource(R.drawable.ic_chevron_forward), contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(16.dp))
        }
        HorizontalDivider(thickness = 0.5.dp, color = MaterialTheme.colorScheme.outlineVariant)
    }
}

private fun featureStatus(feature: AppFeature, session: io.github.anisharyal09.anice.features.session.SessionViewModel,
    peers: List<PeerTrustRecord>): String = when (feature) {
    AppFeature.Playback -> session.media.playback?.let { current ->
        if (current.source.isEmpty()) "No active playback" else
            (if (current.state == 1L) "Playing" else "Paused") + current.title.takeIf(String::isNotEmpty)?.let { " · $it" }.orEmpty()
    } ?: "No active playback"
    AppFeature.Files -> when (val state = session.transfer.state) {
        is io.github.anisharyal09.anice.features.transfer.TransferState.Connecting -> "Connecting"
        is io.github.anisharyal09.anice.features.transfer.TransferState.WaitingForPeerApproval -> "Waiting for approval"
        is io.github.anisharyal09.anice.features.transfer.TransferState.IncomingOffer -> "${state.batch.files.size} incoming files"
        is io.github.anisharyal09.anice.features.transfer.TransferState.Transferring -> "Sending · ${state.fileName}"
        is io.github.anisharyal09.anice.features.transfer.TransferState.Paused -> "Transfer paused"
        is io.github.anisharyal09.anice.features.transfer.TransferState.Completed -> "${state.fileCount} files sent"
        is io.github.anisharyal09.anice.features.transfer.TransferState.Rejected -> "Transfer declined"
        is io.github.anisharyal09.anice.features.transfer.TransferState.Failed -> "Transfer failed"
        io.github.anisharyal09.anice.features.transfer.TransferState.Cancelled -> "Transfer cancelled"
        io.github.anisharyal09.anice.features.transfer.TransferState.Idle -> if (session.transfer.peerConnected) "Ready to send" else "Device offline"
    }
    AppFeature.Clipboard -> if (session.clipboard.selected == null) "Pair a device to share" else
        "${if (session.clipboard.automatic) "Automatic sharing" else "Manual sharing"} · History ${if (session.clipboard.history.enabled) "on" else "off"}"
    AppFeature.Sms -> when {
        !(session.sms.permissionsState.receive && session.sms.permissionsState.read && session.sms.permissionsState.send) -> "SMS access needed"
        peers.any { session.sms.reachable(it.peer) } -> "SMS sharing with your Mac"
        peers.isEmpty() -> "Pair a Mac to relay messages"
        else -> "Connect your Mac"
    }
    AppFeature.FindDevice -> when {
        session.findDevice.busy -> "Request in progress"
        peers.any { session.findDevice.canFind(it.peer) } -> "Ready to alert your device"
        peers.any { session.findDevice.connected(it.peer) } -> "Not available on this device"
        else -> "Device offline"
    }
}
