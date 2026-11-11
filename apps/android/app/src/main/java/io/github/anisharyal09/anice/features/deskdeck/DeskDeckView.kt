// SPDX-License-Identifier: GPL-3.0-or-later
// Presents live Mac meters and explicit controls in a responsive phone-first deck.
package io.github.anisharyal09.anice.features.deskdeck

import android.content.Context
import android.text.format.DateUtils
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.clickable
import androidx.compose.foundation.verticalScroll
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
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity
import io.github.anisharyal09.anice.infrastructure.pairing.PeerTrustRecord
import io.github.anisharyal09.anice.ui.AutomaticConnectionToggle
import java.text.DateFormat
import java.util.Date
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
    var volumeDrag by remember(sample?.outputTarget, sample?.outputRevision) { mutableStateOf<Float?>(null) }
    var outputMenuExpanded by remember(sample?.protocolVersion) { mutableStateOf(false) }
    var cpuDetails by rememberSaveable { mutableStateOf(false) }
    var memoryDetails by rememberSaveable { mutableStateOf(false) }
    var showDetails by rememberSaveable { mutableStateOf(false) }
    var microphoneHelp by rememberSaveable { mutableStateOf(false) }
    var lockHelp by rememberSaveable { mutableStateOf(false) }
    var focusHelp by rememberSaveable { mutableStateOf(false) }
    var managingApps by rememberSaveable { mutableStateOf(false) }
    val fresh = owner.readingsAreFresh && connected
    val thermal = sample?.let { listOf("Nominal", "Fair", "Serious", "Critical").getOrElse(it.thermalState.toInt()) { "Unavailable" } } ?: "Waiting"
    val memoryAvailable = sample != null && sample.memoryTotal > 0 && sample.memoryUsed >= 0
    val memoryPercent = if (memoryAvailable) sample!!.memoryUsed.toFloat() / sample.memoryTotal else 0f
    val memoryTitle = if (sample != null && sample.protocolVersion < 3L) "Memory (legacy)" else "Memory used"

    val microphone: @Composable () -> Unit = {
        val supported = sample?.microphoneSupported == true
        val mute = sample?.microphoneMuted != true
        MacroCard(if (supported) { if (mute) "Mute input" else "Unmute input" } else "Mic mute",
            owner.actionFeedback(2).ifBlank { if (supported) "Mac default input" else "No controllable default input" },
            fresh && !owner.isBusy(2)) {
            if (supported) {
                haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                sample?.let { owner.command(2, if (mute) 1 else 0, it.microphoneTarget, it.microphoneRevision) }
            } else microphoneHelp = true
        }
    }
    val lockControl: @Composable () -> Unit = {
        val supported = sample != null && sample.actions and 1L != 0L
        MacroCard("Lock Mac", owner.actionFeedback(1).ifBlank { if (supported) "Lock this session" else "Events access needed" },
            fresh && !owner.isBusy(1)) {
            if (supported) { haptic.performHapticFeedback(HapticFeedbackType.LongPress); owner.command(1) }
            else lockHelp = true
        }
    }
    val screenshot: @Composable () -> Unit = {
        val supported = sample != null && sample.actions and 8L != 0L
        MacroCard("Screenshot", owner.actionFeedback(5).ifBlank { if (supported) "Open Mac capture controls" else "Capture controls unavailable" },
            fresh && supported && !owner.isBusy(5)) {
            haptic.performHapticFeedback(HapticFeedbackType.LongPress); owner.command(5)
        }
    }
    val focusToggle: @Composable () -> Unit = {
        val supportsV4 = sample?.protocolVersion?.let { it >= 4L } == true
        val available = sample?.let { supportsV4 && it.actions and 16L != 0L } == true
        val detail = owner.actionFeedback(9).ifBlank {
            when {
                !supportsV4 -> "Update aniCe on Mac"
                available -> "Mac-local toggle · no phone sync"
                else -> "Set up on Mac · no phone sync"
            }
        }
        MacroCard("DND mode", detail, fresh && supportsV4 && !owner.isBusy(9)) {
            if (available) {
                haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                owner.command(9)
            } else focusHelp = true
        }
    }
    BoxWithConstraints(modifier.fillMaxWidth()) {
        val wide = maxWidth >= 600.dp
        val columns = if (wide) 4 else 2
        LazyVerticalGrid(
            columns = GridCells.Fixed(columns), modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(bottom = 12.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            item(span = { GridItemSpan(maxLineSpan) }) {
                Card(Modifier.fillMaxWidth()) {
                    Column(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp),
                        verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                                Text(target?.deviceName ?: "Mac", style = MaterialTheme.typography.titleSmall,
                                    maxLines = 1, overflow = TextOverflow.Ellipsis)
                                Text(connectionSummary(owner, connected, sample), style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            }
                            if (!connected && target != null) {
                                TextButton(onClick = onConnect, modifier = Modifier.heightIn(min = 48.dp)) { Text("Connect") }
                            } else if (owner.connectionState in setOf(DeskDeckConnectionState.STALE, DeskDeckConnectionState.FAILED)) {
                                TextButton(onClick = owner::refresh, modifier = Modifier.heightIn(min = 48.dp)) { Text("Refresh") }
                            }
                            TextButton(onClick = { showDetails = true }, modifier = Modifier.heightIn(min = 48.dp)) { Text("Details") }
                        }
                        HorizontalDivider()
                        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                            PowerSummary("Mac", macPowerSummary(sample), Modifier.weight(1f))
                            PowerSummary("Phone", phonePowerSummary(phonePower), Modifier.weight(1f))
                        }
                    }
                }
            }
            item {
                MeterCard("CPU", sample?.let { if (it.cpuPercent < 0) "Collecting…" else "${it.cpuPercent}%" } ?: "Waiting…",
                    sample?.cpuPercent?.coerceAtLeast(0)?.toFloat()?.div(100f) ?: 0f, { cpuDetails = true }, "Across all cores")
            }
            item {
                MeterCard(memoryTitle, if (memoryAvailable) "${bytesAsGB(sample!!.memoryUsed)} GiB" else "Unavailable",
                    memoryPercent, { memoryDetails = true }, if (sample != null && sample.memoryTotal > 0) "of ${bytesAsGB(sample.memoryTotal)} GiB" else "Waiting for Mac")
            }
            if (wide) {
                item { microphone() }
                item { lockControl() }
            }
            item(span = { GridItemSpan(if (wide) 2 else maxLineSpan) }) {
                Column(Modifier.fillMaxWidth().padding(horizontal = 4.dp)) {
                    val routeSample = sample?.takeIf { it.protocolVersion >= 5L }
                    if (routeSample != null) {
                        val routeSwitchAvailable = routeSample.actions and 32L != 0L
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Column(Modifier.weight(1f)) {
                                Text("Output device", style = MaterialTheme.typography.labelLarge)
                                Text(if (owner.outputCatalogLoaded) owner.selectedOutputName(routeSample) else "Loading Mac outputs…",
                                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    maxLines = 1, overflow = TextOverflow.Ellipsis)
                            }
                            Box {
                                TextButton(onClick = {
                                    if (owner.outputCatalogLoaded && owner.outputRoutes.isNotEmpty()) outputMenuExpanded = true
                                    else owner.refreshOutputRoutes()
                                }, enabled = fresh && routeSwitchAvailable && !owner.isBusy(10L) &&
                                    (owner.outputCatalogLoaded || !owner.outputCatalogLoading), modifier = Modifier.heightIn(min = 48.dp)) {
                                    Text(if (owner.outputCatalogLoaded) "Choose" else if (owner.outputCatalogLoading) "Loading…" else "Load")
                                }
                                DropdownMenu(expanded = outputMenuExpanded, onDismissRequest = { outputMenuExpanded = false }) {
                                    owner.outputRoutes.forEach { route ->
                                        DropdownMenuItem(
                                            text = { Text(if (route.id == routeSample.outputRouteID) "${route.name} · Current" else route.name) },
                                            onClick = {
                                                outputMenuExpanded = false
                                                if (route.id != routeSample.outputRouteID) {
                                                    haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                                                    owner.selectOutputRoute(route.id)
                                                }
                                            },
                                            enabled = fresh && !owner.isBusy(10L),
                                        )
                                    }
                                }
                            }
                            TextButton(onClick = owner::refreshOutputRoutes, enabled = fresh && routeSwitchAvailable && !owner.isBusy(10L),
                                modifier = Modifier.heightIn(min = 48.dp)) { Text("Refresh") }
                        }
                        if (owner.outputCatalogLoaded && owner.outputRoutes.isEmpty()) {
                            Text("No available Mac output devices.", style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant)
                        } else if (!routeSwitchAvailable) {
                            Text("Output switching is unavailable on this Mac.", style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                        if (owner.actionFeedback(10L).isNotBlank()) {
                            Text(owner.actionFeedback(10L), style = MaterialTheme.typography.bodySmall)
                        }
                    } else if (sample != null) {
                        Text("Update aniCe on Mac to choose its output device.", style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("Output volume", style = MaterialTheme.typography.labelLarge, modifier = Modifier.weight(1f))
                        Text(if (sample?.outputSupported == true) "${volumeDrag?.toInt() ?: owner.outputPreview?.toInt() ?: sample.outputLevel}%" else "Unavailable",
                            style = MaterialTheme.typography.bodySmall)
                    }
                    if (sample?.outputSupported == true) {
                        Slider(value = volumeDrag ?: owner.outputPreview?.toFloat() ?: sample.outputLevel.toFloat(),
                            onValueChange = { volumeDrag = it }, valueRange = 0f..100f,
                            onValueChangeFinished = {
                                val value = volumeDrag?.toLong(); volumeDrag = null
                                if (value != null) owner.command(6, value, sample.outputTarget, sample.outputRevision)
                            }, enabled = fresh,
                            modifier = Modifier.heightIn(min = 48.dp).semantics { contentDescription = "Mac output volume" })
                    }
                    if (owner.actionFeedback(6L).isNotBlank()) Text(owner.actionFeedback(6L), style = MaterialTheme.typography.bodySmall)
                }
            }
            if (!wide) {
                item { microphone() }
                item { lockControl() }
            }
            item(span = { GridItemSpan(if (wide) 1 else maxLineSpan) }) { screenshot() }
            item(span = { GridItemSpan(if (wide) 1 else maxLineSpan) }) { focusToggle() }
            item(span = { GridItemSpan(maxLineSpan) }) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("Apps", style = MaterialTheme.typography.titleSmall, modifier = Modifier.weight(1f))
                    if (target?.let(owner::usesLegacyShortcuts) != true) {
                        TextButton(onClick = { managingApps = !managingApps }, modifier = Modifier.heightIn(min = 48.dp)) {
                            Text(if (managingApps) "Done" else "Arrange")
                        }
                    }
                }
            }
            if (target?.let(owner::usesLegacyShortcuts) == true) {
                items(listOf(DeckAction("Terminal", "Open on Mac", 4, 4), DeckAction("Blender", "Open on Mac", 3, 2))) { action ->
                    MacroCard(action.title, owner.actionFeedback(action.action).ifBlank { action.detail },
                        fresh && sample != null && sample.actions and action.bit != 0L && !owner.isBusy(action.action)) { owner.command(action.action) }
                }
            } else {
                val listed = owner.shortcuts.filter { managingApps || it.id in owner.pinnedShortcutIDs }
                if (listed.isEmpty()) {
                    item(span = { GridItemSpan(maxLineSpan) }) {
                        Text(when {
                            !owner.shortcutCatalogLoaded -> "Waiting for approved apps…"
                            owner.shortcuts.isEmpty() -> "Approve apps on your Mac in Settings → Desk Deck."
                            else -> "No pinned apps. Tap Arrange to choose shortcuts."
                        }, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
                items(listed, key = { it.id }) { shortcut ->
                    if (managingApps) {
                        ShortcutCard(shortcut, shortcut.id in owner.pinnedShortcutIDs, owner.isShortcutBusy(shortcut.id),
                            owner.shortcutFeedback(shortcut.id), fresh && !owner.isShortcutBusy(shortcut.id), true,
                            onLaunch = { owner.launchShortcut(shortcut.id) },
                            onPin = { owner.setShortcutPinned(target?.fingerprint.orEmpty(), shortcut.id, shortcut.id !in owner.pinnedShortcutIDs) },
                            onMove = { owner.moveShortcut(target?.fingerprint.orEmpty(), shortcut.id, it) })
                    } else {
                        MacroCard(shortcut.name, owner.shortcutFeedback(shortcut.id).ifBlank { if (owner.isShortcutBusy(shortcut.id)) "Launching…" else "Open on Mac" },
                            fresh && !owner.isShortcutBusy(shortcut.id)) {
                            haptic.performHapticFeedback(HapticFeedbackType.LongPress); owner.launchShortcut(shortcut.id)
                        }
                    }
                }
            }
        }
    }
    if (cpuDetails) DeckDetailDialog("CPU", { cpuDetails = false }) {
        HistoryChart(owner.history, memory = false)
        Text("Whole-system use across all cores, from 0 to 100%. Compare with User + System at the bottom of Activity Monitor’s CPU tab.", style = MaterialTheme.typography.bodyMedium)
        Text("Sampled about once per second. Different update intervals can produce short differences.", style = MaterialTheme.typography.bodySmall)
    }
    if (memoryDetails) DeckDetailDialog(memoryTitle, { memoryDetails = false }) {
        HistoryChart(owner.history, memory = true)
        if (sample != null) {
            MemoryDetailRow("Physical", sample.memoryTotal)
            if (sample.protocolVersion >= 3) {
                MemoryDetailRow("Used", sample.memoryUsed)
                MemoryDetailRow("App", sample.memoryApp)
                MemoryDetailRow("Wired", sample.memoryWired)
                MemoryDetailRow("Compressed", sample.memoryCompressed)
                MemoryDetailRow("Other resident", if (sample.memoryUsed >= 0) sample.memoryUsed - sample.memoryApp - sample.memoryWired - sample.memoryCompressed else -1)
                HorizontalDivider()
                MemoryDetailRow("Cached files", sample.memoryCached)
                MemoryDetailRow("Free", sample.memoryFree)
                MemoryDetailRow("Swap used", sample.memorySwap)
                Text("Used = physical − free − cached files. Other resident is the remainder outside the app, wired and compressed categories. Cached files are reclaimable; swap is disk usage.", style = MaterialTheme.typography.bodySmall)
            } else {
                MemoryDetailRow("Active", sample.memoryActive)
                MemoryDetailRow("Wired", sample.memoryWired)
                MemoryDetailRow("Compressed", sample.memoryCompressed)
                Text("This Mac uses an older sample format. Its category sum is not Activity Monitor’s Memory Used. Update aniCe on the Mac for app, cache and swap readings.", style = MaterialTheme.typography.bodySmall)
            }
            Text("Values use GiB (1,073,741,824 bytes).", style = MaterialTheme.typography.bodySmall)
        }
    }
    if (showDetails) DeckDetailDialog("Desk Deck details", { showDetails = false }) {
        Text(owner.status, style = MaterialTheme.typography.bodyMedium)
        Text("Connection · ${owner.activeTransportLabel()}", style = MaterialTheme.typography.bodySmall)
        Text(sample?.let { "Last data · ${sampleTimestamp(it, includeDate = true)}" } ?: "No data received yet",
            style = MaterialTheme.typography.bodySmall)
        Text("Thermal pressure: $thermal. Fair means rising pressure; Serious or Critical can reduce performance. This is not a temperature reading.", style = MaterialTheme.typography.bodySmall)
        if (owner.feedback.isNotBlank()) Text(owner.feedback, style = MaterialTheme.typography.bodySmall)
        AutomaticConnectionToggle(
            checked = keepAwake,
            enabled = true,
            onCheckedChange = onKeepAwakeChange,
            label = "Keep awake while charging",
            description = "Only while Desk Deck is visible and the phone has external power.",
        )
        TextButton(onClick = owner::refresh, enabled = connected, modifier = Modifier.heightIn(min = 48.dp)) { Text("Refresh readings") }
    }
    if (microphoneHelp) DeckDetailDialog("Mac input mute unavailable", { microphoneHelp = false }) {
        Text("Desk Deck can mute only the Mac’s current default input when Core Audio exposes a writable mute control. This Mac reports no controllable default input.", style = MaterialTheme.typography.bodyMedium)
        Text("Choose a microphone in Mac System Settings → Sound → Input, then refresh Desk Deck. Some inputs do not provide a software mute switch. This is not a hardware kill switch and does not affect apps using another input.", style = MaterialTheme.typography.bodySmall)
    }
    if (lockHelp) DeckDetailDialog("Enable Lock Mac", { lockHelp = false }) {
        Text("On your Mac, open aniCe → Settings → Permissions → Request Events access. Enable access for the running aniCe build in System Settings, then return to aniCe.", style = MaterialTheme.typography.bodyMedium)
        Text("A rebuilt ad hoc app may need access again. If access is enabled but still unavailable, restart aniCe on the Mac.", style = MaterialTheme.typography.bodySmall)
    }
    if (focusHelp) DeckDetailDialog("Set up DND mode", { focusHelp = false }) {
        Text("This control runs the selected toggle Shortcut on the Mac only. It does not sync DND to the phone. Select a tested shortcut in Mac aniCe → Settings → Do Not Disturb → Desk Deck button.", style = MaterialTheme.typography.bodyMedium)
        Text("aniCe confirms whether Shortcuts ran, not the resulting Focus state. Focus may sync to other Apple devices when Share Across Devices is enabled.", style = MaterialTheme.typography.bodySmall)
    }
}

