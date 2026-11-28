// SPDX-License-Identifier: GPL-3.0-or-later
// Shares Home's compact action face while preserving Material's native interaction area.
package io.github.anisharyal09.anice.ui

import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

@Composable
internal fun AniCeActionButton(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    prominent: Boolean = false,
    content: @Composable RowScope.() -> Unit,
) {
    // Material reserves a 48 dp target around the smaller 32 dp face.
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
