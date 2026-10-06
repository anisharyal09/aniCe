// SPDX-License-Identifier: GPL-3.0-or-later
package io.github.anisharyal09.anice.features.deviceidentity

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.os.Build
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import io.github.anisharyal09.anice.R
import io.github.anisharyal09.anice.infrastructure.identity.IdentityErrorKind
import kotlinx.coroutines.launch

@Composable
fun DeviceIdentityScreen(
    state: DeviceIdentityUiState,
    snackbars: SnackbarHostState,
    onRetry: () -> Unit,
    onReset: () -> Unit,
    modifier: Modifier = Modifier,
) {
    var confirmation by rememberSaveable { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    val deviceIdLabel = stringResource(R.string.device_id)
    val fingerprintLabel = stringResource(R.string.fingerprint)
    val copiedLabel = stringResource(R.string.copied)
    if (confirmation) AlertDialog(
        onDismissRequest = { confirmation = false },
        title = { Text(stringResource(R.string.reset_identity_title)) },
        text = { Text(stringResource(R.string.reset_identity_warning)) },
        confirmButton = {
            TextButton(onClick = { confirmation = false; onReset() }, enabled = !state.isWorking) {
                Text(stringResource(R.string.reset_identity), color = MaterialTheme.colorScheme.error)
            }
        },
        dismissButton = {
            TextButton(onClick = { confirmation = false }) { Text(stringResource(R.string.cancel)) }
        },
    )
    Column(modifier.fillMaxSize()
        .verticalScroll(rememberScrollState()).padding(24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        if (state.isWorking) LinearProgressIndicator(Modifier.fillMaxWidth())
        state.snapshot?.let { current ->
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(current.identity.deviceName, style = MaterialTheme.typography.headlineSmall)
                Text(stringResource(R.string.android_platform), style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            Text(stringResource(R.string.identity_description), style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
            Surface(shape = MaterialTheme.shapes.large, color = MaterialTheme.colorScheme.surface,
                modifier = Modifier.fillMaxWidth()) {
                Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                    IdentityField(deviceIdLabel, current.identity.deviceId) {
                        copyText(context, deviceIdLabel, current.identity.deviceId)
                        if (Build.VERSION.SDK_INT < 33) scope.launch { snackbars.showSnackbar(copiedLabel) }
                    }
                    HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
                    IdentityField(fingerprintLabel,
                        current.identity.fingerprint.chunked(32).joinToString("\n") { it.chunked(4).joinToString(" ") }) {
                        copyText(context, fingerprintLabel, current.identity.fingerprint)
                        if (Build.VERSION.SDK_INT < 33) scope.launch { snackbars.showSnackbar(copiedLabel) }
                    }
                    Text(stringResource(R.string.fingerprint_description), style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                    HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
                    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Text(stringResource(R.string.key_protection), style = MaterialTheme.typography.titleSmall)
                        Text(current.protection.label, style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
        }
        state.failure?.let { error ->
            Text(stringResource(R.string.identity_unavailable), style = MaterialTheme.typography.titleMedium,
                color = MaterialTheme.colorScheme.error)
            Text(stringResource(when (error) {
                IdentityErrorKind.STORAGE_UNAVAILABLE -> R.string.identity_storage_unavailable
                IdentityErrorKind.KEY_MISSING -> R.string.identity_key_missing
                IdentityErrorKind.INCONSISTENT -> R.string.identity_inconsistent
                IdentityErrorKind.CRYPTO_FAILURE -> R.string.identity_crypto_failure
            }))
            Button(onClick = onRetry, enabled = !state.isWorking) { Text(stringResource(R.string.retry)) }
        }
        if (state.canReset) {
            Spacer(Modifier.height(8.dp))
            HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
            Text(stringResource(R.string.reset_identity), style = MaterialTheme.typography.titleMedium)
            Text(stringResource(R.string.reset_identity_description), style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
            OutlinedButton(onClick = { confirmation = true }, enabled = !state.isWorking) {
                Text(stringResource(R.string.reset_identity), color = MaterialTheme.colorScheme.error)
            }
        }
    }
}

@Composable
private fun IdentityField(label: String, value: String, copy: () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(label, style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(value, style = MaterialTheme.typography.bodyMedium, fontFamily = FontFamily.Monospace)
        TextButton(onClick = copy, modifier = Modifier.heightIn(min = 48.dp)) {
            Text(stringResource(R.string.copy_field, label))
        }
    }
}

private fun copyText(context: Context, label: String, value: String) {
    context.getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText(label, value))
}
