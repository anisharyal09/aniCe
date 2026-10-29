// SPDX-License-Identifier: GPL-3.0-or-later
// Presents device-scoped actions and explicit transport details using the existing session owners.
package io.github.anisharyal09.anice.features.session

import io.github.anisharyal09.anice.ui.AutomaticConnectionToggle
import io.github.anisharyal09.anice.R
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import io.github.anisharyal09.anice.features.backgroundprobe.hasConnectionSetup
import androidx.compose.ui.res.painterResource
import android.content.Intent
import android.content.pm.ApplicationInfo
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.sp
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import io.github.anisharyal09.anice.infrastructure.connections.CompanionProbe
import io.github.anisharyal09.anice.infrastructure.pairing.PeerTrustRecord

@Composable
fun SessionPanel(model: SessionViewModel, peers: List<PeerTrustRecord>, onDiscoveryCheck: () -> Unit, compact: Boolean = false, overview: Boolean = false, flatDeviceLayout: Boolean = false, onOpenDevice: (String) -> Unit = {}, focusedPeer: String? = null, onFocusConsumed: () -> Unit = {}) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var automaticChanging by remember { mutableStateOf(false) }
    var automaticNotice by remember { mutableStateOf<Pair<String, String>?>(null) }
    val nearby = CompanionProbe.get(context)
    val permissions = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        model.permissionReturned()
    }
    val lan = model.lan
    var details by rememberSaveable { mutableStateOf<String?>(null) }
    var diagnostics by rememberSaveable { mutableStateOf(false) }
    var showEvents by rememberSaveable { mutableStateOf(false) }
    val active = model.state in listOf(ConnectionState.CONNECTING, ConnectionState.SECURED) ||
        lan.state in listOf(ConnectionState.CONNECTING, ConnectionState.SECURED)
    fun connect(record: PeerTrustRecord) {
        model.request(record.peer)
        val missing = model.missingPermissions()
        if (missing.isNotEmpty()) permissions.launch(missing)
    }
    // A revoked entry must not remain actionable through expanded details.
    val detailRecord = peers.singleOrNull { it.peer.deviceId + ":" + it.peer.fingerprint == details }
    BackHandler(enabled = !compact && details != null) { details = null }
    LaunchedEffect(focusedPeer) {
        if (focusedPeer != null) {
            details = peers.singleOrNull { it.peer.deviceId == focusedPeer }?.peer?.let { it.deviceId + ":" + it.fingerprint }
            onFocusConsumed()
        }
    }
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(if (flatDeviceLayout) 0.dp else 12.dp)) {
        val primary = primaryPeers(peers) { record ->
            (model.state == ConnectionState.SECURED && model.selected?.deviceId == record.peer.deviceId && model.selected?.fingerprint == record.peer.fingerprint) ||
                (lan.state == ConnectionState.SECURED && lan.selected?.deviceId == record.peer.deviceId && lan.selected?.fingerprint == record.peer.fingerprint)
        }
        val visiblePeers = if (overview) primary.take(1) else primary
        visiblePeers.forEachIndexed { index, record ->
            key(record.peer.deviceId, record.peer.fingerprint) {
                val bleSelected = model.selected?.deviceId == record.peer.deviceId &&
                    model.selected?.fingerprint == record.peer.fingerprint
                val lanSelected = lan.selected?.deviceId == record.peer.deviceId &&
                    lan.selected?.fingerprint == record.peer.fingerprint
                val bleState = if (bleSelected) model.state else ConnectionState.DISCONNECTED
                val lanState = if (lanSelected) lan.state else ConnectionState.DISCONNECTED
                val canUsePeer = canConnectToPeer(model.state, lan.state, bleSelected, lanSelected)
                val waiting = nearby.armed && nearby.peerId == record.peer.deviceId &&
                    nearby.fingerprint == record.peer.fingerprint && canUsePeer
                val summary = connectionSummary(bleState, lanState, waiting)
                val feedback = buildList {
                    if (bleSelected && bleState != ConnectionState.SECURED && model.status.isNotBlank())
                        add("Bluetooth: ${model.status}")
                    if (lanSelected && lanState != ConnectionState.SECURED && lan.status.isNotBlank())
                        add("Local network: ${lan.status}")
                    automaticNotice?.takeIf { it.first == record.peer.deviceId }?.let { add(it.second) }
                    if (waiting && !bleSelected && nearby.status != "Waiting nearby.") add(nearby.status)
                    if (!canUsePeer) add("Disconnect your current Mac to connect to this one.")
                    if (!active && !waiting && isEmpty()) add("Tap Connect on both devices.")
                }.joinToString("\n")
                Column(Modifier.fillMaxWidth().padding(vertical = if (compact || flatDeviceLayout) 0.dp else 8.dp), verticalArrangement = Arrangement.spacedBy(if (compact) 12.dp else if (flatDeviceLayout) 4.dp else 8.dp)) {
                DeviceSessionCard(record.peer.deviceName, summary.state,
                    if (compact) "" else feedback, canUsePeer, { connect(record) }, model::disconnect,
                    onConnectionDetails = { if (compact) onOpenDevice(record.peer.deviceId) else { diagnostics = false; showEvents = false; details = if (details == record.peer.deviceId + ":" + record.peer.fingerprint) null else record.peer.deviceId + ":" + record.peer.fingerprint } },
                    summary = summary.text, action = summary.action,
                    detailsExpanded = detailRecord?.peer?.deviceId == record.peer.deviceId, compact = compact, showDetailsAction = false, showConnectionAction = true)
                if (!compact) {
                val groupOutline = MaterialTheme.colorScheme.outlineVariant
                Column(Modifier.fillMaxWidth()
                    .drawWithContent {
                        drawContent()
                        if (flatDeviceLayout) {
                            val radius = 9.dp.toPx()
                            // Extend only the curved ends beyond the shared label gutter, as on Mac.
                            val edge = 8.dp.toPx()
                            val origin = androidx.compose.ui.geometry.Offset(-edge, 0f)
                            val bounds = androidx.compose.ui.geometry.Size(size.width + edge * 2, size.height)
                            clipRect(left = -edge, right = size.width + edge, bottom = radius) {
                                drawRoundRect(groupOutline, topLeft = origin, size = bounds, cornerRadius = CornerRadius(radius), style = Stroke(1.5.dp.toPx()))
                            }
                            clipRect(left = -edge, right = size.width + edge, top = size.height - radius) {
                                drawRoundRect(groupOutline, topLeft = origin, size = bounds, cornerRadius = CornerRadius(radius), style = Stroke(1.5.dp.toPx()))
                            }
                        }
                    }
                    .then(if (flatDeviceLayout) Modifier else Modifier.border(1.dp, MaterialTheme.colorScheme.outlineVariant, MaterialTheme.shapes.small))
                    .padding(horizontal = if (flatDeviceLayout) 0.dp else 12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                if (!compact && nearby.available) {
                    val enabled = nearby.armed && nearby.peerId == record.peer.deviceId &&
                        nearby.fingerprint == record.peer.fingerprint
                    AutomaticConnectionToggle(checked = enabled, enabled = canUsePeer && !automaticChanging,
                        label = "Auto connect", description = "Reconnect when this device is available.", compact = flatDeviceLayout,
                        onCheckedChange = { checked ->
                            automaticNotice = null
                            if (!checked) {
                                if (hasConnectionSetup(record.peer, nearby.peerId, nearby.fingerprint)) nearby.disable()
                            } else if (hasConnectionSetup(record.peer, nearby.peerId, nearby.fingerprint) && nearby.address != null && model.missingPermissions().isEmpty()) {
                                automaticChanging = true
                                scope.launch {
                                    try { nearby.resume() }
                                    catch (error: CancellationException) { throw error }
                                    catch (_: Exception) {
                                        automaticNotice = record.peer.deviceId to "Check automatic setup in Diagnostics → Setup settings."
                                    } finally { automaticChanging = false }
                                }
                            } else context.startActivity(Intent().setClassName(context.packageName,
                                "${context.packageName}.features.backgroundprobe.CompanionProbeActivity")
                                .putExtra("peer", record.peer.deviceId).putExtra("enable", true))
                        })
                }
                if (!compact) {
                    HorizontalDivider()
                    TransportDetails("Bluetooth", bleState, if (bleSelected) model.status else "",
                        canConnect = canUsePeer,
                        onConnect = { connect(record) }, onDisconnect = model::disconnectBluetooth)
                    if (flatDeviceLayout) HorizontalDivider()
                    TransportDetails("Local network", lanState, if (lanSelected) lan.status else "",
                        canConnect = canUsePeer,
                        onConnect = { lan.connect(record.peer) }, onDisconnect = lan::disconnect)
                    if (flatDeviceLayout) HorizontalDivider()
                }
                if (!compact) {
                    val detailsExpanded = detailRecord?.peer?.deviceId == record.peer.deviceId
                    TextButton(onClick = { diagnostics = false; showEvents = false; details = if (detailsExpanded) null else record.peer.deviceId + ":" + record.peer.fingerprint },
                        contentPadding = PaddingValues(horizontal = 0.dp, vertical = 4.dp),
                        modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp).semantics { stateDescription = if (detailsExpanded) "Expanded" else "Collapsed" }) {
                        Text("▶", style = MaterialTheme.typography.bodyMedium.copy(fontSize = 14.sp, fontWeight = FontWeight.Bold),
                            modifier = Modifier.clearAndSetSemantics { }
                                .graphicsLayer(rotationZ = when {
                                detailsExpanded -> 90f
                                LocalLayoutDirection.current == LayoutDirection.Rtl -> 180f
                                else -> 0f
                            }))
                        Spacer(Modifier.width(8.dp))
                        Text("Security and diagnostics", Modifier.weight(1f))
                    }
                }
                if (!compact && detailRecord?.peer?.deviceId == record.peer.deviceId) {
                    Column(Modifier.fillMaxWidth()
                        .then(if (flatDeviceLayout) Modifier.padding(vertical = 8.dp) else Modifier.background(MaterialTheme.colorScheme.surface, MaterialTheme.shapes.medium).padding(16.dp)),
                        verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        if (!flatDeviceLayout) {
                            Row(Modifier.fillMaxWidth(), verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
                                Text("Connection details", Modifier.weight(1f), style = MaterialTheme.typography.titleSmall)
                                IconButton(onClick = { details = null }) {
                                    Icon(painterResource(R.drawable.ic_close), contentDescription = "Close connection details",
                                        tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(18.dp))
                                }
                            }
                        }
                        androidx.compose.foundation.text.selection.SelectionContainer {
                            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                                Text("Security fingerprint", style = MaterialTheme.typography.labelMedium)
                                Text(record.peer.fingerprint, style = MaterialTheme.typography.bodySmall)
                            }
                        }
                        if (!flatDeviceLayout && (summary.state == ConnectionState.SECURED || summary.state == ConnectionState.CONNECTING)) {
                            TextButton(onClick = model::disconnect) { Text("Disconnect device") }
                        }
                        HorizontalDivider()
                        TextButton(shape = MaterialTheme.shapes.small, contentPadding = PaddingValues(horizontal = 10.dp, vertical = 4.dp), onClick = { diagnostics = !diagnostics; showEvents = false }, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)
                            .semantics { stateDescription = if (diagnostics) "Expanded" else "Collapsed" }) {
                            Text(if (diagnostics) "Hide diagnostics" else "Diagnostics", modifier = Modifier.fillMaxWidth())
                        }
                        if (diagnostics) {
                            Text("Local network ends on background or screen lock.", style = MaterialTheme.typography.bodySmall)
                            if (nearby.available) {
                                TextButton(shape = MaterialTheme.shapes.small, contentPadding = PaddingValues(horizontal = 10.dp, vertical = 4.dp), onClick = {
                                    context.startActivity(Intent().setClassName(context.packageName,
                                        "${context.packageName}.features.backgroundprobe.CompanionProbeActivity")
                                        .putExtra("peer", record.peer.deviceId))
                                }) { Text("Setup settings") }
                            } else {
                                Text("Automatic Bluetooth connection is unavailable in this build.",
                                    style = MaterialTheme.typography.bodySmall)
                            }
                            if (hasConnectionSetup(record.peer, nearby.peerId, nearby.fingerprint) &&
                                context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0) {
                                TextButton(shape = MaterialTheme.shapes.small,
                                    contentPadding = PaddingValues(horizontal = 10.dp, vertical = 4.dp),
                                    onClick = { showEvents = !showEvents },
                                    modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp).semantics {
                                        stateDescription = if (showEvents) "Expanded" else "Collapsed"
                                    }) {
                                    Text(if (showEvents) "Hide automatic connection events" else "Automatic connection events",
                                        modifier = Modifier.fillMaxWidth())
                                }
                                if (showEvents) Text(nearby.events.ifBlank { "No events yet." }, style = MaterialTheme.typography.bodySmall)
                            }
                            Text("Bluetooth checks received: ${if (bleSelected) model.receivedChecks else 0}")
                            if (bleState == ConnectionState.SECURED)
                                TextButton(shape = MaterialTheme.shapes.small, contentPadding = PaddingValues(horizontal = 10.dp, vertical = 4.dp), onClick = model::checkConnection, modifier = Modifier.heightIn(min = 48.dp)) {
                                    Text("Send Bluetooth check")
                                }
                            Text("Local-network checks received: ${if (lanSelected) lan.receivedChecks else 0}")
                            if (lanState == ConnectionState.SECURED)
                                TextButton(shape = MaterialTheme.shapes.small, contentPadding = PaddingValues(horizontal = 10.dp, vertical = 4.dp), onClick = lan::checkConnection, modifier = Modifier.heightIn(min = 48.dp)) {
                                    Text("Send local-network check")
                                }
                            Text("Starting a scan closes Bluetooth connections. Opening the page keeps both connections. Local network stays connected during scanning.",
                                style = MaterialTheme.typography.bodySmall)
                            TextButton(shape = MaterialTheme.shapes.small, contentPadding = PaddingValues(horizontal = 10.dp, vertical = 4.dp), onClick = { details = null; onDiscoveryCheck() },
                                modifier = Modifier.heightIn(min = 48.dp)) { Text("Check nearby discovery") }
                        }
                    }
                }
                }
                }
                }
            }
            if (index < visiblePeers.lastIndex) HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
        }
    }
}

