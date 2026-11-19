// SPDX-License-Identifier: GPL-3.0-or-later
// Presents credential-scoped receiving consent and explicit headphone confirmation without remotely opening setup UI.
package io.github.anisharyal09.anice.features.privatelistening

import android.media.AudioDeviceInfo
import android.media.AudioManager
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import io.github.anisharyal09.anice.AniCeApplication
import io.github.anisharyal09.anice.R

@Composable
fun PrivateListeningView(controller: PrivateListeningController) {
    val context = LocalContext.current
    val app = context.applicationContext as AniCeApplication
    var revision by remember { mutableIntStateOf(0) }
    var confirmationError by remember { mutableStateOf(false) }
    val routes = remember(revision) {
        context.getSystemService(AudioManager::class.java).getDevices(AudioManager.GET_DEVICES_OUTPUTS)
            .filter { it.type in listOf(AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
                AudioDeviceInfo.TYPE_USB_DEVICE, AudioDeviceInfo.TYPE_USB_ACCESSORY) }
            .map { ListeningRoute(it.type, it.address.orEmpty(), it.productName.toString()) }
    }
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(controller.peer?.deviceName ?: stringResource(R.string.listening_connect_mac),
            style = MaterialTheme.typography.titleSmall)
        Text(stringResource(R.string.listening_setup), style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant)
        Row(Modifier.fillMaxWidth().heightIn(min = 48.dp), verticalAlignment = Alignment.CenterVertically) {
            Checkbox(checked = controller.consentEnabled, onCheckedChange = controller::setConsent,
                enabled = controller.peer != null)
            Text(stringResource(R.string.listening_receive))
        }
        Text(controller.status, style = MaterialTheme.typography.bodyMedium)
        if (controller.active) {
            Button(onClick = { controller.stop() }) { Text(stringResource(R.string.listening_stop)) }
        }
        Text(stringResource(R.string.listening_buffer_mode), style = MaterialTheme.typography.titleSmall)
        Column(Modifier.selectableGroup()) {
            for (profile in ListeningBufferProfile.entries) {
                Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).selectable(
                    selected = controller.bufferProfile == profile,
                    enabled = !controller.active, role = Role.RadioButton,
                    onClick = { controller.setBufferProfile(profile) }),
                    verticalAlignment = Alignment.CenterVertically) {
                    RadioButton(selected = controller.bufferProfile == profile,
                        onClick = null, enabled = !controller.active)
                    Text(stringResource(if (profile == ListeningBufferProfile.BALANCED)
                        R.string.listening_buffer_balanced else R.string.listening_buffer_lower),
                        modifier = Modifier.padding(start = 8.dp), style = MaterialTheme.typography.bodyMedium)
                }
            }
        }
        Text(stringResource(R.string.listening_buffer_help), style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant)
        controller.diagnostics?.let { health ->
            Text(stringResource(R.string.listening_buffer_diagnostics,
                health.queuedFrames / 48, health.targetFrames / 48,
                health.nativeQueuedFrames / 48, health.droppedPackets, health.underruns),
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Text(stringResource(R.string.listening_native_diagnostics,
                health.nativeWriteLimitFrames / 48, health.nativeBufferFrames / 48),
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            if (health.routeType == AudioDeviceInfo.TYPE_BLUETOOTH_A2DP ||
                health.routeType == AudioDeviceInfo.TYPE_BLE_HEADSET) {
                Text(stringResource(R.string.listening_bluetooth_delay), style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        if (!controller.active && routes.isEmpty()) Text(stringResource(R.string.listening_headphone_hint),
            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        for (route in routes) {
            val key = route.confirmationKey
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text(route.label, modifier = Modifier.weight(1f).padding(end = 8.dp),
                    style = MaterialTheme.typography.bodyMedium)
                TextButton(onClick = {
                    if (key != null) {
                        val storage = context.getSharedPreferences("private_listening_routes", android.content.Context.MODE_PRIVATE)
                        val values = app.listeningConfirmedRoutes() + key
                        if (storage.edit().putStringSet("headphones", values).commit()) {
                            confirmationError = false
                            revision++
                        } else confirmationError = true
                    }
                }, enabled = key != null && !controller.active, modifier = Modifier.heightIn(min = 48.dp)) {
                    Text(if (key in app.listeningConfirmedRoutes()) stringResource(R.string.listening_confirmed)
                        else stringResource(R.string.listening_confirm_route))
                }
            }
        }
        if (confirmationError) Text(stringResource(R.string.listening_confirmation_failed))
        TextButton(onClick = { revision++ }, modifier = Modifier.heightIn(min = 48.dp)) {
            Text(stringResource(R.string.listening_refresh_outputs))
        }
    }
}
