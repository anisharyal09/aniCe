// SPDX-License-Identifier: GPL-3.0-or-later
// Presents a labeled preference as one accessible row with a compact native checkbox.
package io.github.anisharyal09.anice.ui

import io.github.anisharyal09.anice.ui.theme.selectionAccent
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.selection.toggleable
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.*
import androidx.compose.ui.unit.dp

@Composable
fun AutomaticConnectionToggle(checked: Boolean, enabled: Boolean, onCheckedChange: (Boolean) -> Unit, label: String = "Connect automatically") {
    Row(Modifier.fillMaxWidth().heightIn(min = 48.dp)
        .toggleable(value = checked, enabled = enabled, role = Role.Checkbox, onValueChange = onCheckedChange)
        .semantics(mergeDescendants = true) {}, verticalAlignment = Alignment.CenterVertically) {
        Text(label, Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
        Checkbox(checked = checked, enabled = enabled, onCheckedChange = null,
            colors = CheckboxDefaults.colors(checkedColor = MaterialTheme.colorScheme.selectionAccent,
                checkmarkColor = MaterialTheme.colorScheme.onPrimary),
            modifier = Modifier.clearAndSetSemantics {})
    }
}
