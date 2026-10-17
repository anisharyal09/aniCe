// SPDX-License-Identifier: GPL-3.0-or-later
// Presents peer-scoped Find Device actions and local notification setup using Android resources.
package io.github.anisharyal09.anice.features.finddevice

import android.Manifest
import android.content.Intent
import android.os.Build
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import io.github.anisharyal09.anice.R
import io.github.anisharyal09.anice.features.session.primaryPeers
import io.github.anisharyal09.anice.infrastructure.pairing.PeerTrustRecord

@Composable
fun FindDeviceView(owner: FindDeviceController, peers: List<PeerTrustRecord>, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val native = (context.applicationContext as io.github.anisharyal09.anice.AniCeApplication).findDeviceNotification
    var permitted by remember { mutableStateOf(native.permitted()) }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { permitted = native.permitted() }
    val lifecycle = androidx.lifecycle.compose.LocalLifecycleOwner.current.lifecycle
    DisposableEffect(lifecycle) {
        val observer = androidx.lifecycle.LifecycleEventObserver { _, event ->
            if (event == androidx.lifecycle.Lifecycle.Event.ON_RESUME) permitted = native.permitted()
        }
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer) }
    }
    Column(modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Text(stringResource(R.string.find_explanation), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        if (permitted) {
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
                Text(stringResource(R.string.find_local_allowed), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.weight(1f, fill = false))
                TextButton(
                    onClick = {
                        context.startActivity(Intent(Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS)
                            .putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName).putExtra(Settings.EXTRA_CHANNEL_ID, FindDeviceNotification.CHANNEL))
                    },
                    contentPadding = PaddingValues(horizontal = 8.dp, vertical = 0.dp),
                    modifier = Modifier.heightIn(min = 48.dp)
                ) {
                    Text(stringResource(R.string.find_settings), style = MaterialTheme.typography.bodySmall)
                }
            }
        } else {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(stringResource(R.string.find_local_blocked), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
                FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    OutlinedButton(onClick = {
                        if (Build.VERSION.SDK_INT >= 33) permission.launch(Manifest.permission.POST_NOTIFICATIONS)
                        else context.startActivity(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName))
                    }) { Text(stringResource(R.string.find_permission)) }
                    TextButton(onClick = {
                        context.startActivity(Intent(Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS)
                            .putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName).putExtra(Settings.EXTRA_CHANNEL_ID, FindDeviceNotification.CHANNEL))
                    }) {
                        Text(stringResource(R.string.find_settings))
                    }
                }
            }
        }
        if (peers.isEmpty()) {
            Text(stringResource(R.string.find_pair_first), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        } else {
            HorizontalDivider()
            primaryPeers(peers) { owner.connected(it.peer) }.forEach { record ->
                Row(
                    modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = androidx.compose.ui.Alignment.CenterVertically
                ) {
                    Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Text(record.peer.deviceName, style = MaterialTheme.typography.titleSmall)
                        val status = if (!owner.supports(record.peer)) {
                            if (owner.connected(record.peer)) stringResource(R.string.find_not_advertised)
                            else stringResource(R.string.find_connect_first)
                        } else if (owner.connected(record.peer)) {
                            stringResource(R.string.find_connected)
                        } else {
                            stringResource(R.string.find_connect_first)
                        }
                        Text(status, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    val findLabel = stringResource(R.string.find_peer_action, record.peer.deviceName)
                    OutlinedButton(
                        onClick = { owner.find(record.peer) },
                        enabled = owner.canFind(record.peer),
                        modifier = Modifier.heightIn(min = 48.dp).semantics { contentDescription = findLabel }
                    ) {
                        Text(stringResource(R.string.find_title))
                    }
                }
            }
        }
        owner.feedbackPeer?.let { if (owner.feedbackKey != "find_idle") Text(it.deviceName, style = MaterialTheme.typography.bodySmall) }
        val showIdle = owner.feedbackKey == "find_idle" && peers.isEmpty()
        if (showIdle || (owner.feedbackKey != "find_idle" && owner.feedbackKey.isNotEmpty())) {
            FindDeviceFeedback(owner)
        }
    }
}

@Composable fun FindDeviceFeedback(owner: FindDeviceController) {
    val resource = when (owner.feedbackKey) {
        "find_waiting" -> R.string.find_waiting
        "find_submitted" -> R.string.find_submitted
        "find_blocked" -> R.string.find_blocked
        "find_stale" -> R.string.find_stale
        "find_busy" -> R.string.find_busy
        "find_failed" -> R.string.find_failed
        "find_timeout" -> R.string.find_timeout
        "find_disconnected" -> R.string.find_disconnected
        else -> R.string.find_idle
    }
    Text(stringResource(resource), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
}
