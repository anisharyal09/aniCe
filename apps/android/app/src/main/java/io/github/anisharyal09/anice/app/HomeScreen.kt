// SPDX-License-Identifier: GPL-3.0-or-later
// Presents trusted-device actions and the unpaired entry point without transport diagnostics.
package io.github.anisharyal09.anice.app

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp

@Composable
fun HomeScreen(
  hasTrustedDevices: Boolean,
  onPair: () -> Unit,
  sessions: @Composable () -> Unit,
  modifier: Modifier = Modifier,
  compact: Boolean = false,
  showManagement: Boolean = false,
  attention: @Composable () -> Unit = {},
  quickActions: @Composable () -> Unit = {},
  activities: @Composable () -> Unit = {},
  recentActivity: @Composable () -> Unit = {},
  showRecentHeading: Boolean = true,
) {
  Box(modifier.fillMaxSize(), contentAlignment = Alignment.TopCenter) {
    Column(
      Modifier.fillMaxWidth()
        .verticalScroll(rememberScrollState())
        .padding(horizontal = 16.dp, vertical = if (compact) 24.dp else 12.dp),
      verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
      Text("Home", style = MaterialTheme.typography.titleLarge,
        modifier = Modifier.semantics { heading() })
      attention()
      if (hasTrustedDevices && showManagement) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
          TextButton(onClick = onPair, modifier = Modifier.heightIn(min = 48.dp)) { Text("Manage devices") }
        }
      }
      if (hasTrustedDevices) {
        Column(
          Modifier.fillMaxWidth().padding(vertical = 8.dp),
          verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
          sessions()
        }
      } else {
        Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
          Text("No devices paired yet", style = MaterialTheme.typography.titleSmall)
          Text(
            "Scan your Mac’s QR code or enter its six-digit code.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
          )
          OutlinedButton(shape = MaterialTheme.shapes.small, contentPadding = PaddingValues(horizontal = 10.dp, vertical = 4.dp), onClick = onPair, modifier = Modifier.defaultMinSize(minHeight = 32.dp)) {
            Text("Pair a device")
          }
        }
      }
      quickActions()
      activities()
      if (showRecentHeading) Text("Recent", style = MaterialTheme.typography.labelMedium,
        color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.semantics { heading() })
      recentActivity()
    }
  }
}
