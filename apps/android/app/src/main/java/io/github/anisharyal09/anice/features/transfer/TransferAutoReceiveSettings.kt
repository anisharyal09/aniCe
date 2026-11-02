// SPDX-License-Identifier: GPL-3.0-or-later
// Presents local automatic-receive consent for trusted Mac senders.
package io.github.anisharyal09.anice.features.transfer

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import io.github.anisharyal09.anice.infrastructure.pairing.PeerTrustRecord

@Composable
fun TransferAutoReceiveSettings(
    preferences: TransferAutoReceivePreferences,
    peers: List<PeerTrustRecord>,
    compact: Boolean = false,
) {
    val senders = peers.filter { it.peer.platform == "macos" }
    val peerKeys = senders.joinToString("|") { preferences.key(it.peer) }
    val revision = preferences.revision
    val enabled by remember(peerKeys, revision) {
        mutableStateOf(senders.associate { preferences.key(it.peer) to preferences.enabled(it.peer) })
    }

    Column(verticalArrangement = Arrangement.spacedBy(if (compact) 2.dp else 4.dp)) {
        Text("Automatically receive files", style = if (compact) androidx.compose.material3.MaterialTheme.typography.labelLarge
            else androidx.compose.material3.MaterialTheme.typography.titleSmall)
        if (senders.isEmpty()) {
            Text("Pair a Mac to manage automatic receiving.",
                style = androidx.compose.material3.MaterialTheme.typography.bodySmall,
                color = androidx.compose.material3.MaterialTheme.colorScheme.onSurfaceVariant)
        } else {
            senders.forEach { record ->
                val key = preferences.key(record.peer)
                val checked = enabled[key] == true
                val duplicate = senders.count { it.peer.deviceName == record.peer.deviceName } > 1
                val name = if (duplicate) "${record.peer.deviceName} · ${record.peer.fingerprint.takeLast(8)}"
                    else record.peer.deviceName
                val update: (Boolean) -> Unit = { value -> preferences.set(record.peer, value) }
                Row(
                    Modifier.fillMaxWidth().heightIn(min = 52.dp)
                        .clickable(role = Role.Switch, onClickLabel = "Toggle automatic receive from $name") { update(!checked) }
                        .padding(vertical = 4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(12.dp)
                ) {
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Text("From $name", style = androidx.compose.material3.MaterialTheme.typography.bodyMedium)
                        Text("Trusted Mac", style = androidx.compose.material3.MaterialTheme.typography.bodySmall,
                            color = androidx.compose.material3.MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    Switch(checked = checked, onCheckedChange = update)
                }
            }
            Text("Enabled Macs can send without asking each time. Files use the saved receive folder; you can cancel an active transfer.",
                style = androidx.compose.material3.MaterialTheme.typography.bodySmall,
                color = androidx.compose.material3.MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}
