// SPDX-License-Identifier: GPL-3.0-or-later
// Provides a direct rename action while retaining device-owned names and private aliases as separate facts.
package io.github.anisharyal09.anice.features.deviceidentity

import androidx.compose.material3.*
import androidx.compose.foundation.layout.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import io.github.anisharyal09.anice.ui.AutomaticConnectionToggle

@Composable
internal fun DeviceNameDialog(
    initialName: String,
    busy: Boolean,
    failure: Boolean,
    onDismiss: () -> Unit,
    onSave: (String) -> Unit,
    title: String = "Device name",
    helper: String = "Shared with your paired devices.",
    initialUseNickname: Boolean? = null,
    onSaveNickname: ((String, Boolean) -> Unit)? = null,
) {
    var name by rememberSaveable { mutableStateOf(initialName) }
    var useNickname by rememberSaveable { mutableStateOf(initialUseNickname ?: false) }
    var submitted by remember { mutableStateOf(false) }
    LaunchedEffect(initialName, initialUseNickname, submitted, busy, failure) {
        if (submitted && !busy && !failure && initialName == name.trim() &&
            (initialUseNickname == null || initialUseNickname == useNickname)) onDismiss()
    }
    val trimmed = name.trim()
    val valid = trimmed.codePointCount(0, trimmed.length) <= 64 &&
        (if (onSaveNickname == null) trimmed.isNotBlank() else !useNickname || trimmed.isNotBlank())
    AlertDialog(onDismissRequest = { if (!busy) onDismiss() },
        title = { Text(title) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedTextField(value = name, onValueChange = { name = it }, singleLine = true,
                    enabled = !busy, label = { Text(if (onSaveNickname == null) "Device name" else "Nickname") },
                    modifier = Modifier.fillMaxWidth(), supportingText = { Text(helper) })
                if (onSaveNickname != null) AutomaticConnectionToggle(
                    checked = useNickname, enabled = !busy, onCheckedChange = { useNickname = it },
                    label = "Use nickname", compact = true)
                if (submitted && failure) Text("Couldn't save. Try again.", color = MaterialTheme.colorScheme.error)
            }
        },
        confirmButton = {
            TextButton(enabled = !busy && valid, onClick = {
                submitted = true
                if (onSaveNickname == null) onSave(trimmed) else onSaveNickname(trimmed, useNickname)
            }) { Text(if (busy) "Saving…" else "Save") }
        },
        dismissButton = { TextButton(enabled = !busy, onClick = onDismiss) { Text("Cancel") } })
}