@Composable
private fun DeckDetailDialog(title: String, onDismiss: () -> Unit, content: @Composable ColumnScope.() -> Unit) {
    AlertDialog(onDismissRequest = onDismiss, title = { Text(title) },
        text = { Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(8.dp), content = content) },
        confirmButton = { TextButton(onClick = onDismiss, modifier = Modifier.heightIn(min = 48.dp)) { Text("Done") } })
}

@Composable
private fun MemoryDetailRow(label: String, bytes: Long) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(label, modifier = Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
        Text(if (bytes < 0) "Unavailable" else "${String.format(Locale.getDefault(), "%.2f", bytes.toDouble() / 1_073_741_824.0)} GiB", style = MaterialTheme.typography.bodyMedium)
    }
}

@Composable
private fun MeterCard(title: String, value: String, progress: Float, onOpen: () -> Unit, subtitle: String) {
    Card(Modifier.fillMaxWidth().clickable(role = Role.Button, onClick = onOpen).semantics { contentDescription = "$title details" }) {
        Column(Modifier.fillMaxWidth().padding(12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(title, style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Text(value, style = MaterialTheme.typography.titleLarge)
            Text(subtitle, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            LinearProgressIndicator(progress = { progress.coerceIn(0f, 1f) }, modifier = Modifier.fillMaxWidth().padding(top = 4.dp))
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
    OutlinedCard(onClick = onClick, enabled = enabled, modifier = Modifier.fillMaxWidth().heightIn(min = 80.dp)
        .semantics { contentDescription = "$title. $detail" }) {
        Column(
            Modifier.fillMaxWidth().padding(12.dp),
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

@Composable
private fun PowerSummary(title: String, value: String, modifier: Modifier = Modifier) {
    Column(modifier, verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text(title, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(value, style = MaterialTheme.typography.bodySmall, maxLines = 2, overflow = TextOverflow.Ellipsis)
    }
}

private fun connectionSummary(owner: DeskDeckController, connected: Boolean, sample: DeskDeckSnapshot?): String {
    val lastData = sample?.let { " · Last data ${sampleTimestamp(it)}" }.orEmpty()
    return when {
        !connected && sample != null -> "Disconnected$lastData"
        !connected -> "Disconnected"
        owner.connectionState == DeskDeckConnectionState.OPENING -> "Connecting…$lastData"
        owner.connectionState == DeskDeckConnectionState.FAILED -> "Mac isn’t responding$lastData"
        owner.connectionState == DeskDeckConnectionState.STALE -> "No recent data$lastData"
        sample != null -> "Live · ${owner.activeTransportLabel()} · Updated ${sampleTimestamp(sample)}"
        else -> "Opening Desk Deck…"
    }
}

private fun sampleTimestamp(sample: DeskDeckSnapshot, includeDate: Boolean = false): String {
    val timestamp = sample.receivedAtWallMillis
    val value = Date(timestamp)
    val format = if (includeDate || !DateUtils.isToday(timestamp)) {
        DateFormat.getDateTimeInstance(DateFormat.SHORT, DateFormat.SHORT)
    } else DateFormat.getTimeInstance(DateFormat.SHORT)
    return format.format(value)
}

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

private fun phonePowerSummary(power: DevicePowerReading): String {
    val source = when (power.source) {
        1L -> "Battery"
        2L -> "AC"
        3L -> "USB"
        4L -> "Wireless"
        5L -> "Dock"
        else -> ""
    }
    return listOfNotNull(power.percent?.let { "$it%" }, power.label,
        source.takeIf { it.isNotEmpty() && power.state !in setOf(1L, 2L) })
        .joinToString(" · ")
}

private fun bytesAsGB(value: Long): String = String.format(Locale.getDefault(), "%.1f", value.toDouble() / 1_073_741_824.0)
