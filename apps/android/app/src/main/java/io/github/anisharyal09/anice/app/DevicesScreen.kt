// SPDX-License-Identifier: GPL-3.0-or-later
// Presents device routes through existing pairing, discovery and connection owners.
package io.github.anisharyal09.anice.app

import androidx.compose.material3.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.clickable
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import io.github.anisharyal09.anice.features.transfer.TransferState
import io.github.anisharyal09.anice.features.transfer.TransferView
import io.github.anisharyal09.anice.features.transfer.rememberSendFilesAction
import io.github.anisharyal09.anice.features.clipboard.ClipboardSendButton
import androidx.compose.ui.res.painterResource
import io.github.anisharyal09.anice.R
import androidx.compose.foundation.layout.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.Alignment
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import io.github.anisharyal09.anice.features.discovery.*
import io.github.anisharyal09.anice.features.pairing.*
import io.github.anisharyal09.anice.features.session.*
import io.github.anisharyal09.anice.features.deviceidentity.DeviceIdentityScreen
import io.github.anisharyal09.anice.features.deviceidentity.DeviceIdentityViewModel
import io.github.anisharyal09.anice.infrastructure.connections.CompanionProbe

@Composable
@OptIn(ExperimentalMaterial3Api::class)
internal fun DevicesScreen(pairing: PairingViewModel, discovery: DiscoveryViewModel, session: SessionViewModel, navigation: AppNavigation, nearbyOwner: CompanionProbe, automaticAfterPairing: Boolean, onAutomatic: (Boolean)->Unit, automaticLanAfterPairing: Boolean, onAutomaticLan: (Boolean)->Unit, identity: DeviceIdentityViewModel) {
    when (navigation.route) {
        DeviceRoute.Pairing -> {
            DevicesOverviewContent(pairing, session, navigation, identity)
            ModalBottomSheet(
                onDismissRequest = navigation::back,
                sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
                dragHandle = null,
            ) {
                PairingScreen(
                    pairing,
                    nearbyOwner.available,
                    automaticAfterPairing,
                    onAutomatic,
                    automaticLanAfterPairing,
                    onAutomaticLan,
                    onDismiss = navigation::back,
                )
            }
        }
        DeviceRoute.Discovery -> DiscoveryScreen(discovery)
        DeviceRoute.Overview -> {
            if (navigation.destination == AppDestination.Home) {
                val transfer = session.transfer
                val incoming = transfer.state is TransferState.IncomingOffer
                val isResult = when (transfer.state) {
                    is TransferState.Completed, is TransferState.Rejected, is TransferState.Failed, is TransferState.Cancelled -> true
                    else -> false
                }
                val sendFiles = rememberSendFilesAction(transfer)
                HomeScreen(pairing.peers.isNotEmpty(), onPair = navigation::pair,
                    showRecentHeading = isResult || session.clipboard.recent != null || session.sms.threads?.isNotEmpty() == true,
                    attention = {
                        if (incoming) TransferView(transfer, open = { navigation.openFeature(AppFeature.Files) }, overview = true)
                    },
                    quickActions = {
                        if (pairing.peers.isNotEmpty()) {
                            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                OutlinedButton(onClick = sendFiles::chooseFiles,
                                    enabled = transfer.peerConnected && transfer.peerCompatible && !transfer.preparing && transfer.state is TransferState.Idle,
                                    shape = MaterialTheme.shapes.small,
                                    contentPadding = PaddingValues(horizontal = 8.dp, vertical = 2.dp),
                                    modifier = Modifier.heightIn(min = 48.dp)) {
                                    Icon(painterResource(R.drawable.ic_file_send), contentDescription = null, modifier = Modifier.size(16.dp))
                                    Spacer(Modifier.width(6.dp))
                                    Text("Send files")
                                }
                                ClipboardSendButton(session.clipboard, Modifier.heightIn(min = 48.dp), compact = true)
                            }
                            if (session.clipboard.status != "Ready to share text" && session.clipboard.status != "Confirm sending sensitive text") {
                                Text(session.clipboard.status, style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                        }
                    },
                    activities = {
                        if (session.media.compactVisible || navigation.mediaDetails) {
                            io.github.anisharyal09.anice.features.nowplaying.MediaView(session.media, compact = true,
                                showPlayerSelector = false, compactVolume = true, overview = true,
                                open = { navigation.openFeature(AppFeature.Playback) })
                            if (navigation.mediaDetails) TextButton(onClick = { navigation.mediaDetails = false }) { Text("Done") }
                        }
                        if (!incoming && !isResult && (transfer.state !is TransferState.Idle || transfer.preparing))
                            TransferView(transfer, open = { navigation.openFeature(AppFeature.Files) }, overview = true)
                    },
                    recentActivity = {
                        if (isResult) {
                            val (title, detail) = when (val state = transfer.state) {
                                is TransferState.Completed -> {
                                    val noun = if (state.fileCount == 1) "file" else "files"
                                    (if (transfer.receiving) "Files received" else "Files sent") to "${state.fileCount} $noun · Just now"
                                }
                                is TransferState.Rejected -> "Transfer declined" to "The other device declined the transfer."
                                is TransferState.Failed -> "Transfer failed" to state.reason
                                is TransferState.Cancelled -> "Transfer cancelled" to "Cancelled before completion."
                                else -> return@HomeScreen
                            }
                            TextButton(onClick = { navigation.openFeature(AppFeature.Files) },
                                modifier = Modifier.fillMaxWidth().heightIn(min = 64.dp),
                                contentPadding = PaddingValues(vertical = 12.dp, horizontal = 0.dp),
                                colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.onSurface)) {
                                Row(Modifier.fillMaxWidth(), verticalAlignment = androidx.compose.ui.Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                                    Icon(painterResource(R.drawable.ic_file_send), contentDescription = null,
                                        tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(22.dp))
                                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                                        Text(title, style = MaterialTheme.typography.bodyMedium)
                                        Text(detail, style = MaterialTheme.typography.bodySmall, maxLines = 1,
                                            overflow = TextOverflow.Ellipsis, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                    }
                                    Icon(painterResource(R.drawable.ic_chevron_forward), contentDescription = null,
                                        tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(18.dp))
                                }
                            }
                            HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
                        }
                        io.github.anisharyal09.anice.features.clipboard.ClipboardActivityView(session.clipboard, compact = true,
                            open = { navigation.openFeature(AppFeature.Clipboard) })
                        session.sms.threads?.maxByOrNull { it.dateMillis }?.let { thread ->
                            TextButton(onClick = { navigation.openFeature(AppFeature.Sms) },
                                modifier = Modifier.fillMaxWidth().heightIn(min = 64.dp),
                                contentPadding = PaddingValues(vertical = 12.dp, horizontal = 0.dp),
                                colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.onSurface)) {
                                Row(Modifier.fillMaxWidth(), verticalAlignment = androidx.compose.ui.Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                                    Icon(painterResource(R.drawable.ic_sms), contentDescription = null,
                                        tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(22.dp))
                                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                                        Text("Messages", style = MaterialTheme.typography.bodyMedium)
                                        val whenText = java.text.DateFormat.getTimeInstance(java.text.DateFormat.SHORT)
                                            .format(java.util.Date(thread.dateMillis))
                                        Text("${thread.address} · $whenText", style = MaterialTheme.typography.bodySmall,
                                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                                    }
                                    Icon(painterResource(R.drawable.ic_chevron_forward), contentDescription = null,
                                        tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(18.dp))
                                }
                            }
                            HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
                        }
                    }, sessions = {
                        SessionPanel(session, pairing.peers, overview = true, compact = true, onOpenDevice = navigation::openDevice,
                            onDiscoveryCheck = { navigation.destination = AppDestination.Devices; navigation.route = DeviceRoute.Discovery },
                            focusedPeer = navigation.focusedPeer, onFocusConsumed = { navigation.focusedPeer = null })
                    })
                sendFiles.ReviewDialog()
            } else DevicesOverviewContent(pairing, session, navigation, identity)
        }
    }
}