@Composable
private fun TransportDetails(name: String, state: ConnectionState, status: String, canConnect: Boolean,
    onConnect: () -> Unit, onDisconnect: () -> Unit) {
    Row(Modifier.fillMaxWidth().padding(vertical = 4.dp), verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
        Icon(painterResource(if (name == "Bluetooth") R.drawable.ic_bluetooth else R.drawable.ic_wifi), contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(end = 12.dp).size(24.dp))
        Text(name, Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
        Text(stateLabel(state), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(end = 10.dp))
        val active = state == ConnectionState.CONNECTING || state == ConnectionState.SECURED
        OutlinedButton(shape = MaterialTheme.shapes.small,
            colors = ButtonDefaults.outlinedButtonColors(containerColor = MaterialTheme.colorScheme.surfaceVariant),
            contentPadding = PaddingValues(horizontal = 10.dp, vertical = 2.dp), onClick = if (active) onDisconnect else onConnect,
            enabled = active || canConnect, modifier = Modifier.defaultMinSize(minHeight = 32.dp)
                .semantics { contentDescription = "${when (state) {
                    ConnectionState.CONNECTING -> "Cancel"
                    ConnectionState.SECURED -> "Disconnect"
                    ConnectionState.FAILED -> "Retry"
                    else -> "Connect"
                }} $name" }) {
            Text(when (state) {
                ConnectionState.CONNECTING -> "Cancel"
                ConnectionState.SECURED -> "Disconnect"
                ConnectionState.FAILED -> "Retry"
                else -> "Connect"
            })
        }
    }
    if (status.isNotBlank() && (state != ConnectionState.SECURED || !status.startsWith("Secured")))
        Text(status, style = MaterialTheme.typography.bodySmall,
            modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite })

}

