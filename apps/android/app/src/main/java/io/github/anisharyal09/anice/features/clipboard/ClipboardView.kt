// SPDX-License-Identifier: GPL-3.0-or-later
// Presents credential-scoped clipboard sharing and optional device-local text history.
package io.github.anisharyal09.anice.features.clipboard

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import io.github.anisharyal09.anice.R
import io.github.anisharyal09.anice.infrastructure.pairing.PeerTrustRecord
import io.github.anisharyal09.anice.ui.AutomaticConnectionToggle
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

@Composable
fun ClipboardSettings(owner: ClipboardController, peers: List<PeerTrustRecord>, showHistory: Boolean = true, grouped: Boolean = false) {
    val keys = peers.map { it.peer.deviceId + ":" + it.peer.fingerprint }
    LaunchedEffect(keys) { owner.prune(peers.map { it.peer }); if (owner.selected == null) owner.select(peers.firstOrNull()?.peer) }
    Column(verticalArrangement = Arrangement.spacedBy(if (grouped) 0.dp else 8.dp)) {
        if (peers.isEmpty()) Text("Pair a device to share your clipboard.")
        if (peers.size > 1) {
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                peers.forEach { record -> FilterChip(selected = owner.selected?.deviceId == record.peer.deviceId && owner.selected?.fingerprint == record.peer.fingerprint,
                    onClick = { owner.select(record.peer) }, label = { Text(record.peer.deviceName) }) }
            }
        } else if (!grouped) peers.firstOrNull()?.let { Text(it.peer.deviceName, style = MaterialTheme.typography.titleSmall) }
        if (grouped && peers.isNotEmpty()) HorizontalDivider()
        AutomaticConnectionToggle(checked = owner.automatic, enabled = owner.selected != null,
            onCheckedChange = owner::setAutomaticEnabled,
            label = if (grouped) "Automatic sharing" else "Automatic clipboard sharing",
            description = if (grouped && peers.isNotEmpty()) "Enable on both devices. Manual sends stay available." else null)
        if (showHistory) {
            if (grouped) HorizontalDivider()
            HistoryPreference(owner.history, compact = grouped)
        }
    }
}

@Composable
fun ClipboardView(owner: ClipboardController, peers: List<PeerTrustRecord>) {
    var historyTab by remember { mutableStateOf(false) }
    var more by remember { mutableStateOf(false) }
    var how by remember { mutableStateOf(false) }
    var reveal by remember { mutableStateOf(false) }
    var pasted by remember { mutableStateOf("") }
    val lifecycle = androidx.lifecycle.compose.LocalLifecycleOwner.current.lifecycle
    DisposableEffect(lifecycle) {
        val observer = androidx.lifecycle.LifecycleEventObserver { _, event ->
            if (event == androidx.lifecycle.Lifecycle.Event.ON_STOP) { pasted = ""; reveal = false; owner.clearPreview() }
        }
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer) }
    }
    LaunchedEffect(owner.selected?.deviceId, owner.selected?.fingerprint, owner.selected?.let(owner::supports)) { pasted = ""; reveal = false }
    DisposableEffect(owner.selected?.deviceId) { onDispose { owner.clearPreview() } }
    LaunchedEffect(owner.preview?.token, owner.preview?.text) { reveal = false }
    Column(Modifier.padding(horizontal = 4.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
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
            ClipboardSendButton(owner)
            if (owner.busy) TextButton(onClick = owner::cancel) { Text("Cancel send") }
            TextButton(onClick = { more = !more; if (!more) { pasted = ""; reveal = false; owner.clearPreview() } }) { Text(if (more) "More options ▴" else "More options ▾") }
            if (more) {
                ClipboardTileSetup()
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
            if (how) Text("Manual sharing works with automatic sharing off. For text or links in another app, use Share → Send to Mac (aniCe icon). Text-selection menus also work where supported. For copied text, use the Send to Mac Quick Settings tile and tap Send in its small panel. Add the tile from More options. Connect your Mac first.\n\nFor automatic sharing, enable it on both devices, copy text, then open aniCe. Android reads copied text only while aniCe has focus. Received text replaces your clipboard, including in the background. Home shows the latest successful clipboard activity for five minutes with a short preview and local Copy for eligible text. Optional history stays on this device, organized by date with the latest items first.", style = MaterialTheme.typography.bodySmall)
        }
    }
}

// Home and Share use the same explicit send and exact sensitive-item confirmation.
@Composable
fun ClipboardSendButton(owner: ClipboardController, modifier: Modifier = Modifier, compact: Boolean = false) {
    var confirming by remember { mutableStateOf(false) }
    var sensitiveSample by remember { mutableStateOf<ClipboardSample?>(null) }
    val lifecycle = androidx.lifecycle.compose.LocalLifecycleOwner.current.lifecycle
    DisposableEffect(lifecycle, owner.selected?.deviceId, owner.selected?.fingerprint, owner.selected?.let(owner::supports)) {
        val observer = androidx.lifecycle.LifecycleEventObserver { _, event ->
            if (event == androidx.lifecycle.Lifecycle.Event.ON_STOP) {
                confirming = false; sensitiveSample = null; owner.clearPreview()
            }
        }
        lifecycle.addObserver(observer)
        onDispose {
            lifecycle.removeObserver(observer)
            confirming = false; sensitiveSample = null; owner.clearPreview()
        }
    }
    val available = owner.selected?.let(owner::supports) == true
    OutlinedButton(onClick = { owner.send(); sensitiveSample = owner.preview?.takeIf { it.sensitive }; confirming = sensitiveSample != null }, enabled = available && !owner.busy,
        shape = MaterialTheme.shapes.small, contentPadding = PaddingValues(horizontal = 10.dp, vertical = 4.dp), modifier = modifier.defaultMinSize(minHeight = 32.dp)) {
        Icon(painterResource(R.drawable.ic_clipboard), contentDescription = null, modifier = Modifier.size(if (compact) 16.dp else 18.dp))
        Spacer(Modifier.width(if (compact) 6.dp else 8.dp))
        Text("Send clipboard")
    }
    if (confirming) AlertDialog(onDismissRequest = { confirming = false; sensitiveSample = null; owner.clearPreview() }, title = { Text("Send sensitive text?") },
        text = { Text("This clipboard is marked sensitive. Send it to ${owner.selected?.deviceName ?: "the selected device"}?") },
        confirmButton = { TextButton(onClick = { confirming = false; sensitiveSample?.let(owner::sendConfirmed); sensitiveSample = null }) { Text("Send") } },
        dismissButton = { TextButton(onClick = { confirming = false; sensitiveSample = null; owner.clearPreview() }) { Text("Cancel") } })
}

