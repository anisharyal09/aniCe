// SPDX-License-Identifier: GPL-3.0-or-later
// Presents live Mac meters and explicit controls in a responsive phone-first deck.
package io.github.anisharyal09.anice.features.deskdeck

import android.content.Context
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity
import io.github.anisharyal09.anice.infrastructure.pairing.PeerTrustRecord
import kotlinx.coroutines.delay
import java.util.Locale

@Composable
fun DeskDeckView(
    owner: DeskDeckController,
    power: DevicePowerController,
    peers: List<PeerTrustRecord>,
    trustedPeersLoaded: Boolean,
    onConnect: (DeviceIdentity) -> Unit,
    onPairMac: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current.applicationContext
    val preferences = remember(context) { context.getSharedPreferences("desk_deck", Context.MODE_PRIVATE) }
    val rememberedID = preferences.getString("selected_peer", null)
    var selectedID by rememberSaveable { mutableStateOf(rememberedID.orEmpty()) }
    val target = peers.firstOrNull { it.peer.deviceId == selectedID }?.peer
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val view = LocalView.current
    var keepAwake by remember { mutableStateOf(preferences.getBoolean("keep_awake_charging", false)) }
    val phonePower = power.reading

    LaunchedEffect(peers.map { it.peer.deviceId to it.peer.fingerprint }, trustedPeersLoaded) {
        if (!trustedPeersLoaded) return@LaunchedEffect
        owner.retainTrustedPeers(peers.mapTo(mutableSetOf()) { it.peer.fingerprint })
        if (peers.none { it.peer.deviceId == selectedID }) {
            selectedID = peers.firstOrNull { owner.connected(it.peer) }?.peer?.deviceId ?: peers.firstOrNull()?.peer?.deviceId.orEmpty()
        }
    }
    LaunchedEffect(selectedID, trustedPeersLoaded) {
        if (trustedPeersLoaded) preferences.edit().putString("selected_peer", selectedID).apply()
    }
    LaunchedEffect(keepAwake) { preferences.edit().putBoolean("keep_awake_charging", keepAwake).apply() }
    LaunchedEffect(Unit) { power.refresh() }

    DisposableEffect(lifecycle, target) {
        fun start() { if (lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)) target?.let(owner::start) }
        start()
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_START) start()
            if (event == Lifecycle.Event.ON_STOP) owner.stop()
        }
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer); owner.stop() }
    }
    DisposableEffect(context, lifecycle, view, keepAwake, phonePower.plugged) {
        fun update() {
            view.keepScreenOn = keepAwake && phonePower.plugged && lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)
        }
        val observer = LifecycleEventObserver { _, _ -> update() }
        lifecycle.addObserver(observer)
        update()
        onDispose { lifecycle.removeObserver(observer); view.keepScreenOn = false }
    }
    Column(modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        if (!trustedPeersLoaded && owner.snapshot != null) {
            DeskDeckGrid(
                owner = owner,
                target = null,
                sample = owner.snapshot,
                connected = false,
                phonePower = phonePower,
                keepAwake = keepAwake,
                onKeepAwakeChange = { keepAwake = it },
                onConnect = {},
                modifier = Modifier.weight(1f),
            )
        } else if (!trustedPeersLoaded) {
            Card(Modifier.fillMaxWidth()) {
                Text("Loading trusted devices…", Modifier.padding(16.dp), style = MaterialTheme.typography.bodyMedium)
            }
        } else if (peers.isEmpty()) {
            Card(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("Pair a Mac to use Desk Deck.", style = MaterialTheme.typography.bodyMedium)
                    OutlinedButton(onClick = onPairMac, modifier = Modifier.heightIn(min = 48.dp)) { Text("Pair a Mac") }
                }
            }
        } else {
            if (peers.size > 1) {
                Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    peers.forEach { record ->
                        FilterChip(
                            selected = record.peer.deviceId == selectedID,
                            onClick = { selectedID = record.peer.deviceId },
                            label = { Text(record.peer.deviceName, maxLines = 1) },
                        )
                    }
                }
            }
            DeskDeckGrid(
                owner = owner,
                target = target,
                sample = owner.snapshot,
                connected = target?.let(owner::connected) == true,
                phonePower = phonePower,
                keepAwake = keepAwake,
                onKeepAwakeChange = { keepAwake = it },
                onConnect = { target?.let(onConnect) },
                modifier = Modifier.weight(1f),
            )
        }
    }
}

