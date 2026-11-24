// SPDX-License-Identifier: GPL-3.0-or-later
// Reuses Home's compact rectangular controls without changing native touch targets.
package io.github.anisharyal09.anice.features.transfer

import androidx.compose.foundation.layout.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import io.github.anisharyal09.anice.ui.AniCeActionButton

@Composable
internal fun TransferActionButton(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    prominent: Boolean = false,
    content: @Composable RowScope.() -> Unit,
) {
    AniCeActionButton(onClick = onClick, modifier = modifier, enabled = enabled,
        prominent = prominent, content = content)
}
