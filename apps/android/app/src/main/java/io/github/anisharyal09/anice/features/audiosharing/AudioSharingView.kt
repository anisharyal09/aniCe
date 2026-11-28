// SPDX-License-Identifier: GPL-3.0-or-later
// Presents credential-scoped receiving consent and explicit headphone confirmation without remotely opening setup UI.
package io.github.anisharyal09.anice.features.audiosharing

import android.media.AudioDeviceInfo
import android.media.AudioManager
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.unit.dp
import io.github.anisharyal09.anice.AniCeApplication
import io.github.anisharyal09.anice.R
import io.github.anisharyal09.anice.infrastructure.connections.ConnectionState
import io.github.anisharyal09.anice.infrastructure.connections.LanSessionController
import io.github.anisharyal09.anice.ui.AniCeActionButton
import io.github.anisharyal09.anice.ui.AutomaticConnectionToggle

@Composable
internal fun AudioSharingView(
    controller: AudioSharingController,
    phoneAudio: PhoneAudioController,
    lan: LanSessionController? = null,
    pauseStatus: String? = null,
    connectLan: (() -> Unit)? = null,
    openDevices: () -> Unit = {},
) {
    val app = LocalContext.current.applicationContext as AniCeApplication
    val needsLan = controller.peer == null && phoneAudio.peer == null && !controller.busy && !phoneAudio.busy
    LaunchedEffect(lan, needsLan, pauseStatus) {
        if (needsLan && pauseStatus == null) lan?.requestAutomaticConnection()
    }
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        ListeningNote(stringResource(R.string.listening_overview))
        if (lan != null && needsLan) {
            ListeningLanSetupSection(lan, pauseStatus, connectLan, openDevices)
        } else {
            val directions = if (phoneAudio.busy) listOf(true, false) else listOf(false, true)
            directions.forEachIndexed { index, sendingPhone ->
                if (index > 0) HorizontalDivider()
                key(sendingPhone) {
                    if (sendingPhone) PhoneAudioView(phoneAudio, controller.busy)
                    else MacAudioReceivingView(controller, app)
                }
            }
        }
    }
}

@Composable
private fun ListeningLanSetupSection(
    lan: LanSessionController,
    pauseStatus: String?,
    connectLan: (() -> Unit)?,
    openDevices: () -> Unit,
) {
    val connecting = lan.state == ConnectionState.CONNECTING
    val status = pauseStatus ?: when {
        lan.verifyingConnection -> stringResource(R.string.listening_lan_checking)
        connecting || lan.state == ConnectionState.FAILED -> lan.status
        connectLan == null -> stringResource(R.string.listening_lan_choose_mac)
        else -> stringResource(R.string.listening_lan_help)
    }
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(stringResource(R.string.listening_lan_title), style = MaterialTheme.typography.titleSmall)
        ListeningNote(status)
        AutomaticConnectionToggle(
            checked = lan.automatic,
            enabled = pauseStatus == null,
            onCheckedChange = {
                lan.setAutomaticEnabled(it)
                if (it) lan.requestAutomaticConnection()
            },
            label = stringResource(R.string.listening_lan_auto_label),
            description = stringResource(R.string.listening_lan_auto_help),
            compact = true,
        )
        if (connectLan == null || pauseStatus != null) {
            AniCeActionButton(onClick = openDevices) { Text(stringResource(R.string.listening_open_devices)) }
        } else {
            AniCeActionButton(onClick = connectLan, enabled = !connecting && !lan.verifyingConnection,
                prominent = !connecting && !lan.verifyingConnection) {
                Text(stringResource(if (connecting) R.string.listening_lan_connecting else R.string.listening_lan_connect))
            }
        }
    }
}

