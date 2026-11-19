// SPDX-License-Identifier: GPL-3.0-or-later
// Reuses Home's compact rectangular controls without changing native touch targets.
package io.github.anisharyal09.anice.features.transfer

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

@Composable
internal fun TransferActionButton(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    prominent: Boolean = false,
    content: @Composable RowScope.() -> Unit,
) {
    // Material reserves the 48 dp interaction area around Home's smaller button face.
    val buttonModifier = modifier.defaultMinSize(minHeight = 32.dp)
    val padding = PaddingValues(horizontal = 10.dp, vertical = 2.dp)
    if (prominent) {
        Button(onClick = onClick, modifier = buttonModifier, enabled = enabled,
            shape = MaterialTheme.shapes.small, contentPadding = padding, content = content)
    } else {
        OutlinedButton(onClick = onClick, modifier = buttonModifier, enabled = enabled,
            shape = MaterialTheme.shapes.small, contentPadding = padding,
            colors = ButtonDefaults.outlinedButtonColors(containerColor = MaterialTheme.colorScheme.surfaceVariant),
            content = content)
    }
}
