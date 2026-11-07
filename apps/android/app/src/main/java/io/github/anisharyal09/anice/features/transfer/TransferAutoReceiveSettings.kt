// SPDX-License-Identifier: GPL-3.0-or-later
// Presents local automatic-receive consent for trusted Mac senders.
package io.github.anisharyal09.anice.features.transfer

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import io.github.anisharyal09.anice.infrastructure.pairing.PeerTrustRecord
import io.github.anisharyal09.anice.ui.AutomaticConnectionToggle

@Composable
fun TransferAutoReceiveSettings(
    preferences: TransferAutoReceivePreferences,
    peers: List<PeerTrustRecord>,
    compact: Boolean = false,
    modifier: Modifier = Modifier,
) {
    val senders = peers.filter { it.peer.platform == "macos" }
    val peerKeys = senders.joinToString("|") { preferences.key(it.peer) }
    val revision = preferences.revision
    val enabled by remember(peerKeys, revision) {
        mutableStateOf(senders.associate { preferences.key(it.peer) to preferences.enabled(it.peer) })
    }

    Column(modifier, verticalArrangement = Arrangement.spacedBy(if (compact) 0.dp else 4.dp)) {
        Text("Automatically receive files", style = if (compact) androidx.compose.material3.MaterialTheme.typography.labelLarge
            else androidx.compose.material3.MaterialTheme.typography.titleSmall)
        if (senders.isEmpty()) {
            Text("Pair a Mac first.",
                style = androidx.compose.material3.MaterialTheme.typography.bodySmall,
                color = androidx.compose.material3.MaterialTheme.colorScheme.onSurfaceVariant)
        } else {
            senders.forEach { record ->
                val key = preferences.key(record.peer)
                val checked = enabled[key] == true
                val duplicate = senders.count { it.peer.deviceName == record.peer.deviceName } > 1
                val name = if (duplicate) "Mac · ${record.peer.deviceName} · ${record.peer.fingerprint.takeLast(8)}"
                    else "Mac · ${record.peer.deviceName}"
                val update: (Boolean) -> Unit = { value -> preferences.set(record.peer, value) }
                AutomaticConnectionToggle(
                    checked = checked,
                    enabled = true,
                    onCheckedChange = update,
                    label = name,
                    compact = true,
                )
            }
            Text("For background receipt, turn on Connect automatically.",
                style = androidx.compose.material3.MaterialTheme.typography.bodySmall,
                color = androidx.compose.material3.MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(bottom = if (compact) 0.dp else 8.dp))
        }
    }
}
