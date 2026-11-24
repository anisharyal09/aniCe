// SPDX-License-Identifier: GPL-3.0-or-later
// Requests explicit single-use capture consent for a local phone-to-Mac sharing action.
package io.github.anisharyal09.anice.features.privatelistening

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.media.projection.MediaProjectionManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import io.github.anisharyal09.anice.R
import io.github.anisharyal09.anice.ui.AniCeActionButton

@Composable
fun PhoneAudioView(controller: PhoneAudioController, forwardActive: Boolean) {
    val context = LocalContext.current
    val manager = remember { context.getSystemService(MediaProjectionManager::class.java) }
    var consentID by remember { mutableStateOf<String?>(null) }
    DisposableEffect(controller) {
        onDispose { controller.captureConsentDenied(consentID) }
    }
    val projection = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        val id = consentID
        consentID = null
        val data = result.data
        if (result.resultCode == Activity.RESULT_OK && data != null) {
            controller.completeConsent(id, PhoneAudioGrant(result.resultCode, data))
        } else controller.captureConsentDenied(id)
    }
    val launchProjection = {
        if (controller.consentIsCurrent(consentID)) {
            try { projection.launch(manager.createScreenCaptureIntent()) }
            catch (_: Exception) { controller.captureConsentDenied(consentID); consentID = null }
        } else consentID = null
    }
    val recordAudio = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) launchProjection()
        else { controller.capturePermissionDenied(consentID); consentID = null }
    }
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(stringResource(R.string.phone_audio_title), style = MaterialTheme.typography.titleSmall)
        Text(controller.status, style = MaterialTheme.typography.bodyMedium)
        if (controller.active) {
            AniCeActionButton(onClick = { controller.stop() }) { Text(stringResource(R.string.phone_audio_stop)) }
        } else if (controller.stopping || controller.controlPending) {
            AniCeActionButton(onClick = {}, enabled = false) { Text(stringResource(R.string.listening_stopping)) }
        } else {
            AniCeActionButton(onClick = {
                consentID = controller.requestConsent()
                if (consentID == null) return@AniCeActionButton
                if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) ==
                    PackageManager.PERMISSION_GRANTED) launchProjection()
                else recordAudio.launch(Manifest.permission.RECORD_AUDIO)
            }, enabled = controller.canStart && consentID == null && !forwardActive, prominent = true) {
                Text(stringResource(if (controller.consentPending || consentID != null)
                    R.string.phone_audio_waiting_consent else R.string.phone_audio_start))
            }
        }
        Text(stringResource(R.string.phone_audio_help), style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(stringResource(R.string.phone_audio_consent_note), style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant)
        if (controller.droppedPackets > 0) {
            Text(stringResource(R.string.phone_audio_dropped, controller.droppedPackets),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}
