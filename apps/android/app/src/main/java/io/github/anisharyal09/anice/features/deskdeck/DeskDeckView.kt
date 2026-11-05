// SPDX-License-Identifier: GPL-3.0-or-later
// Presents live Mac meters and explicit controls in a responsive phone-first deck.
package io.github.anisharyal09.anice.features.deskdeck

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.horizontalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity
import io.github.anisharyal09.anice.infrastructure.pairing.PeerTrustRecord
import java.util.Locale

@Composable
fun DeskDeckView(
    owner: DeskDeckController,
    peers: List<PeerTrustRecord>,
    onConnect: (DeviceIdentity) -> Unit,
    onPairMac: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val rememberedPeer = peers.firstOrNull { owner.connected(it.peer) }?.peer?.deviceId ?: peers.firstOrNull()?.peer?.deviceId.orEmpty()
    var selectedID by rememberSaveable { mutableStateOf(rememberedPeer) }
    val target = peers.firstOrNull { it.peer.deviceId == selectedID }?.peer
    val lifecycle = LocalLifecycleOwner.current.lifecycle

    LaunchedEffect(peers.map { it.peer.deviceId }) {
        if (peers.none { it.peer.deviceId == selectedID }) {
            selectedID = peers.firstOrNull { owner.connected(it.peer) }?.peer?.deviceId ?: peers.firstOrNull()?.peer?.deviceId.orEmpty()
        }
    }
    DisposableEffect(lifecycle, target) {
        fun start() { if (lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)) target?.let(owner::start) }
        start()
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_START) target?.let(owner::start)
            if (event == Lifecycle.Event.ON_STOP) owner.stop()
        }
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer); owner.stop() }
    }

    Column(modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        if (peers.isEmpty()) {
            Card(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("Pair a Mac to use Desk Deck.", style = MaterialTheme.typography.bodyMedium)
                    OutlinedButton(onClick = onPairMac, modifier = Modifier.heightIn(min = 48.dp)) { Text("Pair a Mac") }
                }
            }
        } else {
            Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                peers.forEach { record ->
                    FilterChip(
                        selected = record.peer.deviceId == selectedID,
                        onClick = { selectedID = record.peer.deviceId },
                        label = { Text(record.peer.deviceName, maxLines = 1) },
                    )
                }
            }
            if (target != null && !owner.connected(target)) {
                Card(Modifier.fillMaxWidth()) {
                    Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text("Connect ${target.deviceName} to use its hardware meters and controls.", style = MaterialTheme.typography.bodyMedium)
                        OutlinedButton(onClick = { onConnect(target) }, modifier = Modifier.heightIn(min = 48.dp)) { Text("Connect Mac") }
                    }
                }
            } else if (target != null && owner.snapshot == null) {
                Card(Modifier.fillMaxWidth()) {
                    Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text(owner.status, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        if (owner.busy) LinearProgressIndicator(Modifier.fillMaxWidth())
                    }
                }
            } else if (target != null) {
                DeskDeckGrid(owner, owner.snapshot!!, modifier = Modifier.weight(1f))
            }
        }
    }
}

private data class DeckAction(val title: String, val detail: String, val action: Long, val bit: Long, val value: Long = -1)

