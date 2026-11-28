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
import io.github.anisharyal09.anice.infrastructure.connections.ConnectionState
import io.github.anisharyal09.anice.infrastructure.connections.LanSessionController
import io.github.anisharyal09.anice.ui.AniCeActionButton
import io.github.anisharyal09.anice.ui.AutomaticConnectionToggle

@Composable
fun PrivateListeningView(
    controller: PrivateListeningController,
    phoneAudio: PhoneAudioController? = null,
    lan: LanSessionController? = null,
    connectLan: (() -> Unit)? = null,
) {
    val app = LocalContext.current.applicationContext as AniCeApplication
    val reverse = phoneAudio ?: app.phoneAudio
    LaunchedEffect(lan, controller.peer, reverse.peer) {
        if (lan != null && controller.peer == null && reverse.peer == null &&
            lan.state == ConnectionState.DISCONNECTED) {
            lan.requestAutomaticConnection()
        }
    }
    // Keep the current operation and its Stop above the inactive direction's setup.
    val directions = if (reverse.busy) listOf(true, false) else listOf(false, true)
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        if (lan != null && controller.peer == null && reverse.peer == null) {
            ListeningLanSetupSection(lan) {
                if (connectLan != null) connectLan()
                else if (!lan.requestAutomaticConnection()) lan.connectPreferred()
            }
            HorizontalDivider()
        }
        directions.forEachIndexed { index, sendingPhone ->
            if (index > 0) HorizontalDivider()
            key(sendingPhone) {
                if (sendingPhone) PhoneAudioView(reverse, controller.busy)
                else MacAudioReceivingView(controller, app)
            }
        }
    }
}

@Composable
private fun ListeningLanSetupSection(lan: LanSessionController, onConnectLan: () -> Unit) {
    val connecting = lan.state == ConnectionState.CONNECTING
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(stringResource(R.string.listening_lan_title), style = MaterialTheme.typography.titleSmall)
        Text(
            stringResource(when {
                connecting -> R.string.listening_lan_status_connecting
                lan.automatic -> R.string.listening_lan_status_auto_on
                else -> R.string.listening_lan_status_auto_off
            }),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        AutomaticConnectionToggle(
            checked = lan.automatic,
            enabled = true,
            onCheckedChange = { enabled ->
                lan.setAutomaticEnabled(enabled)
                if (enabled) lan.requestAutomaticConnection()
            },
            label = stringResource(R.string.listening_lan_auto_label),
            description = stringResource(R.string.listening_lan_auto_help),
            compact = true,
        )
        AniCeActionButton(onClick = onConnectLan, enabled = !connecting) {
            Text(stringResource(if (connecting) R.string.listening_lan_connecting else R.string.listening_lan_connect))
        }
    }
}