@Composable
@OptIn(ExperimentalMaterial3Api::class)
private fun DevicesOverviewContent(
    pairing: PairingViewModel,
    session: SessionViewModel,
    navigation: AppNavigation,
    identity: DeviceIdentityViewModel,
) {
    var showingIdentity by rememberSaveable { mutableStateOf(false) }
    val localName = identity.state.snapshot?.identity?.deviceName
    Column(Modifier.fillMaxSize()) {
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = 20.dp, vertical = 16.dp)) {
            Text("Devices", style = MaterialTheme.typography.titleLarge)
            Spacer(Modifier.height(4.dp))
            Text("Connection and trust.", style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
            Spacer(Modifier.height(12.dp))
            if (pairing.peers.isEmpty()) Text("No devices paired yet", style = MaterialTheme.typography.bodySmall)
            SessionPanel(
                session,
                pairing.peers,
                onDiscoveryCheck = { navigation.route = DeviceRoute.Discovery },
                flatDeviceLayout = true,
                focusedPeer = navigation.focusedPeer,
                onFocusConsumed = { navigation.focusedPeer = null },
            )
            Spacer(Modifier.height(8.dp))
            TrustedDevicesSection(pairing)
            Row(
                Modifier.fillMaxWidth().heightIn(min = 56.dp)
                    .clickable(role = Role.Button, onClickLabel = "Open this device details", onClick = { showingIdentity = true })
                    .padding(vertical = 10.dp),
                verticalAlignment = androidx.compose.ui.Alignment.CenterVertically,
            ) {
                Icon(painterResource(R.drawable.ic_phone), contentDescription = null, modifier = Modifier.size(20.dp))
                Spacer(Modifier.width(10.dp))
                val secondary = MaterialTheme.colorScheme.onSurfaceVariant
                Text(buildAnnotatedString {
                    append("This device")
                    if (localName != null) withStyle(SpanStyle(color = secondary)) { append(" · $localName") }
                }, Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
                Icon(painterResource(R.drawable.ic_chevron_forward), contentDescription = null, modifier = Modifier.size(18.dp))
            }
            HorizontalDivider()
            Row(
                Modifier.fillMaxWidth().heightIn(min = 56.dp)
                    .clickable(role = Role.Button, onClickLabel = "Add device", onClick = navigation::pair)
                    .padding(vertical = 10.dp),
                verticalAlignment = androidx.compose.ui.Alignment.CenterVertically,
            ) {
                Text("+", style = MaterialTheme.typography.titleMedium, modifier = Modifier.width(20.dp))
                Spacer(Modifier.width(10.dp))
                Text("Add device", Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
                Icon(painterResource(R.drawable.ic_chevron_forward), contentDescription = null, modifier = Modifier.size(18.dp))
            }
            HorizontalDivider()
        }
    }
    if (showingIdentity) LocalIdentitySheet(identity) { showingIdentity = false }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun LocalIdentitySheet(identity: DeviceIdentityViewModel, onDismiss: () -> Unit) {
    // Sheet feedback must remain above the modal rather than behind it in the app scaffold.
    val sheetSnackbars = remember { SnackbarHostState() }
    val windowHeight = LocalWindowInfo.current.containerSize.height
    val maxBodyHeight = with(LocalDensity.current) { windowHeight.toDp() * 0.7f }
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
    ) {
        Row(Modifier.fillMaxWidth().padding(start = 24.dp, end = 16.dp),
            verticalAlignment = Alignment.CenterVertically) {
            Text("This phone", Modifier.weight(1f), style = MaterialTheme.typography.titleMedium)
            TextButton(onClick = onDismiss, modifier = Modifier.heightIn(min = 48.dp)) { Text("Done") }
        }
        Box(Modifier.fillMaxWidth().heightIn(max = maxBodyHeight)) {
            DeviceIdentityScreen(identity.state, sheetSnackbars, identity::retry, identity::reset,
                onRename = identity::rename)
            SnackbarHost(sheetSnackbars, Modifier.align(Alignment.BottomCenter))
        }
    }
}