private data class DeckAction(val title: String, val detail: String, val action: Long, val bit: Long, val value: Long = -1)

@Composable
private fun DeskDeckGrid(
    owner: DeskDeckController,
    target: DeviceIdentity?,
    sample: DeskDeckSnapshot?,
    connected: Boolean,
    phonePower: DevicePowerReading,
    keepAwake: Boolean,
    onKeepAwakeChange: (Boolean) -> Unit,
    onConnect: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val haptic = LocalHapticFeedback.current
    val actions = listOf(
        DeckAction("Lock Mac", "Lock the current Mac session", 1, 1),
        DeckAction("Take Screenshot", "Start the Mac area-capture tool", 5, 8),
    )
    var volumeDrag by remember(sample?.outputTarget, sample?.outputRevision) { mutableStateOf<Float?>(null) }
    var cpuDetails by rememberSaveable { mutableStateOf(false) }
    var memoryDetails by rememberSaveable { mutableStateOf(false) }
    var thermalDetails by rememberSaveable { mutableStateOf(false) }
    var showConnectionDetails by rememberSaveable { mutableStateOf(false) }
    var showAllShortcuts by rememberSaveable { mutableStateOf(false) }
    var ageNow by remember { mutableLongStateOf(android.os.SystemClock.elapsedRealtime()) }
    LaunchedEffect(sample?.sequence) {
        while (true) {
            delay(1_000)
            ageNow = android.os.SystemClock.elapsedRealtime()
        }
    }
    val fresh = owner.readingsAreFresh && connected
    val legacyShortcuts = target?.let(owner::usesLegacyShortcuts) == true
    val memoryPercent = sample?.let { if (it.memoryTotal > 0) (it.memoryUsed.toDouble() / it.memoryTotal).toFloat().coerceIn(0f, 1f) else 0f } ?: 0f
    val thermal = sample?.let { listOf("Nominal", "Fair", "Serious", "Critical").getOrElse(it.thermalState.toInt()) { "Unavailable" } } ?: "Collecting…"

    LazyVerticalGrid(
        columns = GridCells.Adaptive(156.dp),
        modifier = modifier.fillMaxWidth(),
        contentPadding = PaddingValues(bottom = 8.dp, start = 2.dp, end = 2.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        item(span = { GridItemSpan(maxLineSpan) }) {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Column(Modifier.weight(1f)) {
                        Text(target?.deviceName ?: "Mac Desk Deck", style = MaterialTheme.typography.titleMedium)
                        Text(connectionSummary(owner, connected, sample, ageNow), style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    if (connected && owner.connectionState in setOf(DeskDeckConnectionState.STALE, DeskDeckConnectionState.FAILED)) {
                        OutlinedButton(onClick = owner::refresh, modifier = Modifier.heightIn(min = 48.dp)) { Text("Refresh") }
                    } else if (!connected && target != null) {
                        OutlinedButton(onClick = onConnect, modifier = Modifier.heightIn(min = 48.dp)) { Text("Connect") }
                    }
                }
                Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text("Phone · ${phonePower.percent?.let { "$it% · " } ?: ""}${phonePower.label}",
                        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Text("Mac · ${macPowerSummary(sample)}", style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                TextButton(onClick = { showConnectionDetails = !showConnectionDetails }, modifier = Modifier.heightIn(min = 48.dp)) {
                    Text(if (showConnectionDetails) "Hide connection details" else "Connection details")
                }
                if (showConnectionDetails) {
                    Text("Transport · ${owner.activeTransportLabel()} · Last sample · ${sample?.let { sampleAge(it, ageNow) } ?: "none yet"}",
                        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Text(owner.status, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                if (owner.feedback.isNotEmpty()) Text(owner.feedback, style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        item { MeterCard("CPU", sample?.let { if (it.cpuPercent < 0) "Collecting…" else "${it.cpuPercent}%" } ?: "Waiting…", sample?.let { it.cpuPercent.coerceAtLeast(0).toFloat() / 100f } ?: 0f, cpuDetails, { cpuDetails = !cpuDetails }) {
            HistoryChart(owner.history, memory = false)
            Text("Whole-system CPU use. The first counter reading establishes a baseline.", style = MaterialTheme.typography.bodySmall)
        } }
        item { MeterCard("Memory", sample?.let { "${bytesAsGB(it.memoryUsed)} / ${bytesAsGB(it.memoryTotal)} GB" } ?: "Waiting…", memoryPercent, memoryDetails, { memoryDetails = !memoryDetails }) {
            if (sample != null && sample.memoryActive >= 0) {
                Text("Active · ${bytesAsGB(sample.memoryActive)} GB", style = MaterialTheme.typography.bodySmall)
                Text("Wired · ${bytesAsGB(sample.memoryWired)} GB", style = MaterialTheme.typography.bodySmall)
                Text("Compressed · ${bytesAsGB(sample.memoryCompressed)} GB", style = MaterialTheme.typography.bodySmall)
                Text("Physical memory total · ${bytesAsGB(sample.memoryTotal)} GB", style = MaterialTheme.typography.bodySmall)
            } else Text("Used memory combines active, wired and compressed pages. Breakdown requires an updated Mac.", style = MaterialTheme.typography.bodySmall)
            HistoryChart(owner.history, memory = true)
        } }
        item { MeterCard("Thermal pressure", thermal, sample?.let { it.thermalState.toFloat() / 3f } ?: 0f, thermalDetails, { thermalDetails = !thermalDetails }) {
            Text("Nominal: normal. Fair: pressure is rising. Serious or Critical: macOS may reduce performance to manage heat. These are states, not temperatures.", style = MaterialTheme.typography.bodySmall)
        } }

        item(span = { GridItemSpan(maxLineSpan) }) { Text("Quick actions", style = MaterialTheme.typography.titleSmall) }
        if (sample == null) {
            item(span = { GridItemSpan(maxLineSpan) }) {
                Text("Actions appear when the Mac is connected and sending fresh readings.", style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        } else {
            item {
                val supported = sample.microphoneSupported
                val shouldMute = !sample.microphoneMuted
                MacroCard(
                    title = if (shouldMute) "Mute mic" else "Unmute mic",
                    detail = owner.actionFeedback(2L).ifBlank { if (supported) "Default input · ${if (sample.microphoneMuted) "muted" else "live"}" else "Unavailable for current input" },
                    enabled = fresh && supported && !owner.isBusy(2L),
                    onClick = {
                        haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                        owner.command(2, if (shouldMute) 1 else 0, sample.microphoneTarget, sample.microphoneRevision)
                    },
                )
            }
            items(actions) { action ->
                val supported = (sample.actions and action.bit) != 0L
                MacroCard(
                    action.title,
                    owner.actionFeedback(action.action).ifBlank { if (supported) action.detail else "Unavailable on this Mac" },
                    fresh && supported && !owner.isBusy(action.action),
                ) {
                    haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                    owner.command(action.action, action.value)
                }
            }
            if (legacyShortcuts) {
                val legacyApps = listOf(
                    DeckAction("Launch Blender", "Open Blender", 3, 2),
                    DeckAction("Launch Terminal", "Open Terminal", 4, 4),
                )
                items(legacyApps) { action ->
                    val supported = (sample.actions and action.bit) != 0L
                    MacroCard(action.title, owner.actionFeedback(action.action).ifBlank { if (supported) action.detail else "Unavailable on this Mac" },
                        fresh && supported && !owner.isBusy(action.action)) {
                        haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                        owner.command(action.action)
                    }
                }
            } else {
                item(span = { GridItemSpan(maxLineSpan) }) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("Approved apps", style = MaterialTheme.typography.titleSmall, modifier = Modifier.weight(1f))
                        TextButton(onClick = { showAllShortcuts = !showAllShortcuts }, modifier = Modifier.heightIn(min = 48.dp)) {
                            Text(if (showAllShortcuts) "Done" else "Manage")
                        }
                    }
                }
                val listedShortcuts = owner.shortcuts.filter { showAllShortcuts || it.id in owner.pinnedShortcutIDs }
                if (listedShortcuts.isEmpty()) {
                    item(span = { GridItemSpan(maxLineSpan) }) {
                        Text("Loading approved apps…", style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                } else items(listedShortcuts, key = { it.id }) { shortcut ->
                    ShortcutCard(
                        shortcut = shortcut,
                        pinned = shortcut.id in owner.pinnedShortcutIDs,
                        busy = owner.isShortcutBusy(shortcut.id),
                        feedback = owner.shortcutFeedback(shortcut.id),
                        enabled = fresh && !owner.isShortcutBusy(shortcut.id),
                        managing = showAllShortcuts,
                        onLaunch = {
                            haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                            owner.launchShortcut(shortcut.id)
                        },
                        onPin = { owner.setShortcutPinned(target?.fingerprint.orEmpty(), shortcut.id, shortcut.id !in owner.pinnedShortcutIDs) },
                        onMove = { direction -> owner.moveShortcut(target?.fingerprint.orEmpty(), shortcut.id, direction) },
                    )
                }
            }
        }
        item(span = { GridItemSpan(maxLineSpan) }) {
            Card(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(horizontal = 14.dp, vertical = 10.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("Mac output volume", style = MaterialTheme.typography.titleSmall, modifier = Modifier.weight(1f))
                        Text(if (sample?.outputSupported == true) "${volumeDrag?.toInt() ?: owner.outputPreview?.toInt() ?: sample.outputLevel}%" else "Unavailable",
                            style = MaterialTheme.typography.bodySmall)
                    }
                    if (sample?.outputSupported == true) {
                        Slider(
                            value = volumeDrag ?: owner.outputPreview?.toFloat() ?: sample.outputLevel.toFloat(),
                            onValueChange = { volumeDrag = it },
                            valueRange = 0f..100f,
                            onValueChangeFinished = {
                                val value = volumeDrag?.toLong()
                                volumeDrag = null
                                if (value != null) owner.command(6, value, sample.outputTarget, sample.outputRevision)
                            },
                            enabled = fresh,
                            modifier = Modifier.heightIn(min = 48.dp).semantics { contentDescription = "Mac output volume" },
                        )
                    } else {
                        Text("This Mac's current output does not expose a writable volume control.", style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    if (owner.actionFeedback(6L).isNotBlank()) Text(owner.actionFeedback(6L), style = MaterialTheme.typography.bodySmall)
                }
            }
        }
        item(span = { GridItemSpan(maxLineSpan) }) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("Keep screen awake while charging", style = MaterialTheme.typography.bodyMedium)
                    Text("Only while Desk Deck is visible and the phone is plugged in.", style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                Switch(checked = keepAwake, onCheckedChange = onKeepAwakeChange)
            }
        }
    }
}

@Composable
private fun MeterCard(title: String, value: String, progress: Float, expanded: Boolean, onToggle: () -> Unit, details: @Composable ColumnScope.() -> Unit) {
    Card(Modifier.fillMaxWidth().clickable(role = Role.Button, onClick = onToggle).semantics { contentDescription = "$title details" }) {
        Column(Modifier.fillMaxWidth().padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(title, style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.weight(1f))
                Text(if (expanded) "⌄" else "›", style = MaterialTheme.typography.titleMedium,
                    modifier = Modifier.semantics { contentDescription = if (expanded) "Collapse $title details" else "Expand $title details" })
            }
            Text(value, style = MaterialTheme.typography.titleMedium)
            LinearProgressIndicator(progress = { progress.coerceIn(0f, 1f) }, modifier = Modifier.fillMaxWidth())
            if (expanded) Column(verticalArrangement = Arrangement.spacedBy(6.dp), content = details)
        }
    }
}

@Composable
private fun HistoryChart(points: List<DeskDeckHistoryPoint>, memory: Boolean) {
    val color = MaterialTheme.colorScheme.primary
    Canvas(Modifier.fillMaxWidth().height(36.dp).semantics { contentDescription = if (memory) "Recent memory history" else "Recent CPU history" }) {
        if (points.size < 2) return@Canvas
        val path = Path()
        var started = false
        points.forEachIndexed { index, point ->
            val value = (if (memory) point.memoryPercent else point.cpuPercent)?.coerceIn(0, 100)
            if (value == null) { started = false; return@forEachIndexed }
            val x = size.width * index / (points.size - 1).coerceAtLeast(1)
            val y = size.height * (1f - value / 100f)
            if (started) path.lineTo(x, y) else path.moveTo(x, y)
            started = true
        }
        drawPath(path, color, style = Stroke(width = 2.dp.toPx(), cap = StrokeCap.Round))
    }
}

@Composable
private fun MacroCard(title: String, detail: String, enabled: Boolean, onClick: () -> Unit) {
    Card(Modifier.fillMaxWidth().heightIn(min = 76.dp)) {
        Column(
            Modifier.fillMaxWidth().clickable(enabled = enabled, role = Role.Button, onClick = onClick)
                .semantics { contentDescription = "$title. $detail" }.padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Text(title, style = MaterialTheme.typography.titleSmall,
                color = if (enabled) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurfaceVariant)
            Text(detail, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@Composable
private fun ShortcutCard(
    shortcut: DeskDeckShortcut,
    pinned: Boolean,
    busy: Boolean,
    feedback: String,
    enabled: Boolean,
    managing: Boolean,
    onLaunch: () -> Unit,
    onPin: () -> Unit,
    onMove: (Int) -> Unit,
) {
    Card(Modifier.fillMaxWidth().heightIn(min = 88.dp)) {
        Row(Modifier.fillMaxWidth().padding(6.dp), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                TextButton(onClick = onLaunch, enabled = enabled, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) {
                    Text(shortcut.name, maxLines = 2)
                }
                Text(if (busy) "Launching…" else feedback, style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(horizontal = 8.dp))
            }
            if (managing) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    TextButton(onClick = { onMove(-1) }, modifier = Modifier.sizeIn(minWidth = 48.dp, minHeight = 48.dp)) { Text("↑") }
                    TextButton(onClick = { onMove(1) }, modifier = Modifier.sizeIn(minWidth = 48.dp, minHeight = 48.dp)) { Text("↓") }
                }
            }
            TextButton(onClick = onPin, modifier = Modifier.sizeIn(minWidth = 48.dp, minHeight = 48.dp)) {
                Text(if (pinned) "Pinned" else "Pin")
            }
        }
    }
}

private fun connectionSummary(owner: DeskDeckController, connected: Boolean, sample: DeskDeckSnapshot?, now: Long): String = when {
    !connected && sample != null -> "Cached · stale · ${sampleAge(sample, now)}"
    !connected -> "Disconnected · Connect to see live hardware readings"
    owner.connectionState == DeskDeckConnectionState.OPENING -> owner.status
    owner.connectionState == DeskDeckConnectionState.FAILED -> owner.status
    owner.connectionState == DeskDeckConnectionState.STALE -> owner.status
    sample != null -> "Live · ${owner.activeTransportLabel()} · ${sampleAge(sample, now)}"
    else -> owner.status
}

private fun sampleAge(sample: DeskDeckSnapshot, now: Long = android.os.SystemClock.elapsedRealtime()): String =
    "${((now - sample.receivedAtMillis).coerceAtLeast(0) / 1000)}s ago"

private fun macPowerSummary(sample: DeskDeckSnapshot?): String {
    if (sample == null) return "Unavailable"
    val state = when (sample.powerState) {
        1L -> "No battery"
        2L -> "On battery"
        3L -> "Charging"
        4L -> "Fully charged"
        5L -> "Plugged in · not charging"
        else -> "Power unavailable"
    }
    val source = when (sample.powerSource) { 1L -> "Battery"; 2L -> "AC"; 3L -> "UPS"; else -> "" }
    val percent = sample.powerPercent.takeIf { it >= 0 }?.let { " · $it%" }.orEmpty()
    val powerSource = source.takeIf { it.isNotEmpty() }?.let { " · $it" }.orEmpty()
    return state + percent + powerSource
}
private fun bytesAsGB(value: Long): String = String.format(Locale.getDefault(), "%.1f", value.toDouble() / 1_073_741_824.0)