@Composable
fun DeviceSessionCard(name: String, state: ConnectionState, status: String,
    canConnect: Boolean, onConnect: () -> Unit, onDisconnect: () -> Unit,
    onConnectionDetails: () -> Unit,
    summary: String = stateLabel(state),
    action: String = connectionSummary(state, ConnectionState.DISCONNECTED).action,
    detailsExpanded: Boolean = false, compact: Boolean = false, showDetailsAction: Boolean = true, showConnectionAction: Boolean = true) {
    val statusColor = when (state) {
        ConnectionState.SECURED -> MaterialTheme.colorScheme.onSurfaceVariant
        ConnectionState.FAILED -> MaterialTheme.colorScheme.error
        else -> MaterialTheme.colorScheme.onSurfaceVariant
    }
    if (compact) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = androidx.compose.ui.Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Icon(painterResource(R.drawable.ic_laptop), contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(24.dp))
            Column(Modifier.weight(1f).clickable(role = androidx.compose.ui.semantics.Role.Button, onClickLabel = "Open devices for $name", onClick = onConnectionDetails)
                .heightIn(min = 48.dp), verticalArrangement = Arrangement.Center) {
                Row(verticalAlignment = androidx.compose.ui.Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(name, maxLines = 1, overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis,
                        style = MaterialTheme.typography.titleSmall, modifier = Modifier.weight(1f))
                    Icon(painterResource(R.drawable.ic_chevron_forward), contentDescription = null,
                        tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(16.dp))
                }
                Text(if (state == ConnectionState.SECURED) "Connected" else summary,
                    style = MaterialTheme.typography.bodySmall, color = statusColor)
            }
            OutlinedButton(onClick = if (action == "Disconnect" || action == "Cancel") onDisconnect else onConnect,
                enabled = action == "Disconnect" || action == "Cancel" || canConnect,
                shape = MaterialTheme.shapes.small, contentPadding = PaddingValues(horizontal = 10.dp, vertical = 2.dp),
                modifier = Modifier.defaultMinSize(minHeight = 32.dp)) { Text(action) }
        }
        return
    }
    Column(Modifier.fillMaxWidth().padding(vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = androidx.compose.ui.Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Icon(painterResource(R.drawable.ic_laptop), contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(24.dp))
            Column(Modifier.weight(1f).clickable(role = androidx.compose.ui.semantics.Role.Button,
                onClickLabel = "Device details for $name", onClick = onConnectionDetails).heightIn(min = 48.dp), verticalArrangement = Arrangement.spacedBy(4.dp, androidx.compose.ui.Alignment.CenterVertically)) {
                Text(name, Modifier.semantics { heading() }, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Medium)
                Text(if (state == ConnectionState.SECURED) "Connected" else summary,
                    style = MaterialTheme.typography.bodySmall, color = statusColor)
            }
            if (showConnectionAction) OutlinedButton(shape = MaterialTheme.shapes.small,
                colors = ButtonDefaults.outlinedButtonColors(containerColor = MaterialTheme.colorScheme.surfaceVariant), contentPadding = PaddingValues(horizontal = 14.dp, vertical = 2.dp),
                onClick = if (action == "Disconnect" || action == "Cancel") onDisconnect else onConnect,
                enabled = action == "Disconnect" || action == "Cancel" || canConnect,
                modifier = Modifier.defaultMinSize(minHeight = 32.dp)) { Text(action) }
        }
        if (status.isNotBlank()) Text(status,
            modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        if (state == ConnectionState.CONNECTING) LinearProgressIndicator(Modifier.fillMaxWidth())
        val expandedAngle = if (LocalLayoutDirection.current == LayoutDirection.Ltr) -90f else 90f
        if (showDetailsAction) TextButton(onClick = onConnectionDetails, shape = MaterialTheme.shapes.small,
            contentPadding = PaddingValues(horizontal = 10.dp, vertical = 4.dp),
            modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)
                .semantics { stateDescription = if (detailsExpanded) "Expanded" else "Collapsed" }) {
            Text("Connection details", Modifier.weight(1f))
            Icon(painterResource(R.drawable.ic_back), contentDescription = null,
                modifier = Modifier.size(18.dp).graphicsLayer(rotationZ = if (detailsExpanded) expandedAngle else 180f))
        }
    }
}

private fun stateLabel(state: ConnectionState): String = when (state) {
    ConnectionState.DISCONNECTED -> "Disconnected"
    ConnectionState.CONNECTING -> "Connecting"
    ConnectionState.SECURED -> "Connected"
    ConnectionState.FAILED -> "Connection failed"
}
