// SPDX-License-Identifier: GPL-3.0-or-later
// Presents mutually exclusive choices as one compact, theme-aware segmented row.
package io.github.anisharyal09.anice.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.ripple
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp

@Composable
fun <T> AniCeSegmentedControl(
    options: List<Pair<T, String>>,
    selected: T,
    onSelected: (T) -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = MaterialTheme.colorScheme
    Row(
        modifier
            .background(colors.surfaceVariant, RoundedCornerShape(8.dp))
            .padding(horizontal = 3.dp)
            .selectableGroup(),
        horizontalArrangement = Arrangement.spacedBy(2.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        options.forEach { (value, title) ->
            val isSelected = value == selected
            Box(
                Modifier.weight(1f)
                    .heightIn(min = 48.dp)
                    .clip(RoundedCornerShape(6.dp))
                    // Native indication owns hover, focus and touch feedback for this segment only.
                    .selectable(
                        selected = isSelected,
                        interactionSource = null,
                        indication = ripple(color = if (isSelected) colors.onPrimary else colors.primary),
                        role = Role.Tab,
                        onClick = { if (!isSelected) onSelected(value) },
                    )
                    .padding(vertical = 3.dp)
                    .background(if (isSelected) colors.primary else Color.Transparent, RoundedCornerShape(6.dp)),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    title,
                    style = MaterialTheme.typography.bodyMedium,
                    color = if (isSelected) colors.onPrimary else colors.onSurfaceVariant,
                    modifier = Modifier.padding(horizontal = 10.dp, vertical = 4.dp),
                )
            }
        }
    }
}
