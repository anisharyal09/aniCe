// SPDX-License-Identifier: GPL-3.0-or-later
// Presents live Mac meters, subscription controls and independently gated Find Mac in one deck.
package io.github.anisharyal09.anice.features.deskdeck
import io.github.anisharyal09.anice.infrastructure.connections.displayName

import android.content.Context
import android.text.format.DateUtils
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import io.github.anisharyal09.anice.R
import io.github.anisharyal09.anice.features.finddevice.FindDeviceController
import io.github.anisharyal09.anice.features.finddevice.findDeviceFeedbackText
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
    findDevice: FindDeviceController,
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
                findDevice = findDevice,
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
            DeckSurfaceCard {
                Text("Loading trusted devices…", Modifier.padding(16.dp), style = MaterialTheme.typography.bodyMedium)
            }
        } else if (peers.isEmpty()) {
            DeckSurfaceCard {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("Pair a Mac to use Desk Deck.", style = MaterialTheme.typography.bodyMedium)
                    FilledTonalButton(
                        onClick = onPairMac,
                        shape = MaterialTheme.shapes.small,
                        modifier = Modifier.heightIn(min = 48.dp),
                    ) { Text("Pair a Mac") }
                }
            }
        } else {
            if (peers.size > 1) {
                FlowRow(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    peers.forEach { record ->
                        FilterChip(
                            selected = record.peer.deviceId == selectedID,
                            onClick = { selectedID = record.peer.deviceId },
                            label = { Text(record.peer.displayName) },
                            modifier = Modifier.heightIn(min = 48.dp),
                        )
                    }
                }
            }
            DeskDeckGrid(
                owner = owner,
                findDevice = findDevice,
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
    findDevice: FindDeviceController,
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
    val memoryPercent = if (memoryAvailable) sample.memoryUsed.toFloat() / sample.memoryTotal else 0f
    val memoryTitle = if (sample != null && sample.protocolVersion < 3L) "Memory (legacy)" else "Memory used"

    val microphone: @Composable () -> Unit = {
        val supported = sample?.microphoneSupported == true
        val mute = sample?.microphoneMuted != true
        MacroCard(if (supported) { if (mute) "Mute input" else "Unmute input" } else "Mic mute",
            owner.actionFeedback(2).ifBlank { if (supported) "Mac default input" else "No controllable default input" },
            fresh && !owner.isBusy(2)) {
            if (supported) {
                haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                owner.command(2, if (mute) 1 else 0, sample.microphoneTarget, sample.microphoneRevision)
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
        val columns = if (wide) 4 else if (maxWidth < 280.dp * LocalDensity.current.fontScale) 1 else 2
        LazyVerticalGrid(
            columns = GridCells.Fixed(columns), modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(bottom = 12.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            item(span = { GridItemSpan(maxLineSpan) }) {
                StatusCard(owner, target, sample, connected, phonePower, onConnect) { showDetails = true }
            }
            item(span = { GridItemSpan(maxLineSpan) }) {
                FindMacCard(findDevice, target)
            }
            item {
                MeterCard("CPU", sample?.let { if (it.cpuPercent < 0) "Collecting…" else "${it.cpuPercent}%" } ?: "Waiting…",
                    sample?.cpuPercent?.coerceAtLeast(0)?.toFloat()?.div(100f) ?: 0f, { cpuDetails = true }, "Across all cores")
            }
            item {
                MeterCard(memoryTitle, if (memoryAvailable) "${bytesAsGB(sample.memoryUsed)} GiB" else "Unavailable",
                    memoryPercent, { memoryDetails = true }, if (sample != null && sample.memoryTotal > 0) "of ${bytesAsGB(sample.memoryTotal)} GiB" else "Waiting for Mac")
            }
            if (wide) {
                item { microphone() }
                item { lockControl() }
            }
            item(span = { GridItemSpan(if (wide) 2 else maxLineSpan) }) {
                AudioOutputCard(owner, sample, fresh)
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
    DeckSurfaceCard(
        onClick = onOpen,
        modifier = Modifier.semantics { contentDescription = "$title details" },
    ) {
        Column(Modifier.fillMaxWidth().padding(14.dp), verticalArrangement = Arrangement.spacedBy(5.dp)) {
            Text(title, style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Text(
                value,
                style = MaterialTheme.typography.titleLarge.copy(fontFeatureSettings = "tnum"),
            )
            Text(subtitle, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            LinearProgressIndicator(
                progress = { progress.coerceIn(0f, 1f) },
                modifier = Modifier.fillMaxWidth().padding(top = 4.dp).height(5.dp).clip(CircleShape),
                trackColor = MaterialTheme.colorScheme.surfaceVariant,
                strokeCap = StrokeCap.Round,
            )
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
private fun StatusCard(
    owner: DeskDeckController,
    target: DeviceIdentity?,
    sample: DeskDeckSnapshot?,
    connected: Boolean,
    phonePower: DevicePowerReading,
    onConnect: () -> Unit,
    onShowDetails: () -> Unit,
) {
    val titleText = target?.displayName ?: "Mac"
    val summaryText = connectionSummary(owner, connected, sample)
    val secondaryAction: Pair<String, () -> Unit>? = when {
        !connected && target != null -> "Connect" to onConnect
        owner.connectionState in setOf(DeskDeckConnectionState.STALE, DeskDeckConnectionState.FAILED) -> "Refresh" to owner::refresh
        else -> null
    }
    val dotColor = when {
        connected && owner.connectionState == DeskDeckConnectionState.LIVE -> MaterialTheme.colorScheme.tertiary
        owner.connectionState == DeskDeckConnectionState.FAILED -> MaterialTheme.colorScheme.error
        else -> MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.65f)
    }
    DeckSurfaceCard {
        Column(Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 10.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            BoxWithConstraints(Modifier.fillMaxWidth()) {
                val density = LocalDensity.current
                val measurer = rememberTextMeasurer()
                val labelStyle = MaterialTheme.typography.labelLarge
                val detailsWidth = with(density) {
                    maxOf(58.dp, measurer.measure("Details", labelStyle).size.width.toDp() + 20.dp)
                }
                val secondaryWidth = secondaryAction?.let { (label, _) ->
                    with(density) { maxOf(58.dp, measurer.measure(label, labelStyle).size.width.toDp() + 20.dp) }
                } ?: 0.dp
                val actionsWidth = detailsWidth + if (secondaryAction != null) secondaryWidth + 4.dp else 0.dp
                val measuredSummaryWidth = with(density) {
                    maxOf(
                        measurer.measure(titleText, MaterialTheme.typography.titleSmall).size.width.toDp(),
                        measurer.measure(summaryText, MaterialTheme.typography.bodySmall).size.width.toDp() + 12.dp,
                    )
                }
                val minSummaryWidth = minOf(measuredSummaryWidth, 148.dp * density.fontScale.coerceAtLeast(1f))
                val compact = maxWidth < minSummaryWidth + actionsWidth + 8.dp
                val summary: @Composable (Modifier) -> Unit = { summaryModifier ->
                    Column(summaryModifier, verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Text(titleText, style = MaterialTheme.typography.titleSmall)
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(6.dp),
                        ) {
                            Box(Modifier.size(6.dp).background(dotColor, CircleShape))
                            Text(
                                summaryText,
                                style = MaterialTheme.typography.bodySmall.copy(fontFeatureSettings = "tnum"),
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    }
                }
                val actionButtons: @Composable () -> Unit = {
                    secondaryAction?.let { (label, action) ->
                        TextButton(
                            onClick = action,
                            contentPadding = PaddingValues(horizontal = 10.dp, vertical = 6.dp),
                            modifier = Modifier.heightIn(min = 48.dp),
                        ) { Text(label, maxLines = 1, softWrap = false) }
                    }
                    TextButton(
                        onClick = onShowDetails,
                        contentPadding = PaddingValues(horizontal = 10.dp, vertical = 6.dp),
                        modifier = Modifier.heightIn(min = 48.dp),
                    ) { Text("Details", maxLines = 1, softWrap = false) }
                }
                if (compact) {
                    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        summary(Modifier.fillMaxWidth())
                        FlowRow(
                            Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.spacedBy(4.dp, Alignment.End),
                            verticalArrangement = Arrangement.spacedBy(4.dp),
                        ) { actionButtons() }
                    }
                } else {
                    Row(
                        Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        summary(Modifier.weight(1f))
                        Row(
                            horizontalArrangement = Arrangement.spacedBy(4.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) { actionButtons() }
                    }
                }
            }
            HorizontalDivider(thickness = 0.5.dp, color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.55f))
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                PowerSummary("Mac", macPowerSummary(sample), Modifier.weight(1f))
                PowerSummary("Phone", phonePowerSummary(phonePower), Modifier.weight(1f))
            }
        }
    }
}

@Composable
private fun AudioOutputCard(
    owner: DeskDeckController,
    sample: DeskDeckSnapshot?,
    fresh: Boolean,
) {
    val haptic = LocalHapticFeedback.current
    var volumeDrag by remember(sample?.outputTarget, sample?.outputRevision) { mutableStateOf<Float?>(null) }
    var outputMenuExpanded by remember(sample?.protocolVersion) { mutableStateOf(false) }
    val routeSample = sample?.takeIf { it.protocolVersion >= 5L }
    val routeSwitchAvailable = routeSample != null && (routeSample.actions and 32L != 0L)
    LaunchedEffect(fresh, routeSwitchAvailable, owner.outputRoutes) {
        if (!fresh || !routeSwitchAvailable || owner.outputRoutes.isEmpty()) outputMenuExpanded = false
    }
    val dark = MaterialTheme.colorScheme.background.luminance() < 0.5f
    DeckSurfaceCard {
        Column(Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            if (routeSample != null) {
                val routeBusy = owner.isBusy(10L)
                val hasRoutes = owner.outputCatalogLoaded && owner.outputRoutes.isNotEmpty()
                val canInteractSelector = fresh && routeSwitchAvailable && !routeBusy &&
                    (owner.outputCatalogLoaded || !owner.outputCatalogLoading)
                val selectorLabel = when {
                    !routeSwitchAvailable -> owner.selectedOutputName(routeSample)
                        .takeIf { owner.outputCatalogLoaded && it != "Unavailable" }
                        ?: "Output switching unavailable"
                    routeBusy -> "Switching output…"
                    hasRoutes -> owner.selectedOutputName(routeSample)
                    owner.outputCatalogLoaded -> "No available Mac outputs"
                    owner.outputCatalogLoading -> "Loading Mac outputs…"
                    else -> "Load Mac output devices"
                }
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Row(
                        Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        Text("Output device", style = MaterialTheme.typography.titleSmall, modifier = Modifier.weight(1f))
                        TextButton(
                            onClick = owner::refreshOutputRoutes,
                            enabled = fresh && routeSwitchAvailable && !routeBusy,
                            contentPadding = PaddingValues(horizontal = 10.dp, vertical = 6.dp),
                            modifier = Modifier.heightIn(min = 48.dp)
                                .semantics { contentDescription = "Refresh output devices" },
                        ) {
                            Text(
                                if (owner.outputCatalogLoading) "Refreshing…" else "Refresh",
                                maxLines = 1,
                                softWrap = false,
                            )
                        }
                    }
                    Box(Modifier.fillMaxWidth()) {
                        val selectorShape = RoundedCornerShape(10.dp)
                        val selectorFill = MaterialTheme.colorScheme.surfaceVariant.copy(
                            alpha = if (dark) (if (canInteractSelector) 0.58f else 0.34f)
                            else (if (canInteractSelector) 0.48f else 0.30f),
                        )
                        val selectorBorder = if (outputMenuExpanded) {
                            BorderStroke(1.dp, MaterialTheme.colorScheme.primary.copy(alpha = 0.75f))
                        } else {
                            BorderStroke(
                                0.75.dp,
                                Brush.verticalGradient(
                                    listOf(
                                        Color.White.copy(alpha = if (dark) 0.11f else 0.85f),
                                        MaterialTheme.colorScheme.outlineVariant.copy(alpha = if (dark) 0.22f else 0.40f),
                                    ),
                                ),
                            )
                        }
                        Surface(
                            shape = selectorShape,
                            color = selectorFill,
                            border = selectorBorder,
                            modifier = Modifier
                                .fillMaxWidth()
                                .heightIn(min = 48.dp)
                                .clip(selectorShape)
                                .clickable(
                                    enabled = canInteractSelector,
                                    role = Role.DropdownList,
                                    onClickLabel = if (hasRoutes) "Choose output device" else "Load output devices",
                                ) {
                                    if (hasRoutes) outputMenuExpanded = true else owner.refreshOutputRoutes()
                                },
                        ) {
                            Row(
                                Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 10.dp),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(8.dp),
                            ) {
                                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                                    Text(
                                        selectorLabel,
                                        style = MaterialTheme.typography.bodyMedium,
                                        fontWeight = if (hasRoutes && canInteractSelector) FontWeight.Medium else FontWeight.Normal,
                                        color = if (canInteractSelector) MaterialTheme.colorScheme.onSurface
                                            else MaterialTheme.colorScheme.onSurfaceVariant,
                                        maxLines = 2,
                                        overflow = TextOverflow.Ellipsis,
                                    )
                                    if (hasRoutes) {
                                        Text(
                                            if (owner.outputRoutes.size == 1) "1 Mac output available"
                                            else "${owner.outputRoutes.size} Mac outputs · tap to switch",
                                            style = MaterialTheme.typography.bodySmall,
                                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                                        )
                                    }
                                }
                                Icon(
                                    painter = painterResource(R.drawable.ic_chevron_forward),
                                    contentDescription = null,
                                    modifier = Modifier.size(16.dp)
                                        .graphicsLayer(rotationZ = if (outputMenuExpanded) -90f else 90f),
                                    tint = if (canInteractSelector) MaterialTheme.colorScheme.onSurfaceVariant
                                        else MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.5f),
                                )
                            }
                        }
                        DropdownMenu(
                            expanded = outputMenuExpanded && hasRoutes,
                            onDismissRequest = { outputMenuExpanded = false },
                        ) {
                            owner.outputRoutes.forEach { route ->
                                val isCurrent = route.id == routeSample.outputRouteID
                                DropdownMenuItem(
                                    text = {
                                        Text(
                                            route.name,
                                            fontWeight = if (isCurrent) FontWeight.SemiBold else FontWeight.Normal,
                                        )
                                    },
                                    trailingIcon = if (isCurrent) {
                                        {
                                            Icon(
                                                painter = painterResource(R.drawable.ic_check),
                                                contentDescription = "Current output",
                                                modifier = Modifier.size(18.dp),
                                                tint = MaterialTheme.colorScheme.primary,
                                            )
                                        }
                                    } else null,
                                    onClick = {
                                        outputMenuExpanded = false
                                        if (!isCurrent) {
                                            haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                                            owner.selectOutputRoute(route.id)
                                        }
                                    },
                                    enabled = fresh && !routeBusy,
                                )
                            }
                        }
                    }
                    if (owner.outputCatalogLoaded && owner.outputRoutes.isEmpty()) {
                        Text(
                            "No available Mac output devices.",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    } else if (!routeSwitchAvailable) {
                        Text(
                            "Output switching is unavailable on this Mac.",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    if (owner.actionFeedback(10L).isNotBlank()) {
                        Text(
                            owner.actionFeedback(10L),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
                HorizontalDivider(thickness = 0.5.dp, color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.55f))
            } else if (sample != null) {
                Text(
                    "Update aniCe on Mac to choose its output device.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                HorizontalDivider(thickness = 0.5.dp, color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.55f))
            }
            val shownLevel = volumeDrag?.toInt() ?: owner.outputPreview?.toInt() ?: sample?.outputLevel
            val volumeSample = sample?.takeIf { it.outputSupported }
            val volumeSupported = volumeSample != null
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Row(
                    Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Text("Output volume", style = MaterialTheme.typography.titleSmall, modifier = Modifier.weight(1f))
                    Text(
                        if (volumeSupported && shownLevel != null) "$shownLevel%" else "Unavailable",
                        style = MaterialTheme.typography.titleSmall.copy(fontFeatureSettings = "tnum"),
                        color = if (volumeSupported && fresh) MaterialTheme.colorScheme.primary
                            else MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1,
                        softWrap = false,
                    )
                }
                if (volumeSample != null) {
                    Slider(
                        value = volumeDrag ?: owner.outputPreview?.toFloat() ?: volumeSample.outputLevel.toFloat(),
                        onValueChange = { volumeDrag = it },
                        valueRange = 0f..100f,
                        onValueChangeFinished = {
                            val value = volumeDrag?.toLong()
                            volumeDrag = null
                            if (value != null) owner.command(6, value, volumeSample.outputTarget, volumeSample.outputRevision)
                        },
                        enabled = fresh,
                        modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)
                            .semantics { contentDescription = "Mac output volume" },
                    )
                }
                if (owner.actionFeedback(6L).isNotBlank()) {
                    Text(
                        owner.actionFeedback(6L),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }
    }
}

@Composable
private fun FindMacCard(owner: FindDeviceController, target: DeviceIdentity?) {
    val feedback = target?.let(owner::feedbackFor)
    val detail = when {
        target == null -> stringResource(R.string.find_mac_choose)
        owner.isFinding(target) -> findDeviceFeedbackText("find_waiting")
        !owner.connected(target) -> if (feedback in setOf("find_disconnected", "find_timeout", "find_failed")) {
            findDeviceFeedbackText(feedback!!)
        } else stringResource(R.string.find_mac_connect)
        !owner.supports(target) -> stringResource(R.string.find_mac_not_advertised)
        owner.busy -> stringResource(R.string.find_mac_other_pending)
        feedback != null -> findDeviceFeedbackText(feedback)
        else -> stringResource(R.string.find_idle)
    }
    val title = stringResource(R.string.find_mac_title)
    val pingLabel = stringResource(R.string.find_mac_ping_label)
    val enabled = target?.let(owner::canFind) == true
    val description = listOfNotNull(title, pingLabel, target?.displayName, detail).joinToString(". ")
    // Find Device has no subscription or telemetry-freshness requirement.
    DeckSurfaceCard(
        onClick = { target?.let(owner::find) },
        enabled = enabled,
        modifier = Modifier.heightIn(min = 84.dp)
            .semantics { contentDescription = description },
    ) {
        Column(
            Modifier.fillMaxWidth().padding(14.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Row(
                Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Text(
                    title,
                    style = MaterialTheme.typography.titleSmall,
                    color = if (enabled) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.weight(1f),
                )
                Text(
                    pingLabel,
                    style = MaterialTheme.typography.labelLarge,
                    color = if (enabled) MaterialTheme.colorScheme.primary
                        else MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.72f),
                    maxLines = 1,
                    softWrap = false,
                )
            }
            Text(detail, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@Composable
private fun MacroCard(title: String, detail: String, enabled: Boolean,
    description: String = "$title. $detail", onClick: () -> Unit) {
    DeckSurfaceCard(
        onClick = onClick,
        enabled = enabled,
        modifier = Modifier.heightIn(min = 84.dp)
            .semantics { contentDescription = description },
    ) {
        Column(
            Modifier.fillMaxWidth().padding(14.dp),
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
    DeckSurfaceCard(Modifier.heightIn(min = 88.dp)) {
        Row(Modifier.fillMaxWidth().padding(8.dp), verticalAlignment = Alignment.CenterVertically) {
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
private fun DeckSurfaceCard(
    modifier: Modifier = Modifier,
    onClick: (() -> Unit)? = null,
    enabled: Boolean = true,
    content: @Composable ColumnScope.() -> Unit,
) {
    val dark = MaterialTheme.colorScheme.background.luminance() < 0.5f
    val shape = RoundedCornerShape(12.dp)
    val baseColor = if (enabled) MaterialTheme.colorScheme.surfaceContainer
    else MaterialTheme.colorScheme.surfaceContainer.copy(alpha = if (dark) 0.72f else 0.78f)
    val sheenTop = if (dark) Color.White.copy(alpha = if (enabled) 0.03f else 0.012f)
    else Color.White.copy(alpha = if (enabled) 0.38f else 0.18f)
    val edgeTop = if (dark) Color.White.copy(alpha = if (enabled) 0.10f else 0.05f)
    else Color.White.copy(alpha = if (enabled) 0.80f else 0.42f)
    val edgeBottom = MaterialTheme.colorScheme.outlineVariant.copy(alpha = if (dark) 0.28f else 0.48f)
    val border = BorderStroke(0.85.dp, Brush.verticalGradient(listOf(edgeTop, edgeBottom)))
    val elevation = if (!dark && enabled) 1.dp else 0.dp
    val body: @Composable () -> Unit = {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .background(Brush.verticalGradient(0f to sheenTop, 0.38f to Color.Transparent)),
            content = content,
        )
    }
    if (onClick != null) {
        Surface(
            onClick = onClick,
            enabled = enabled,
            modifier = modifier.fillMaxWidth(),
            shape = shape,
            color = baseColor,
            contentColor = MaterialTheme.colorScheme.onSurface,
            shadowElevation = elevation,
            border = border,
            content = body,
        )
    } else {
        Surface(
            modifier = modifier.fillMaxWidth(),
            shape = shape,
            color = baseColor,
            contentColor = MaterialTheme.colorScheme.onSurface,
            shadowElevation = elevation,
            border = border,
            content = body,
        )
    }
}

@Composable
private fun PowerSummary(title: String, value: String, modifier: Modifier = Modifier) {
    Column(modifier, verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text(title, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(
            value,
            style = MaterialTheme.typography.bodySmall.copy(fontFeatureSettings = "tnum"),
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
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
