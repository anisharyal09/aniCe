// SPDX-License-Identifier: GPL-3.0-or-later
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
  onCheck: () -> Unit,
  sessions: @Composable () -> Unit,
  modifier: Modifier = Modifier,
) {
  var menu by remember { mutableStateOf(false) }
  Box(modifier.fillMaxSize(), contentAlignment = Alignment.TopCenter) {
    Column(
      Modifier.widthIn(max = 640.dp)
        .fillMaxWidth()
        .verticalScroll(rememberScrollState())
        .padding(24.dp),
      verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
      Row(verticalAlignment = Alignment.CenterVertically) {
        Text(
          "Devices",
          modifier = Modifier.weight(1f).semantics { heading() },
          style = MaterialTheme.typography.titleMedium,
          color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Box {
          TextButton(onClick = { menu = true }, modifier = Modifier.heightIn(min = 48.dp)) {
            Text("Manage")
          }
          DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            DropdownMenuItem(
              text = { Text(if (hasTrustedDevices) "Pair or manage devices" else "Pair your Mac") },
              onClick = {
                menu = false
                onPair()
              },
            )
            DropdownMenuItem(
              text = { Text("Check nearby discovery") },
              onClick = {
                menu = false
                onCheck()
              },
            )
          }
        }
      }
      if (hasTrustedDevices) sessions()
      else {
        Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
          Text("No devices yet", style = MaterialTheme.typography.titleLarge)
          Text(
            "Scan its QR code or enter the six-digit code.",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
          )
          Button(onClick = onPair, modifier = Modifier.heightIn(min = 48.dp)) {
            Text("Pair your Mac")
          }
        }
      }
    }
  }
}
