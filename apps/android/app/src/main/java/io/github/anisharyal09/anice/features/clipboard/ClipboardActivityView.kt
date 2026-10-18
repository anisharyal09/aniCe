// SPDX-License-Identifier: GPL-3.0-or-later
// Presents a bounded eligible-text preview and local Copy for the latest shared clipboard activity.
package io.github.anisharyal09.anice.features.clipboard

import android.widget.Toast
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import io.github.anisharyal09.anice.R

@Composable
fun ClipboardActivityView(owner: ClipboardController, open: () -> Unit) {
    val item = owner.recent ?: return
    val context = LocalContext.current
    Surface(shape = MaterialTheme.shapes.medium, color = MaterialTheme.colorScheme.surfaceContainer) {
        Column(Modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                TextButton(onClick = open, modifier = Modifier.weight(1f).semantics { heading() }) {
                    Text("Clipboard", Modifier.weight(1f), style = MaterialTheme.typography.titleSmall)
                    Icon(painterResource(R.drawable.ic_chevron_forward), contentDescription = "Open Clipboard", modifier = Modifier.size(18.dp))
                }
                IconButton(onClick = { owner.dismissActivity(item.id) }) {
                    Icon(painterResource(R.drawable.ic_close), contentDescription = "Dismiss clipboard activity")
                }
            }
            Text(if (item.received) "From Mac" else "From phone", style = MaterialTheme.typography.bodyMedium)
            val time = java.text.DateFormat.getTimeInstance(java.text.DateFormat.SHORT).format(java.util.Date(item.timestamp))
            Text("${if (item.received) "Received" else "Sent to Mac"} · $time", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            item.textPreview?.let { Text(it, maxLines = 2, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.bodyMedium) }
                ?: Text("Preview hidden for marked clipboard items", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            if (item.canCopy) TextButton(onClick = {
                val copied = owner.copyActivity(item.id)
                Toast.makeText(context, if (copied) "Copied" else "Could not copy text", Toast.LENGTH_SHORT).show()
            }) {
                Icon(painterResource(R.drawable.ic_clipboard), contentDescription = null, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(8.dp))
                Text("Copy")
            }
        }
    }
}
