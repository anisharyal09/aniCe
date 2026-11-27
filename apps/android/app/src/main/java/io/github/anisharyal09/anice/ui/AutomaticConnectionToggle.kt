// SPDX-License-Identifier: GPL-3.0-or-later
// Presents a persistent preference as one accessible row with a compact capsule switch.
package io.github.anisharyal09.anice.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.selection.toggleable
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.*
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.compositeOver
import androidx.compose.ui.graphics.luminance
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.tween
import io.github.anisharyal09.anice.ui.theme.controlTrack

@Composable
fun AutomaticConnectionToggle(
    checked: Boolean,
    enabled: Boolean,
    onCheckedChange: (Boolean) -> Unit,
    label: String = "Connect automatically",
    description: String? = null,
    compact: Boolean = false,
    descriptionBottomPadding: Dp? = null,
) {
    Row(Modifier.fillMaxWidth().heightIn(min = 48.dp)
        // toggleable already merges its label/helper; a second merging node is redundant.
        .toggleable(value = checked, enabled = enabled, role = Role.Switch,
            onValueChange = { if (enabled) onCheckedChange(it) }),
        verticalAlignment = Alignment.CenterVertically) {
        val inset = if (description == null) 0.dp else if (compact) 6.dp else 12.dp
        Column(Modifier.weight(1f).padding(top = inset, bottom = descriptionBottomPadding ?: inset), verticalArrangement = Arrangement.spacedBy(if (compact) 4.dp else 6.dp)) {
            Text(label, style = MaterialTheme.typography.bodyMedium)
            if (description != null) Text(description, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Spacer(Modifier.width(12.dp))
        CapsuleSwitchFace(checked, enabled)
    }
}

@Composable
private fun CapsuleSwitchFace(checked: Boolean, enabled: Boolean) {
    val position = animateDpAsState(if (checked) 18.dp else 2.dp, tween(140), label = "Switch thumb")
    val colors = capsuleSwitchColors(MaterialTheme.colorScheme, checked)
    val shape = RoundedCornerShape(50)
    // This face is decorative; the labeled row owns the single accessible, keyboard/touch action.
    Box(Modifier.size(width = 44.dp, height = 28.dp).clearAndSetSemantics {}
        .graphicsLayer(alpha = if (enabled) 1f else 0.45f), contentAlignment = Alignment.Center) {
        Box(Modifier.size(width = 38.dp, height = 22.dp)
            .background(colors.track, shape)
            .border(0.5.dp, colors.border, shape)) {
            Box(Modifier.offset { IntOffset(position.value.roundToPx(), 2.dp.roundToPx()) }.size(18.dp)
                .background(colors.thumb, CircleShape))
        }
    }
}

internal data class CapsuleSwitchColors(val track: Color, val thumb: Color, val border: Color)

internal fun capsuleSwitchColors(colors: ColorScheme, checked: Boolean): CapsuleSwitchColors {
    val dark = colors.surface.luminance() < 0.5f
    return CapsuleSwitchColors(
        track = if (checked) colors.primary.copy(alpha = if (dark) 0.34f else 0.78f)
            .compositeOver(colors.primaryContainer) else colors.controlTrack,
        thumb = if (checked) (if (dark) colors.primary else colors.background) else colors.onSurfaceVariant,
        border = colors.onSurfaceVariant.copy(alpha = if (checked) 0f else 0.35f),
    )
}
