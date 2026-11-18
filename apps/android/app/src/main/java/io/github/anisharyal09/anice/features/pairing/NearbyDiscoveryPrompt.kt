// SPDX-License-Identifier: GPL-3.0-or-later
// Presents actual qualified anonymous beacons without implying SAS or trusted connectivity.
package io.github.anisharyal09.anice.features.pairing

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import io.github.anisharyal09.anice.infrastructure.connections.NearbyDiscoveryViewModel

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun NearbyDiscoveryPrompt(model: NearbyDiscoveryViewModel, manualPair: () -> Unit) {
    if (model.candidates.isEmpty() || model.dismissed) return
    ModalBottomSheet(onDismissRequest = model::dismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 24.dp).padding(bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Text("aniCe device discovered", style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
            Text(if (model.candidates.size == 1) "A Mac is nearby" else "Macs are nearby",
                style = MaterialTheme.typography.titleLarge)
            Text("Device names stay private during discovery. This does not establish trust.",
                style = MaterialTheme.typography.bodyMedium)
            model.candidates.forEachIndexed { index, candidate ->
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    Text(if (model.candidates.size == 1) "Nearby Mac" else "Nearby Mac ${index + 1}")
                    Text("Strong signal · ${candidate.rssi} dBm",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            Text("Code comparison is not available yet. Pair using the QR code or manual code on your Mac.",
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                TextButton(onClick = model::dismiss, modifier = Modifier.heightIn(min = 48.dp)) { Text("Dismiss") }
                OutlinedButton(onClick = { model.dismiss(); manualPair() },
                    shape = MaterialTheme.shapes.small, modifier = Modifier.heightIn(min = 48.dp)) { Text("Manual pair") }
            }
        }
    }
}
