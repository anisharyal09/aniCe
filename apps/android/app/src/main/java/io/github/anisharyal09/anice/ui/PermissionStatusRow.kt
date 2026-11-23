// SPDX-License-Identifier: GPL-3.0-or-later
// Presents native permission state without repeating granted details outside the Permissions category.
package io.github.anisharyal09.anice.ui

import androidx.compose.foundation.layout.*
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

internal fun permissionRowVisible(allowed: Boolean, showGranted: Boolean): Boolean =
    !allowed || showGranted

@Composable
fun PermissionStatusRow(
    title: String,
    allowed: Boolean,
    purpose: String,
    showGranted: Boolean,
    action: (@Composable () -> Unit)? = null,
) {
    if (!permissionRowVisible(allowed, showGranted)) return
    Column(
        Modifier.fillMaxWidth().padding(vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Row(
            Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(title, Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
            Text(
                if (allowed) "Allowed" else "Not allowed",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        if (showGranted) {
            Text(purpose, style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        if (!allowed) action?.invoke()
    }
}
