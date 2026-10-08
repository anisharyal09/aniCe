// SPDX-License-Identifier: GPL-3.0-or-later
package io.github.anisharyal09.anice.features.session

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import io.github.anisharyal09.anice.infrastructure.pairing.PeerTrustRecord

@Composable
fun SessionPanel(model: SessionViewModel, peers: List<PeerTrustRecord>) {
  val permissions =
    rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
      model.permissionReturned()
    }
  val active = model.state == ConnectionState.CONNECTING || model.state == ConnectionState.SECURED
  Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
    peers.forEachIndexed { index, record ->
      key(record.peer.deviceId) {
        val selected = model.selected?.deviceId == record.peer.deviceId
        DeviceSessionCard(
          name = record.peer.deviceName,
          fingerprint = record.peer.fingerprint,
          state = if (selected) model.state else ConnectionState.DISCONNECTED,
          status =
            if (selected) model.status
            else if (active) "Disconnect your current Mac to connect to this one."
            else "Open Allow connections on your Mac, then connect here.",
          canConnect = !active,
          onConnect = {
            model.request(record.peer)
            val missing = model.missingPermissions()
            if (missing.isNotEmpty()) permissions.launch(missing)
          },
          onDisconnect = model::disconnect,
          onCheck = model::checkConnection,
        )
      }
      if (index < peers.lastIndex)
        HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
    }
  }
}

@Composable
fun DeviceSessionCard(
  name: String,
  fingerprint: String,
  state: ConnectionState,
  status: String,
  canConnect: Boolean,
  onConnect: () -> Unit,
  onDisconnect: () -> Unit,
  onCheck: () -> Unit,
) {
  var menu by remember { mutableStateOf(false) }
  val statusColor =
    when (state) {
      ConnectionState.SECURED -> MaterialTheme.colorScheme.tertiary
      ConnectionState.FAILED -> MaterialTheme.colorScheme.error
      else -> MaterialTheme.colorScheme.onSurfaceVariant
    }
  Column(
    Modifier.fillMaxWidth().padding(vertical = 8.dp),
    verticalArrangement = Arrangement.spacedBy(12.dp),
  ) {
    Text(
      name,
      modifier = Modifier.semantics { heading() },
      style = MaterialTheme.typography.titleLarge,
      fontWeight = FontWeight.Medium,
    )
    // This prefix is a visual identifier; authentication uses the complete pinned credential.
    Text(
      stateLabel(state) + " · " + fingerprint.take(8).chunked(4).joinToString(" "),
      modifier =
        Modifier.semantics {
          contentDescription = "${stateLabel(state)}. Fingerprint ${fingerprint.take(8)}"
        },
      style = MaterialTheme.typography.bodyMedium,
      color = statusColor,
    )
    if (status.isNotBlank())
      Text(
        status,
        modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
        style = MaterialTheme.typography.bodyMedium,
        color =
          if (state == ConnectionState.FAILED) MaterialTheme.colorScheme.error
          else MaterialTheme.colorScheme.onSurfaceVariant,
      )
    if (state == ConnectionState.CONNECTING) LinearProgressIndicator(Modifier.fillMaxWidth())
    Row(
      verticalAlignment = Alignment.CenterVertically,
      horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
      if (state == ConnectionState.SECURED || state == ConnectionState.CONNECTING) {
        TextButton(onClick = onDisconnect, modifier = Modifier.heightIn(min = 48.dp)) {
          Text(if (state == ConnectionState.CONNECTING) "Cancel" else "Disconnect")
        }
      } else {
        Button(
          onClick = onConnect,
          enabled = canConnect,
          modifier = Modifier.heightIn(min = 48.dp),
        ) {
          Text(if (state == ConnectionState.FAILED) "Retry" else "Connect")
        }
      }
      if (state == ConnectionState.SECURED)
        Box {
          TextButton(onClick = { menu = true }, modifier = Modifier.heightIn(min = 48.dp)) {
            Text("More")
          }
          DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            DropdownMenuItem(
              text = { Text("Send connection check") },
              onClick = {
                menu = false
                onCheck()
              },
            )
          }
        }
    }
  }
}

private fun stateLabel(state: ConnectionState): String =
  when (state) {
    ConnectionState.DISCONNECTED -> "Disconnected"
    ConnectionState.CONNECTING -> "Connecting"
    ConnectionState.SECURED -> "Secured"
    ConnectionState.FAILED -> "Connection failed"
  }