@Composable
private fun HistoryPreference(history: ClipboardHistory, compact: Boolean = false) {
    var confirm by remember { mutableStateOf(false) }
    AutomaticConnectionToggle(checked = history.enabled, enabled = true,
        onCheckedChange = { if (it) confirm = true else history.setKeepingHistory(false) },
        label = "Keep clipboard history",
        description = if (compact) "Saved on this phone. Pausing keeps saved clips." else null)
    if (!compact) {
        var capacityMenu by remember { mutableStateOf(false) }
        Box {
            TextButton(onClick = { capacityMenu = true }) { Text("History capacity: ${history.capacity} items") }
            DropdownMenu(expanded = capacityMenu, onDismissRequest = { capacityMenu = false }) {
                listOf(20, 50, 100).forEach { value ->
                    DropdownMenuItem(text = { Text("$value items") }, onClick = { capacityMenu = false; history.updateCapacity(value) })
                }
            }
        }
    }
    if (!compact && !history.enabled && history.entries.isNotEmpty()) Text("Collection paused · Saved items are kept", style = MaterialTheme.typography.bodySmall)
    history.error?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
    if (confirm) AlertDialog(onDismissRequest = { confirm = false }, title = { Text("Keep clipboard history?") },
        text = { Text("Save eligible text on this device across restarts. Recognized sensitive text is excluded. Turning this off pauses collection and keeps saved items. Use Delete or Clear to remove them.") },
        confirmButton = { TextButton(onClick = { confirm = false; history.setKeepingHistory(true) }) { Text("Enable") } },
        dismissButton = { TextButton(onClick = { confirm = false }) { Text("Cancel") } })
}

@Composable
internal fun ClipboardHistoryView(owner: ClipboardController) {
    val history = owner.history
    var clear by remember { mutableStateOf(false) }
    HistoryPreference(history)
    Row(Modifier.fillMaxWidth(), verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
        Text("${history.entries.size} of ${history.capacity} · Saved on this device", Modifier.weight(1f), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        if (history.entries.isNotEmpty()) TextButton(onClick = { clear = true }) { Text("Clear all") }
    }
    if (owner.status != "Ready to share text") Text(owner.status, style = MaterialTheme.typography.bodySmall)
    if (owner.busy) TextButton(onClick = owner::cancel) { Text("Cancel send") }
    if (history.entries.isEmpty()) Text(if (history.enabled) "No clipboard history yet" else "Enable history to keep text on this device", style = MaterialTheme.typography.bodyMedium)
    else {
        val zone = ZoneId.systemDefault()
        val days = history.entries.groupBy { Instant.ofEpochMilli(it.timestamp).atZone(zone).toLocalDate() }
        days.keys.sortedDescending().forEach { day ->
            Text(day.format(DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM)), style = MaterialTheme.typography.titleSmall)
            days.getValue(day).forEach { entry ->
                key(entry.id) {
                    Column(Modifier.fillMaxWidth().padding(vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Text(entry.text.take(240), maxLines = 2, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.bodyMedium)
                        Text("${if (entry.origin == "mac") "From Mac" else "From phone"} · ${java.text.DateFormat.getTimeInstance(java.text.DateFormat.SHORT).format(java.util.Date(entry.timestamp))}", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            TextButton(onClick = { owner.copyHistory(entry) }) {
                                Icon(painterResource(R.drawable.ic_clipboard), contentDescription = null, modifier = Modifier.size(18.dp))
                                Spacer(Modifier.width(8.dp)); Text("Copy")
                            }
                            TextButton(onClick = { owner.sendHistory(entry) }, enabled = owner.selected?.let(owner::supports) == true && !owner.busy) {
                                Icon(painterResource(R.drawable.ic_file_send), contentDescription = null, modifier = Modifier.size(18.dp))
                                Spacer(Modifier.width(8.dp)); Text("Send")
                            }
                            TextButton(onClick = { history.delete(entry.id) }) { Text("Delete") }
                        }
                    }
                    HorizontalDivider()
                }
            }
        }
    }
    if (history.error != null && history.entries.isEmpty()) TextButton(onClick = history::clear) { Text("Clear history") }
    if (clear) AlertDialog(onDismissRequest = { clear = false }, title = { Text("Clear clipboard history?") }, text = { Text("Delete all saved text on this device.") },
        confirmButton = { TextButton(onClick = { clear = false; history.clear() }) { Text("Clear all") } },
        dismissButton = { TextButton(onClick = { clear = false }) { Text("Cancel") } })
}
