// SPDX-License-Identifier: GPL-3.0-or-later
// Offers one user-selected anonymous candidate; discovery never implies trust or connectivity.
package io.github.anisharyal09.anice.features.pairing

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.dp
import io.github.anisharyal09.anice.infrastructure.connections.NearbyDiscoveryViewModel

@Composable
internal fun NearbySetupStatus(model: NearbyDiscoveryViewModel, onAllow: () -> Unit,
    onSettings: () -> Unit, onRetry: () -> Unit) {
    if (model.scanning) {
        Text("Looking for your Mac automatically…", style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant)
        return
    }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(model.status, style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant)
        Button(onClick = if (model.permissionRequired) {
                if (model.permissionNeedsSettings) onSettings else onAllow
            } else onRetry,
            shape = MaterialTheme.shapes.small,
            contentPadding = PaddingValues(horizontal = 12.dp, vertical = 4.dp),
            modifier = Modifier.heightIn(min = 48.dp)) {
            Text(if (model.permissionRequired) {
                if (model.permissionNeedsSettings) "Open app settings"
                else if (android.os.Build.VERSION.SDK_INT >= 31) "Allow nearby devices" else "Allow discovery"
            } else "Find nearby")
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun NearbyDiscoveryPrompt(model: NearbyDiscoveryViewModel, manualPair: () -> Unit,
    pair: (Long) -> Unit) {
    if (model.candidates.isEmpty() || model.dismissed || !model.choosingCandidate) return
    val maxBodyHeight = with(LocalDensity.current) { LocalWindowInfo.current.containerSize.height.toDp() * 0.5f }
    ModalBottomSheet(onDismissRequest = model::dismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 24.dp).padding(bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Text("Choose your Mac",
                style = MaterialTheme.typography.titleLarge)
            Text("More than one Mac was nearby. Select one to compare codes.",
                style = MaterialTheme.typography.bodyMedium)
            Column(Modifier.fillMaxWidth().heightIn(max = maxBodyHeight).verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(12.dp)) {
                model.candidates.forEachIndexed { index, candidate ->
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                        Text(if (model.candidates.size == 1) "Nearby Mac" else "Nearby Mac ${index + 1}",
                            modifier = Modifier.weight(1f))
                        Text("Nearby",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    Button(onClick = { pair(candidate.id) }, shape = MaterialTheme.shapes.small,
                        modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) {
                        Text("Compare code")
                    }
                }
            }
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                TextButton(onClick = model::dismiss, modifier = Modifier.heightIn(min = 48.dp)) { Text("Dismiss") }
                OutlinedButton(onClick = { model.dismiss(); manualPair() },
                    shape = MaterialTheme.shapes.small, modifier = Modifier.heightIn(min = 48.dp)) { Text("Manual pair") }
            }
        }
    }
}
