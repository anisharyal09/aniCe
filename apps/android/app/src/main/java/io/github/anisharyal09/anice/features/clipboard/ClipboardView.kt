// SPDX-License-Identifier: GPL-3.0-or-later
// Presents credential-scoped clipboard sharing and optional device-local text history.
package io.github.anisharyal09.anice.features.clipboard

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import io.github.anisharyal09.anice.infrastructure.pairing.PeerTrustRecord

@Composable
fun ClipboardSettings(owner: ClipboardController, peers: List<PeerTrustRecord>, showHistory: Boolean = true) {
    val keys = peers.map { it.peer.deviceId + ":" + it.peer.fingerprint }
    LaunchedEffect(keys) { owner.prune(peers.map { it.peer }); if (owner.selected == null) owner.select(peers.firstOrNull()?.peer) }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        if (peers.isEmpty()) Text("Pair a device to share your clipboard.")
        if (peers.size > 1) {
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                peers.forEach { record -> FilterChip(selected = owner.selected?.deviceId == record.peer.deviceId && owner.selected?.fingerprint == record.peer.fingerprint,
                    onClick = { owner.select(record.peer) }, label = { Text(record.peer.deviceName) }) }
            }
        } else peers.firstOrNull()?.let { Text(it.peer.deviceName, style = MaterialTheme.typography.titleSmall) }
        Row(Modifier.fillMaxWidth(), verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
            Text("Automatic clipboard sharing", Modifier.weight(1f))
            Switch(checked = owner.automatic, onCheckedChange = owner::setAutomaticEnabled, enabled = owner.selected != null)
        }
        if (showHistory) HistoryPreference(owner.history)
    }
}

@Composable
fun ClipboardView(owner: ClipboardController, peers: List<PeerTrustRecord>) {
    var historyTab by remember { mutableStateOf(false) }
    var more by remember { mutableStateOf(false) }
    var how by remember { mutableStateOf(false) }
    var reveal by remember { mutableStateOf(false) }
    var pasted by remember { mutableStateOf("") }
    var confirming by remember { mutableStateOf(false) }
    var sensitiveSample by remember { mutableStateOf<ClipboardSample?>(null) }
    val lifecycle = androidx.lifecycle.compose.LocalLifecycleOwner.current.lifecycle
    DisposableEffect(lifecycle) {
        val observer = androidx.lifecycle.LifecycleEventObserver { _, event ->
            if (event == androidx.lifecycle.Lifecycle.Event.ON_STOP) { pasted = ""; sensitiveSample = null; confirming = false; reveal = false; owner.clearPreview() }
        }
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer) }
    }
    LaunchedEffect(owner.selected?.deviceId, owner.selected?.fingerprint, owner.selected?.let(owner::supports)) { pasted = ""; reveal = false; sensitiveSample = null; confirming = false }
    DisposableEffect(owner.selected?.deviceId) { onDispose { owner.clearPreview() } }
    LaunchedEffect(owner.preview?.token, owner.preview?.text) { reveal = false }
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        SecondaryTabRow(selectedTabIndex = if (historyTab) 1 else 0) {
            Tab(selected = !historyTab, onClick = { historyTab = false }, text = { Text("Share") })
            Tab(selected = historyTab, onClick = { historyTab = true; pasted = ""; reveal = false; owner.clearPreview() }, text = { Text("History") })
        }
        if (historyTab) ClipboardHistoryView(owner)
        else {
            ClipboardSettings(owner, peers, showHistory = false)
            val peer = owner.selected
            val available = peer?.let(owner::supports) == true
            if (peer != null && !available) Text(if (owner.connected(peer)) "Clipboard unavailable on this device" else "Connect first")
            if (owner.status != "Ready to share text" && (available || owner.busy)) Text(owner.status, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Button(onClick = { owner.send(); sensitiveSample = owner.preview?.takeIf { it.sensitive }; confirming = sensitiveSample != null }, enabled = available && !owner.busy) { Text("Send clipboard") }
            if (owner.busy) TextButton(onClick = owner::cancel) { Text("Cancel send") }
            TextButton(onClick = { more = !more; if (!more) { pasted = ""; reveal = false; owner.clearPreview() } }) { Text(if (more) "More options ▴" else "More options ▾") }
            if (more) {
                OutlinedButton(onClick = owner::inspect, enabled = !owner.busy) { Text("Inspect clipboard") }
                owner.preview?.let { sample ->
                    Text("${sample.text.toByteArray(Charsets.UTF_8).size} bytes · ${if (sample.sensitive) "Sensitive text" else "Plain text"}", style = MaterialTheme.typography.bodySmall)
                    if (reveal) Text(sample.text)
                    else TextButton(onClick = { reveal = true }) { Text("Reveal text") }
                }
                OutlinedTextField(value = pasted, onValueChange = { if (it.length <= 65536) pasted = it }, label = { Text("Paste text here") }, modifier = Modifier.fillMaxWidth())
                if (pasted.isNotEmpty()) OutlinedButton(onClick = { owner.send(pasted = pasted); pasted = "" }, enabled = available && !owner.busy) { Text("Send pasted text") }
            }
            TextButton(onClick = { how = !how }) { Text(if (how) "How sharing works ▴" else "How sharing works ▾") }
            if (how) Text("Manual sharing works with automatic sharing off. For text or links in another app, use Share → Send to Mac (aniCe icon). Text-selection menus also work where supported. A small sending panel opens; connect your Mac first.\n\nFor automatic sharing, enable it on both devices, copy text, then open aniCe. Android reads copied text only while aniCe has focus. Received text replaces your clipboard, including in the background. Optional history stays on this device.", style = MaterialTheme.typography.bodySmall)
        }
    }
    if (confirming) AlertDialog(onDismissRequest = { confirming = false; sensitiveSample = null; owner.clearPreview() }, title = { Text("Send sensitive text?") },
        text = { Text("This clipboard is marked sensitive. Send it to ${owner.selected?.deviceName ?: "the selected device"}?") },
        confirmButton = { TextButton(onClick = { confirming = false; sensitiveSample?.let(owner::sendConfirmed); sensitiveSample = null }) { Text("Send") } },
        dismissButton = { TextButton(onClick = { confirming = false; sensitiveSample = null; owner.clearPreview() }) { Text("Cancel") } })
}

