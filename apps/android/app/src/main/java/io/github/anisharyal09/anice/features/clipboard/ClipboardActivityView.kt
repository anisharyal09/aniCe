// SPDX-License-Identifier: GPL-3.0-or-later
// Presents a bounded eligible-text preview and local Copy for the latest shared clipboard activity.
package io.github.anisharyal09.anice.features.clipboard

import android.text.format.DateUtils
import android.widget.Toast
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import io.github.anisharyal09.anice.R

@Composable
fun ClipboardActivityView(owner: ClipboardController, open: () -> Unit, compact: Boolean = false) {
    val item = owner.recent ?: return
    val context = LocalContext.current
    val relativeTime = DateUtils.getRelativeTimeSpanString(
        item.timestamp, System.currentTimeMillis(), DateUtils.MINUTE_IN_MILLIS
    ).toString()
    Surface(shape = if (compact) androidx.compose.ui.graphics.RectangleShape else MaterialTheme.shapes.medium,
        color = if (compact) androidx.compose.ui.graphics.Color.Transparent else MaterialTheme.colorScheme.surfaceContainer) {
        Column(Modifier.fillMaxWidth().padding(if (compact) PaddingValues(vertical = 12.dp) else PaddingValues(16.dp)),
            verticalArrangement = Arrangement.spacedBy(if (compact) 6.dp else 4.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                if (compact) Icon(painterResource(R.drawable.ic_clipboard), contentDescription = null,
                    tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(20.dp))
                Column(Modifier.weight(1f)) {
                    if (compact) {
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            Box(
                                modifier = Modifier.clickable(role = Role.Button, onClickLabel = "Open Clipboard", onClick = open)
                                    .heightIn(min = 48.dp).semantics { heading() },
                                contentAlignment = Alignment.CenterStart,
                            ) {
                                Text("Clipboard", style = MaterialTheme.typography.titleSmall)
                            }
                            Text("From ${if (item.received) "Mac" else "phone"} · $relativeTime",
                                modifier = Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis,
                                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                        item.textPreview?.let {
                            Text(it, maxLines = 1, overflow = TextOverflow.Ellipsis,
                                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        } ?: Text("Preview hidden for marked clipboard items", maxLines = 1,
                            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    } else {
                        TextButton(onClick = open, contentPadding = PaddingValues(0.dp), modifier = Modifier.semantics { heading() }) {
                            Text("Clipboard", style = MaterialTheme.typography.titleSmall)
                        }
                    }
                }
                if (!compact) Text(if (item.received) "From Mac" else "From phone", style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
                if (!compact) IconButton(onClick = { owner.dismissActivity(item.id) }) {
                    Icon(painterResource(R.drawable.ic_close), contentDescription = "Dismiss clipboard activity")
                }
            }
            val time = java.text.DateFormat.getTimeInstance(java.text.DateFormat.SHORT).format(java.util.Date(item.timestamp))
            if (!compact) Text("${if (item.received) "Received" else "Sent to Mac"} · $time", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            if (!compact) {
                item.textPreview?.let { Text(it, maxLines = 2, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.bodyMedium) }
                    ?: Text("Preview hidden for marked clipboard items", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            Row(Modifier.fillMaxWidth(), horizontalArrangement = if (compact) Arrangement.End else Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically) {
                if (item.canCopy) TextButton(onClick = {
                    val copied = owner.copyActivity(item.id)
                    Toast.makeText(context, if (copied) "Copied" else "Could not copy text", Toast.LENGTH_SHORT).show()
                }) {
                    Icon(painterResource(R.drawable.ic_clipboard), contentDescription = null, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(8.dp))
                    Text("Copy")
                }
                if (compact) TextButton(onClick = { owner.dismissActivity(item.id) }) { Text("Dismiss") }
            }
            if (compact) HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
        }
    }
}
