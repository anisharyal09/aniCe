// SPDX-License-Identifier: GPL-3.0-or-later
// Presents local identity information and confirmed reset inside advanced controls.
package io.github.anisharyal09.anice.features.deviceidentity

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.os.Build
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.ui.Alignment
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.material3.Icon
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.OutlinedTextField
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
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
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
    onRename: (String) -> Unit = {},
) {
    var confirmation by rememberSaveable { mutableStateOf(false) }
    var editingName by rememberSaveable { mutableStateOf(false) }
    var name by rememberSaveable(state.snapshot?.identity?.deviceId) { mutableStateOf("") }
    var advanced by rememberSaveable { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    val deviceIdLabel = stringResource(R.string.device_id)
    val fingerprintLabel = stringResource(R.string.fingerprint)
    val copiedLabel = stringResource(R.string.copied)
    val largeText = LocalDensity.current.fontScale >= 1.5f
    if (editingName) AlertDialog(
        onDismissRequest = { editingName = false },
        title = { Text("Device name") },
        text = {
            OutlinedTextField(value = name, onValueChange = { name = it }, label = { Text("Phone name") },
                singleLine = true, enabled = !state.isWorking,
                supportingText = { Text("Up to 64 characters. Shown after authentication.") })
        },
        confirmButton = {
            TextButton(shape = MaterialTheme.shapes.small, contentPadding = PaddingValues(horizontal = 10.dp, vertical = 4.dp),
                enabled = !state.isWorking && name.trim().isNotBlank() &&
                    name.trim().codePointCount(0, name.trim().length) <= 64 && name.trim() != state.snapshot?.identity?.deviceName,
                onClick = { onRename(name); editingName = false }) { Text("Save") }
        },
        dismissButton = {
            TextButton(shape = MaterialTheme.shapes.small, contentPadding = PaddingValues(horizontal = 10.dp, vertical = 4.dp), onClick = { editingName = false }) { Text(stringResource(R.string.cancel)) }
        },
    )
    if (confirmation) AlertDialog(
        onDismissRequest = { confirmation = false },
        title = { Text(stringResource(R.string.reset_identity_title)) },
        text = { Text(stringResource(R.string.reset_identity_warning)) },
        confirmButton = {
            TextButton(shape = MaterialTheme.shapes.small, contentPadding = PaddingValues(horizontal = 10.dp, vertical = 4.dp), onClick = { confirmation = false; onReset() }, enabled = !state.isWorking) {
                Text(stringResource(R.string.reset_identity), color = MaterialTheme.colorScheme.error)
            }
        },
        dismissButton = {
            TextButton(shape = MaterialTheme.shapes.small, contentPadding = PaddingValues(horizontal = 10.dp, vertical = 4.dp), onClick = { confirmation = false }) { Text(stringResource(R.string.cancel)) }
        },
    )
    Box(modifier.fillMaxSize(), contentAlignment = Alignment.TopCenter) {
        Column(Modifier.widthIn(max = 640.dp).fillMaxWidth()
            .verticalScroll(rememberScrollState()).padding(horizontal = 24.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            if (state.isWorking) LinearProgressIndicator(Modifier.fillMaxWidth())
            state.snapshot?.let { current ->
                val editName: @Composable () -> Unit = {
                    TextButton(shape = MaterialTheme.shapes.small, contentPadding = PaddingValues(horizontal = 10.dp, vertical = 4.dp), enabled = !state.isWorking,
                        onClick = { name = current.identity.deviceName; editingName = true },
                        modifier = Modifier.heightIn(min = 48.dp)) { Text("Edit name") }
                }
                Surface(shape = MaterialTheme.shapes.medium, color = MaterialTheme.colorScheme.surface,
                    modifier = Modifier.fillMaxWidth()) {
                    Column {
                        Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                            Icon(painterResource(R.drawable.ic_phone), contentDescription = null,
                                tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(28.dp))
                            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                                Text(current.identity.deviceName, style = MaterialTheme.typography.titleMedium)
                                Text(stringResource(R.string.android_platform), style = MaterialTheme.typography.bodyMedium,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                            if (!largeText) editName()
                        }
                        if (largeText) editName()
                    }
                }
                if (state.renameFailure) Text("Could not save the name. Try again.", color = MaterialTheme.colorScheme.error)
                Text(stringResource(R.string.identity_description), style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
                Surface(shape = MaterialTheme.shapes.large, color = MaterialTheme.colorScheme.surface,
                    modifier = Modifier.fillMaxWidth()) {
                    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
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
                OutlinedButton(shape = MaterialTheme.shapes.small, contentPadding = PaddingValues(horizontal = 10.dp, vertical = 4.dp), onClick = onRetry, enabled = !state.isWorking) { Text(stringResource(R.string.retry)) }
            }
            // Keep destructive recovery separate from the everyday rename and copy actions.
            if (state.canReset) {
                TextButton(shape = MaterialTheme.shapes.small, contentPadding = PaddingValues(horizontal = 10.dp, vertical = 4.dp), onClick = { advanced = !advanced }, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)
                    .semantics { stateDescription = if (advanced) "Expanded" else "Collapsed" }) {
                    Text(if (advanced) "Hide advanced" else "Advanced")
                }
                if (advanced) {
                    HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
                    Text(stringResource(R.string.reset_identity_description), style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                    OutlinedButton(shape = MaterialTheme.shapes.small,
                        contentPadding = PaddingValues(horizontal = 14.dp, vertical = 2.dp),
                        modifier = Modifier.defaultMinSize(minHeight = 32.dp),
                        onClick = { confirmation = true }, enabled = !state.isWorking) {
                        Text(stringResource(R.string.reset_identity))
                    }
                }
            }
        }
    }
}

@Composable
private fun IdentityField(label: String, value: String, copy: () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        FlowRow(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween,
            verticalArrangement = Arrangement.Center, itemVerticalAlignment = Alignment.CenterVertically) {
            Text(label, style = MaterialTheme.typography.titleSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
            TextButton(shape = MaterialTheme.shapes.small, contentPadding = PaddingValues(horizontal = 10.dp, vertical = 4.dp), onClick = copy, modifier = Modifier.heightIn(min = 48.dp)) {
                Text(stringResource(R.string.copy_field, label))
            }
        }
        // Grouping is visual only; copy actions retain the original full identity value.
        Text(value, style = MaterialTheme.typography.bodySmall, fontFamily = FontFamily.Monospace)
    }
}

private fun copyText(context: Context, label: String, value: String) {
    context.getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText(label, value))
}