@Composable
private fun MacAudioReceivingView(controller: PrivateListeningController, app: AniCeApplication) {
    val context = LocalContext.current
    var revision by remember { mutableIntStateOf(0) }
    var confirmationError by remember { mutableStateOf(false) }
    var speakerConfirmation by remember {
        mutableStateOf<io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity?>(null)
    }
    val routes = remember(revision) {
        context.getSystemService(AudioManager::class.java).getDevices(AudioManager.GET_DEVICES_OUTPUTS)
            .filter { it.type in listOf(AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
                AudioDeviceInfo.TYPE_USB_DEVICE, AudioDeviceInfo.TYPE_USB_ACCESSORY) }
            .map { ListeningRoute(it.type, it.address.orEmpty(), it.productName.toString()) }
    }
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(stringResource(R.string.listening_from_mac), style = MaterialTheme.typography.titleSmall)
            Text(controller.peer?.deviceName ?: stringResource(R.string.listening_connect_mac),
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Text(controller.status, style = MaterialTheme.typography.bodyMedium)
        if (controller.active) {
            AniCeActionButton(onClick = { controller.stop() }) { Text(stringResource(R.string.listening_stop)) }
        } else if (controller.busy) {
            AniCeActionButton(onClick = {}, enabled = false) { Text(stringResource(R.string.listening_stopping)) }
        }
        AutomaticConnectionToggle(checked = controller.consentEnabled, onCheckedChange = controller::setConsent,
            enabled = controller.canSetConsent, label = stringResource(R.string.listening_receive),
            description = stringResource(R.string.listening_setup), compact = true)
        AutomaticConnectionToggle(checked = controller.speakerFallbackEnabled,
            enabled = controller.canSetConsent && (!controller.busy || (controller.active && controller.speakerFallbackEnabled)),
            onCheckedChange = { enabled ->
                if (enabled) speakerConfirmation = controller.peer else controller.setSpeakerFallback(false)
            }, label = stringResource(R.string.listening_speaker_fallback),
            description = stringResource(R.string.listening_speaker_help), compact = true)
        if (speakerConfirmation != null) AlertDialog(onDismissRequest = { speakerConfirmation = null },
            title = { Text(stringResource(R.string.listening_speaker_confirm_title)) },
            text = { Text(stringResource(R.string.listening_speaker_confirm_help)) },
            confirmButton = { TextButton(shape = MaterialTheme.shapes.small, onClick = {
                val confirmedPeer = speakerConfirmation
                speakerConfirmation = null
                if (confirmedPeer == controller.peer) controller.setSpeakerFallback(true)
            }) { Text(stringResource(R.string.listening_speaker_allow)) } },
            dismissButton = { TextButton(shape = MaterialTheme.shapes.small,
                onClick = { speakerConfirmation = null }) { Text(stringResource(R.string.cancel)) } })
        Text(stringResource(R.string.listening_buffer_mode), style = MaterialTheme.typography.titleSmall)
        Column(Modifier.selectableGroup()) {
            for (profile in ListeningBufferProfile.entries) {
                Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).selectable(
                    selected = controller.bufferProfile == profile,
                    enabled = !controller.busy, role = Role.RadioButton,
                    onClick = { controller.setBufferProfile(profile) }),
                    verticalAlignment = Alignment.CenterVertically) {
                    RadioButton(selected = controller.bufferProfile == profile,
                        onClick = null, enabled = !controller.busy)
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
            Text(stringResource(R.string.listening_recovery_diagnostics,
                health.gapRecoveries, health.rebufferCount, health.maximumArrivalGapMillis),
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            if (health.routeType == AudioDeviceInfo.TYPE_BLUETOOTH_A2DP ||
                health.routeType == AudioDeviceInfo.TYPE_BLE_HEADSET) {
                Text(stringResource(R.string.listening_bluetooth_delay), style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        if (!controller.active && routes.isEmpty() && !controller.speakerFallbackEnabled) Text(stringResource(R.string.listening_headphone_hint),
            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        for (route in routes) {
            val key = route.confirmationKey
            Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(route.label,
                    style = MaterialTheme.typography.bodyMedium)
                AniCeActionButton(onClick = {
                    if (key != null) {
                        val storage = context.getSharedPreferences("private_listening_routes", android.content.Context.MODE_PRIVATE)
                        val values = app.listeningConfirmedRoutes() + key
                        if (storage.edit().putStringSet("headphones", values).commit()) {
                            confirmationError = false
                            revision++
                        } else confirmationError = true
                    }
                }, enabled = key != null && !controller.busy && key !in app.listeningConfirmedRoutes()) {
                    Text(if (key in app.listeningConfirmedRoutes()) stringResource(R.string.listening_confirmed)
                        else stringResource(R.string.listening_confirm_route))
                }
            }
        }
        if (confirmationError) Text(stringResource(R.string.listening_confirmation_failed))
        AniCeActionButton(onClick = { revision++ }) {
            Text(stringResource(R.string.listening_refresh_outputs))
        }
    }
}
