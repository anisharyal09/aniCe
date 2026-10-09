// SPDX-License-Identifier: GPL-3.0-or-later
package io.github.anisharyal09.anice.features.session

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import android.content.Intent
import androidx.compose.ui.platform.LocalContext
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
  val nearby = io.github.anisharyal09.anice.features.backgroundprobe.CompanionProbe.get(LocalContext.current)
  val permissions =
    rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
      model.permissionReturned()
    }
  val active = model.state == ConnectionState.CONNECTING || model.state == ConnectionState.SECURED
  Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
    peers.forEachIndexed { index, record ->
      key(record.peer.deviceId) {
        val selected = model.selected?.deviceId == record.peer.deviceId
        val waiting = nearby.armed && nearby.peerId == record.peer.deviceId &&
          (!selected || model.state == ConnectionState.FAILED || model.state == ConnectionState.DISCONNECTED)
        DeviceSessionCard(
          name = record.peer.deviceName,
          fingerprint = record.peer.fingerprint,
          state = if (selected && !waiting) model.state else ConnectionState.DISCONNECTED,
          status =
            if (waiting) nearby.status.takeUnless { it == "Waiting nearby." }.orEmpty()
            else if (selected) model.status
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
          probePeerId = record.peer.deviceId,
          automaticWaiting = waiting,
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
  probePeerId: String? = null,
  automaticWaiting: Boolean = false,
) {
  val context = LocalContext.current
  // Device settings expose availability truth; a gated owner cannot start background work.
  val probeIntent = remember(probePeerId) {
    Intent().setClassName(context, "io.github.anisharyal09.anice.features.backgroundprobe.CompanionProbeActivity")
      .putExtra("peer", probePeerId)
  }
  val hasProbe = probePeerId != null && context.packageManager.resolveActivity(probeIntent, 0) != null
  val label = if (automaticWaiting) "Waiting nearby" else stateLabel(state)
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
      label + " · " + fingerprint.take(8).chunked(4).joinToString(" "),
      modifier =
        Modifier.semantics {
          contentDescription = "$label. Fingerprint ${fingerprint.take(8)}"
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
      if (state == ConnectionState.SECURED || state == ConnectionState.CONNECTING || automaticWaiting) {
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
      if (state == ConnectionState.SECURED || hasProbe)
        Box {
          TextButton(onClick = { menu = true }, modifier = Modifier.heightIn(min = 48.dp)) {
            Text("More")
          }
          DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            if (hasProbe) DropdownMenuItem(text = { Text("Connection settings") }, onClick = {
              menu = false
              context.startActivity(probeIntent)
            })
            if (state == ConnectionState.SECURED) DropdownMenuItem(
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
