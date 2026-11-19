// SPDX-License-Identifier: GPL-3.0-or-later
// Presents attempt-bound comparison approval independently of navigation; dismissal rejects pairing.
package io.github.anisharyal09.anice.features.pairing

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.selection.toggleable
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp

@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
internal fun ComparisonPrompt(model: PairingViewModel, manualPair: () -> Unit) {
    if (!model.comparingNearby) return
    val attempt = model.comparisonAttempt
    val sheetHeight = with(LocalDensity.current) {
        LocalWindowInfo.current.containerSize.height.toDp() * 0.85f
    }
    ModalBottomSheet(onDismissRequest = model::declineComparison,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(Modifier.fillMaxWidth().heightIn(max = sheetHeight)
            .padding(horizontal = 24.dp).padding(bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = androidx.compose.ui.Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Icon(androidx.compose.ui.res.painterResource(io.github.anisharyal09.anice.R.drawable.ic_laptop),
                    contentDescription = null, modifier = Modifier.size(28.dp),
                    tint = MaterialTheme.colorScheme.onSurfaceVariant)
                Text("Connect your Mac", style = MaterialTheme.typography.titleLarge)
            }
            Column(Modifier.fillMaxWidth().weight(1f, fill = false).verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(16.dp)) {
                model.comparisonCode?.let { code ->
                    Text(code.take(3) + " " + code.takeLast(3),
                        style = MaterialTheme.typography.headlineLarge.copy(fontFamily = FontFamily.Monospace),
                        modifier = Modifier.semantics {
                            contentDescription = "Comparison code " + code.toList().joinToString(" ")
                        })
                    Text("Does this code match your Mac?",
                        style = MaterialTheme.typography.bodyMedium)
                }
                if (model.phase != "comparison")
                    Text(model.status, style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                if (model.phase in listOf("preparing", "connecting", "authenticating", "verifying", "saving", "cleanup"))
                    LinearProgressIndicator(Modifier.fillMaxWidth())
                Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).toggleable(
                    value = model.automaticAfterPairing, enabled = model.phase == "comparison",
                    role = androidx.compose.ui.semantics.Role.Checkbox,
                    onValueChange = model::chooseAutomaticAfterPairing),
                    verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
                    Checkbox(checked = model.automaticAfterPairing, enabled = model.phase == "comparison",
                        onCheckedChange = null)
                    Text("Reconnect automatically", style = MaterialTheme.typography.bodyMedium)
                }
            }
            FlowRow(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End,
                verticalArrangement = Arrangement.spacedBy(4.dp)) {
                TextButton(onClick = { model.cancel(); manualPair() },
                    enabled = model.phase !in listOf("saving", "cleanup", "cancelling")) { Text("Manual pair") }
                TextButton(onClick = model::declineComparison,
                    enabled = model.phase !in listOf("saving", "cleanup", "cancelling"),
                    modifier = Modifier.heightIn(min = 48.dp)) { Text("Dismiss") }
                Button(onClick = { model.confirmComparison(attempt) },
                    enabled = model.phase == "comparison", shape = MaterialTheme.shapes.small,
                    modifier = Modifier.heightIn(min = 48.dp)) { Text("Confirm") }
            }
        }
    }
}