@Composable
private fun DeskDeckGrid(owner: DeskDeckController, sample: DeskDeckSnapshot, modifier: Modifier = Modifier) {
    val haptic = LocalHapticFeedback.current
    val actions = listOf(
        DeckAction("Lock Mac", "Lock the current Mac session", 1, 1),
        DeckAction("Launch Blender", "Open Blender", 3, 2),
        DeckAction("Launch Terminal", "Open Terminal", 4, 4),
        DeckAction("Take Screenshot", "Start the Mac area-capture tool", 5, 8),
    )
    var volumeDrag by remember(sample.outputTarget, sample.outputRevision) { mutableStateOf<Float?>(null) }
    var brightnessDrag by remember(sample.brightnessTarget, sample.brightnessRevision) { mutableStateOf<Float?>(null) }
    val memoryPercent = if (sample.memoryTotal > 0) (sample.memoryUsed.toDouble() / sample.memoryTotal).toFloat().coerceIn(0f, 1f) else 0f
    val thermal = listOf("Nominal", "Fair", "Serious", "Critical").getOrElse(sample.thermalState.toInt()) { "Unavailable" }

    LazyVerticalGrid(
        columns = GridCells.Adaptive(156.dp),
        modifier = modifier.fillMaxWidth(),
        contentPadding = PaddingValues(4.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        item(span = { GridItemSpan(maxLineSpan) }) {
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(owner.status, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                if (owner.feedback.isNotEmpty()) Text(owner.feedback, style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
                if (owner.busy) LinearProgressIndicator(Modifier.fillMaxWidth())
            }
        }
        item { MeterCard("CPU", if (sample.cpuPercent < 0) "—" else "${sample.cpuPercent}%", sample.cpuPercent.coerceAtLeast(0).toFloat() / 100f) }
        item { MeterCard("Memory", "${bytesAsGB(sample.memoryUsed)} / ${bytesAsGB(sample.memoryTotal)} GB", memoryPercent) }
        item { MeterCard("Thermal pressure", thermal, sample.thermalState.toFloat() / 3f) }
        item(span = { GridItemSpan(maxLineSpan) }) { Text("Quick actions", style = MaterialTheme.typography.titleSmall) }
        item {
            val supported = sample.microphoneSupported
            val mute = !sample.microphoneMuted
            MacroCard(
                title = if (!supported) "Mute mic" else if (mute) "Mute mic" else "Unmute mic",
                detail = if (!supported) "Unavailable for the current input" else if (mute) "Default input is live" else "Default input is muted",
                enabled = supported && !owner.busy,
                onClick = {
                    haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                    owner.command(2, if (mute) 1 else 0, sample.microphoneTarget, sample.microphoneRevision)
                },
            )
        }
        items(actions) { action ->
            val supported = (sample.actions and action.bit) != 0L
            val enabled = supported && !owner.busy
            MacroCard(action.title, if (supported) action.detail else "Unavailable on this Mac", enabled) {
                haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                owner.command(action.action, action.value)
            }
        }
        item(span = { GridItemSpan(maxLineSpan) }) {
            Card(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("Mac output volume", style = MaterialTheme.typography.titleSmall, modifier = Modifier.weight(1f))
                        Text(if (sample.outputSupported) "${volumeDrag?.toInt() ?: owner.outputPreview?.toInt() ?: sample.outputLevel}%" else "Unavailable", style = MaterialTheme.typography.bodySmall)
                    }
                    if (sample.outputSupported) {
                        Slider(
                            value = volumeDrag ?: owner.outputPreview?.toFloat() ?: sample.outputLevel.toFloat(),
                            onValueChange = { volumeDrag = it },
                            valueRange = 0f..100f,
                            onValueChangeFinished = {
                                val value = volumeDrag?.toLong()
                                volumeDrag = null
                                if (value != null) owner.command(6, value, sample.outputTarget, sample.outputRevision)
                            },
                            modifier = Modifier.heightIn(min = 48.dp).semantics { contentDescription = "Mac output volume" },
                        )
                    } else {
                        Text("This Mac's current output does not expose a writable volume control.", style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
        }
        item(span = { GridItemSpan(maxLineSpan) }) {
            Card(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("Display brightness", style = MaterialTheme.typography.titleSmall, modifier = Modifier.weight(1f))
                        Text(if (sample.brightnessSupported) "${brightnessDrag?.toInt() ?: owner.brightnessPreview?.toInt() ?: sample.brightnessLevel}%" else "Unavailable",
                            style = MaterialTheme.typography.bodySmall)
                    }
                    if (sample.brightnessSupported) {
                        Slider(
                            value = brightnessDrag ?: owner.brightnessPreview?.toFloat() ?: sample.brightnessLevel.toFloat(),
                            onValueChange = { brightnessDrag = it },
                            valueRange = 0f..100f,
                            onValueChangeFinished = {
                                val value = brightnessDrag?.toLong()
                                brightnessDrag = null
                                if (value != null) owner.command(7, value, sample.brightnessTarget, sample.brightnessRevision)
                            },
                            modifier = Modifier.heightIn(min = 48.dp).semantics { contentDescription = "Mac display brightness" },
                        )
                    } else {
                        Text("Brightness control is unavailable in this version.", style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
        }
    }
}

@Composable
private fun MeterCard(title: String, value: String, progress: Float) {
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(title, style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Text(value, style = MaterialTheme.typography.titleMedium)
            LinearProgressIndicator(progress = { progress.coerceIn(0f, 1f) }, modifier = Modifier.fillMaxWidth())
        }
    }
}

@Composable
private fun MacroCard(title: String, detail: String, enabled: Boolean, onClick: () -> Unit) {
    Card(Modifier.fillMaxWidth().heightIn(min = 84.dp)) {
        Column(
            Modifier.fillMaxWidth().clickable(enabled = enabled, role = Role.Button, onClick = onClick)
                .semantics { contentDescription = "$title. $detail" }
                .padding(14.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Text(title, style = MaterialTheme.typography.titleSmall,
                color = if (enabled) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurfaceVariant)
            Text(detail, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

private fun bytesAsGB(value: Long): String = String.format(Locale.getDefault(), "%.1f", value.toDouble() / 1_073_741_824.0)
