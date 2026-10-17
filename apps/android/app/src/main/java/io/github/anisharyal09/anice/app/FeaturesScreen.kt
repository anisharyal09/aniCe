// SPDX-License-Identifier: GPL-3.0-or-later
// Routes feature launchers to shared device controls or Find Device.
package io.github.anisharyal09.anice.app

import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
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
    if (!favouritesOnly && (panel == AppFeature.Playback || panel == AppFeature.Files)) {
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            TextButton(onClick = navigation::closeFeature) {
                Icon(painterResource(R.drawable.ic_back), contentDescription = null, modifier = Modifier.size(16.dp))
                Spacer(Modifier.width(6.dp))
                Text("Back to ${navigation.featureOrigin.label}")
            }
            Text(panel.label, style = MaterialTheme.typography.titleMedium)
            if (panel == AppFeature.Playback) io.github.anisharyal09.anice.features.nowplaying.MediaView(session.media)
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
        LazyVerticalGrid(columns = GridCells.Fixed(1), contentPadding = PaddingValues(16.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            item {
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text(if (favouritesOnly) "Favourites" else "Features", style = MaterialTheme.typography.titleMedium)
                    Text(if (favouritesOnly) "Your selected shortcuts." else "Choose a feature, or star it to keep it in Favourites.",
                        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    if (favouritesOnly && AppFeature.favourites(navigation.favouriteFeatures).isEmpty()) {
                        TextButton(onClick = { navigation.select(AppDestination.Features, peers.isEmpty()) }) { Text("Choose favourites") }
                    }
                }
            }
            (if (favouritesOnly) AppFeature.favourites(navigation.favouriteFeatures) else AppFeature.entries).forEach { feature ->
                item(key = feature.name) {
                    FeatureEntry(feature, AppFeature.favourites(navigation.favouriteFeatures).contains(feature),
                        onFavourite = { navigation.favouriteFeatures = feature.toggled(navigation.favouriteFeatures) },
                        onClick = { navigation.openFeature(feature) })
                }
            }
        }
    }
}

@Composable
private fun FeatureEntry(feature: AppFeature, favourite: Boolean, onFavourite: () -> Unit, onClick: () -> Unit) {
    val icon = when (feature) { AppFeature.Playback -> R.drawable.ic_media_play; AppFeature.Files -> R.drawable.ic_file_send; AppFeature.FindDevice -> R.drawable.ic_find_device }
    val detail = when (feature) {
        AppFeature.Playback -> "Playback from your Mac"
        AppFeature.Files -> "Send to your connected device"
        AppFeature.FindDevice -> "Alert a connected device"
    }
    Surface(onClick = onClick, modifier = Modifier.fillMaxWidth(), shape = MaterialTheme.shapes.medium,
        color = MaterialTheme.colorScheme.surfaceContainer) {
        Row(Modifier.fillMaxWidth().padding(start = 16.dp, end = 8.dp, top = 12.dp, bottom = 12.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
            Icon(painterResource(icon), contentDescription = null, modifier = Modifier.size(22.dp))
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(feature.label, style = MaterialTheme.typography.titleSmall)
                Text(detail, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            IconButton(onClick = onFavourite, modifier = Modifier.semantics {
                contentDescription = (if (favourite) "Remove " else "Add ") + feature.label + (if (favourite) " from favourites" else " to favourites")
            }) { Icon(painterResource(if (favourite) R.drawable.ic_star_filled else R.drawable.ic_star), contentDescription = null, modifier = Modifier.size(20.dp)) }
            Icon(painterResource(R.drawable.ic_chevron_forward), contentDescription = null,
                modifier = Modifier.size(16.dp))
        }
    }
}