@Composable
private fun MacAudioReceivingView(controller: AudioSharingController, app: AniCeApplication) {
    val context = LocalContext.current
    var revision by remember { mutableIntStateOf(0) }
    var confirmationError by remember { mutableStateOf(false) }
    var moreOptions by rememberSaveable { mutableStateOf(false) }
    var speakerConfirmation by remember {
        mutableStateOf<io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity?>(null)
    }
    val outputs = remember(revision) {
        context.getSystemService(AudioManager::class.java).getDevices(AudioManager.GET_DEVICES_OUTPUTS)
            .map { ListeningRoute(it.type, it.address.orEmpty(), it.productName.toString()) }
    }
    val confirmedRoutes = remember(revision) { app.listeningConfirmedRoutes() }
    val hasHeadphones = outputs.any { AudioSharingRoutes.privateOutput(it, confirmedRoutes) }
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(stringResource(R.string.listening_from_mac), style = MaterialTheme.typography.titleSmall)
            controller.peer?.deviceName?.let { ListeningNote(it) }
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
        if (!controller.busy) {
            if (!hasHeadphones && !controller.speakerFallbackEnabled) {
                ListeningNote(stringResource(R.string.listening_headphone_hint))
            }
            for (route in outputs.filter {
                it.type == AudioDeviceInfo.TYPE_BLUETOOTH_A2DP ||
                    it.type == AudioDeviceInfo.TYPE_USB_DEVICE || it.type == AudioDeviceInfo.TYPE_USB_ACCESSORY
            }) {
                val key = route.confirmationKey
                Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(route.label, style = MaterialTheme.typography.bodyMedium)
                    when {
                        key == null -> ListeningNote(stringResource(R.string.listening_cannot_confirm))
                        key in confirmedRoutes -> ListeningNote(stringResource(R.string.listening_confirmed))
                        else -> AniCeActionButton(onClick = {
                            val storage = context.getSharedPreferences("private_listening_routes", android.content.Context.MODE_PRIVATE)
                            confirmationError = !storage.edit().putStringSet("headphones",
                                app.listeningConfirmedRoutes() + key).commit()
                            if (!confirmationError) revision++
                        }) {
                            Text(stringResource(R.string.listening_confirm_route))
                        }
                    }
                }
            }
            if (confirmationError) ListeningNote(stringResource(R.string.listening_confirmation_failed))
            AniCeActionButton(onClick = { revision++ }) {
                Text(stringResource(R.string.listening_refresh_outputs))
            }
        }
        val optionsState = stringResource(if (moreOptions) R.string.listening_options_expanded else R.string.listening_options_collapsed)
        TextButton(onClick = { moreOptions = !moreOptions }, shape = MaterialTheme.shapes.small,
            contentPadding = PaddingValues(0.dp),
            modifier = Modifier.heightIn(min = 48.dp).semantics { stateDescription = optionsState }) {
            Text(stringResource(if (moreOptions) R.string.listening_hide_options else R.string.listening_show_options))
        }
        if (moreOptions) ListeningPlaybackOptions(controller)
    }
}

@Composable
internal fun ListeningNote(text: String) {
    Text(text, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
}

@Composable
private fun ListeningPlaybackOptions(controller: AudioSharingController) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
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
        ListeningNote(stringResource(R.string.listening_buffer_help))
        controller.diagnostics?.let { health ->
            ListeningNote(stringResource(R.string.listening_buffer_diagnostics,
                health.queuedFrames / 48, health.targetFrames / 48,
                health.nativeQueuedFrames / 48, health.droppedPackets, health.underruns))
            ListeningNote(stringResource(R.string.listening_native_diagnostics,
                health.nativeWriteLimitFrames / 48, health.nativeBufferFrames / 48))
            ListeningNote(stringResource(R.string.listening_recovery_diagnostics,
                health.gapRecoveries, health.rebufferCount, health.maximumArrivalGapMillis))
            if (health.routeType == AudioDeviceInfo.TYPE_BLUETOOTH_A2DP ||
                health.routeType == AudioDeviceInfo.TYPE_BLE_HEADSET) {
                ListeningNote(stringResource(R.string.listening_bluetooth_delay))
            }
        }
    }
}