@Composable
private fun HistoryPreference(history: ClipboardHistory) {
    var confirm by remember { mutableStateOf(false) }
    Row(Modifier.fillMaxWidth(), verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
        Text("Keep clipboard history", Modifier.weight(1f))
        Switch(checked = history.enabled, onCheckedChange = { if (it) confirm = true else history.setKeepingHistory(false) })
    }
    history.error?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
    if (confirm) AlertDialog(onDismissRequest = { confirm = false }, title = { Text("Keep clipboard history?") },
        text = { Text("Save the latest 20 text items on this device across restarts. Recognized sensitive text is excluded. Turning this off deletes saved history.") },
        confirmButton = { TextButton(onClick = { confirm = false; history.setKeepingHistory(true) }) { Text("Enable") } },
        dismissButton = { TextButton(onClick = { confirm = false }) { Text("Cancel") } })
}

@Composable
private fun ClipboardHistoryView(owner: ClipboardController) {
    val history = owner.history
    var clear by remember { mutableStateOf(false) }
    HistoryPreference(history)
    if (owner.status != "Ready to share text") Text(owner.status, style = MaterialTheme.typography.bodySmall)
    if (owner.busy) TextButton(onClick = owner::cancel) { Text("Cancel send") }
    if (history.entries.isEmpty()) Text(if (history.enabled) "No clipboard history yet" else "Enable history to keep text on this device", style = MaterialTheme.typography.bodyMedium)
    else {
        TextButton(onClick = { clear = true }) { Text("Clear all") }
        history.entries.forEach { entry ->
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(entry.text.take(240), maxLines = 2, overflow = TextOverflow.Ellipsis)
                Text("${if (entry.origin == "mac") "From Mac" else "From phone"} · ${java.text.DateFormat.getDateTimeInstance(java.text.DateFormat.SHORT, java.text.DateFormat.SHORT).format(java.util.Date(entry.timestamp))}", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    TextButton(onClick = { owner.copyHistory(entry) }) { Text("Copy") }
                    TextButton(onClick = { owner.sendHistory(entry) }, enabled = owner.selected?.let(owner::supports) == true && !owner.busy) { Text("Send") }
                    TextButton(onClick = { history.delete(entry.id) }) { Text("Delete") }
                }
                HorizontalDivider()
            }
        }
    }
    if (history.error != null && history.entries.isEmpty()) TextButton(onClick = history::clear) { Text("Clear history") }
    if (clear) AlertDialog(onDismissRequest = { clear = false }, title = { Text("Clear clipboard history?") }, text = { Text("Delete all saved text on this device.") },
        confirmButton = { TextButton(onClick = { clear = false; history.clear() }) { Text("Clear all") } },
        dismissButton = { TextButton(onClick = { clear = false }) { Text("Cancel") } })
}
