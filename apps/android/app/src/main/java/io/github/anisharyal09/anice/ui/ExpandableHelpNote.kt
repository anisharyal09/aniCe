// SPDX-License-Identifier: GPL-3.0-or-later
// Presents a compact, collapsed-by-default offline help disclosure without altering control state.
package io.github.anisharyal09.anice.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import io.github.anisharyal09.anice.R

@Composable
fun ExpandableHelpNote(
    title: String,
    body: String,
    modifier: Modifier = Modifier,
    expandedByDefault: Boolean = false,
    summary: String? = null,
    iconRes: Int? = null,
    highlighted: Boolean = false,
) {
    var expanded by rememberSaveable(title) { mutableStateOf(expandedByDefault) }
    var syncedDefault by rememberSaveable(title) { mutableStateOf(expandedByDefault) }
    if (expandedByDefault != syncedDefault) {
        expanded = expandedByDefault
        syncedDefault = expandedByDefault
    }
    val layoutDirection = LocalLayoutDirection.current
    Column(modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = 48.dp)
                .clickable(role = Role.Button) { expanded = !expanded }
                .padding(horizontal = 4.dp, vertical = 10.dp)
                .semantics { stateDescription = if (expanded) "Expanded" else "Collapsed" },
        ) {
            if (iconRes != null) {
                Icon(
                    painter = painterResource(iconRes),
                    contentDescription = null,
                    tint = if (highlighted) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.size(18.dp),
                )
            }
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(
                    text = title,
                    style = MaterialTheme.typography.titleSmall,
                    color = MaterialTheme.colorScheme.onSurface,
                )
                if (!summary.isNullOrBlank()) {
                    Text(
                        text = summary,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
            Icon(
                painter = painterResource(R.drawable.ic_chevron_forward),
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(16.dp).graphicsLayer(
                    rotationZ = if (!expanded) 0f else if (layoutDirection == LayoutDirection.Ltr) 90f else -90f,
                ),
            )
        }
        if (expanded) {
            Text(
                text = body,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.fillMaxWidth()
                    .padding(start = if (iconRes != null) 34.dp else 4.dp, end = 24.dp, bottom = 10.dp),
            )
        }
    }
}

