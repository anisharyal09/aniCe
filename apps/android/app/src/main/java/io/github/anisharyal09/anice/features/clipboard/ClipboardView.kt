// SPDX-License-Identifier: GPL-3.0-or-later
// Presents credential-scoped clipboard consent and explicit text sharing without saved content.
package io.github.anisharyal09.anice.features.clipboard

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.unit.dp
import io.github.anisharyal09.anice.infrastructure.pairing.PeerTrustRecord

@Composable
fun ClipboardSettings(owner: ClipboardController, peers: List<PeerTrustRecord>) {
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
        Text("Enable on both devices. After copying in another Android app, open aniCe to share. Incoming text replaces your clipboard, including in the background.",
            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
fun ClipboardView(owner: ClipboardController, peers: List<PeerTrustRecord>) {
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
        ClipboardSettings(owner, peers)
        HorizontalDivider()
        val peer = owner.selected
        if (peer != null && !owner.supports(peer)) Text(if (owner.connected(peer)) "Clipboard unavailable on this device" else "Connect first")
        Text(owner.status, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        owner.preview?.let { sample ->
            Text("${sample.text.toByteArray(Charsets.UTF_8).size} bytes · ${if (sample.sensitive) "Sensitive text" else "Plain text"}", style = MaterialTheme.typography.bodySmall)
            if (reveal) Text(sample.text, modifier = Modifier.clearAndSetSemantics {})
            else TextButton(onClick = { reveal = true }) { Text("Reveal text") }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedButton(onClick = owner::inspect, enabled = !owner.busy) { Text("Inspect clipboard") }
            Button(onClick = { owner.send(); sensitiveSample = owner.preview?.takeIf { it.sensitive }; confirming = sensitiveSample != null }, enabled = peer?.let(owner::supports) == true && !owner.busy) {
                Text("Send to ${peer?.deviceName ?: "device"}")
            }
        }
        OutlinedTextField(value = pasted, onValueChange = { if (it.length <= 65536) pasted = it }, label = { Text("Or paste text here") }, modifier = Modifier.fillMaxWidth())
        if (pasted.isNotEmpty()) OutlinedButton(onClick = { owner.send(pasted = pasted); pasted = "" }, enabled = peer?.let(owner::supports) == true && !owner.busy) { Text("Send pasted text") }
        if (owner.busy) TextButton(onClick = owner::cancel) { Text("Cancel send") }
    }
    if (confirming) AlertDialog(onDismissRequest = { confirming = false; owner.clearPreview() }, title = { Text("Send sensitive text?") },
        text = { Text("This clipboard is marked sensitive. Send it to ${owner.selected?.deviceName ?: "the selected device"}?") },
        confirmButton = { TextButton(onClick = { confirming = false; sensitiveSample?.let(owner::sendConfirmed); sensitiveSample = null }) { Text("Send") } },
        dismissButton = { TextButton(onClick = { confirming = false; owner.clearPreview() }) { Text("Cancel") } })
}
