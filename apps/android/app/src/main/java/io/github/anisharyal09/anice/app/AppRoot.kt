// SPDX-License-Identifier: GPL-3.0-or-later
// Routes existing device, pairing and diagnostic presentations while preserving native lifecycle ownership.
package io.github.anisharyal09.anice.app

import android.content.Intent
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.background
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.relocation.BringIntoViewRequester
import androidx.compose.foundation.relocation.bringIntoViewRequester
import androidx.compose.ui.draw.clip
import androidx.compose.foundation.clickable
import androidx.compose.ui.Alignment
import androidx.compose.ui.graphics.graphicsLayer
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.listSaver
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.launch
import io.github.anisharyal09.anice.R
import io.github.anisharyal09.anice.features.deviceidentity.DeviceIdentityScreen
import io.github.anisharyal09.anice.features.deviceidentity.DeviceIdentityViewModel
import io.github.anisharyal09.anice.features.discovery.DiscoveryScreen
import io.github.anisharyal09.anice.features.discovery.DiscoveryViewModel
import io.github.anisharyal09.anice.features.pairing.PairingScreen
import io.github.anisharyal09.anice.features.pairing.PairingViewModel
import io.github.anisharyal09.anice.features.pairing.completedPairingPeer
import io.github.anisharyal09.anice.features.session.SessionPanel
import io.github.anisharyal09.anice.features.session.SessionViewModel
import io.github.anisharyal09.anice.ui.theme.Appearance
import io.github.anisharyal09.anice.ui.theme.appearancePreference
import io.github.anisharyal09.anice.ui.theme.saveAppearance

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AppRoot(identity: DeviceIdentityViewModel, discovery: DiscoveryViewModel,
    pairing: PairingViewModel, session: SessionViewModel) {
    session.findDevice.incomingAlert?.let { alert ->
        AlertDialog(onDismissRequest = { session.findDevice.dismiss(alert.identifier) },
            title = { Text(androidx.compose.ui.res.stringResource(R.string.find_ringing_title)) },
            text = { Text(androidx.compose.ui.res.stringResource(R.string.find_notification_body, alert.peerName)) },
            confirmButton = {
                Button(onClick = { session.findDevice.dismiss(alert.identifier) }) {
                    Text(androidx.compose.ui.res.stringResource(R.string.find_stop_ringing))
                }
            })
    }
    val context = LocalContext.current
    val fontScale = LocalDensity.current.fontScale
    val largeText = fontScale >= 1.5f
    val navigationScroll = rememberScrollState()
    val navigationScrollScope = rememberCoroutineScope()
    val uiPreferences = remember { context.getSharedPreferences("ui_preferences", android.content.Context.MODE_PRIVATE) }
    val navigation = rememberSaveable(saver = AppNavigation.saver) {
        AppNavigation().also { it.favouriteFeatures = uiPreferences.getString("favourite_features", "").orEmpty() }
    }
    LaunchedEffect(navigation.favouriteFeatures) {
        uiPreferences.edit().putString("favourite_features", navigation.favouriteFeatures).apply()
    }
    LaunchedEffect(session.media.openWorkspaceRequest) {
        if(session.media.openWorkspaceRequest) { navigation.openFeature(AppFeature.Playback);session.media.workspaceOpened() }
    }
    LaunchedEffect(identity.state.snapshot?.identity?.fingerprint) {
        if (identity.state.snapshot != null) pairing.refresh()
    }

    var automaticAfterPairing by rememberSaveable { mutableStateOf(true) }
    var automaticLanAfterPairing by rememberSaveable { mutableStateOf(true) }
    val nearbyOwner = io.github.anisharyal09.anice.infrastructure.connections.CompanionProbe.get(LocalContext.current)
    LaunchedEffect(pairing.busy) {
        if (pairing.busy || discovery.state.busy) nearbyOwner.suspend() else nearbyOwner.resumeAfterOperation()
    }
    LaunchedEffect(pairing.phase, pairing.peers, identity.state.snapshot?.identity?.fingerprint) {
        val paired = completedPairingPeer(pairing.phase, pairing.peer,
            identity.state.snapshot?.identity?.fingerprint, pairing.peers)
        if (paired != null) {
            session.lan.setAutomaticEnabled(automaticLanAfterPairing)
            navigation.paired()
            pairing.cancel()
            if (automaticAfterPairing && nearbyOwner.available) {
                context.startActivity(Intent().setClassName(context.packageName,
                    "${context.packageName}.features.backgroundprobe.CompanionProbeActivity")
                    .putExtra("peer", paired.deviceId).putExtra("enable", true))
            } else session.request(paired)
        }
    }
    val snackbars = remember { SnackbarHostState() }
    val pageState = rememberSaveableStateHolder()
    fun back() { navigation.back() }
    BackHandler(navigation.destination != AppDestination.Home || navigation.mediaDetails) { back() }
    Scaffold(containerColor = MaterialTheme.colorScheme.background,
        contentWindowInsets = WindowInsets.safeDrawing,
        topBar = {
            TopAppBar(title = { Text("aniCe", style = MaterialTheme.typography.titleMedium.copy(fontSize = 17.sp)) }, navigationIcon = {
                if ((navigation.destination == AppDestination.Devices &&
                        navigation.route != DeviceRoute.Overview && navigation.route != DeviceRoute.Pairing) ||
                    (navigation.destination == AppDestination.Settings && navigation.settingsRoute != SettingsRoute.Overview) ||
                    (navigation.destination == AppDestination.Features && navigation.featurePanel != null)) {
                    IconButton(onClick = { back() }) {
                        Icon(painterResource(R.drawable.ic_back), contentDescription = "Back")
                    }
                }
            }, actions = {
                if (navigation.destination != AppDestination.About) {
                    IconButton(onClick = { navigation.select(AppDestination.About, pairing.peers.isEmpty()) }) {
                        Icon(painterResource(R.drawable.ic_about), contentDescription = "About aniCe",
                            tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(18.dp))
                    }
                }
            }, expandedHeight = maxOf(48.dp, (24 * LocalDensity.current.fontScale + 16).dp),
                colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.background))
        }, bottomBar = {
            NavigationBar(modifier = Modifier.heightIn(
                min = if (largeText) maxOf(80.dp, (48f + 20f * fontScale).dp) else 80.dp
            )) {
                if (largeText) {
                    Box(Modifier.fillMaxWidth()) {
                        Row(Modifier.fillMaxWidth().padding(end = 48.dp)
                            .horizontalScroll(navigationScroll).selectableGroup()
                            .padding(horizontal = 8.dp, vertical = 8.dp),
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                            verticalAlignment = Alignment.CenterVertically) {
                            AppDestination.primary.forEach { page ->
                                val selected = navigation.destination == page
                                val destinationView = remember { BringIntoViewRequester() }
                                // Back and deep links can select a destination outside the visible strip.
                                LaunchedEffect(selected, navigationScroll.viewportSize) {
                                    if (selected && navigationScroll.viewportSize > 0) {
                                        destinationView.bringIntoView()
                                    }
                                }
                                val itemColor = if (selected) MaterialTheme.colorScheme.onSecondaryContainer
                                    else MaterialTheme.colorScheme.onSurfaceVariant
                                Row(Modifier.bringIntoViewRequester(destinationView).clip(MaterialTheme.shapes.large)
                                    .background(if (selected) MaterialTheme.colorScheme.secondaryContainer
                                        else androidx.compose.ui.graphics.Color.Transparent)
                                    .selectable(selected = selected,
                                        onClick = { navigation.select(page, pairing.peers.isEmpty()) },
                                        role = Role.Tab)
                                    .heightIn(min = 48.dp)
                                    .padding(horizontal = 12.dp, vertical = 8.dp),
                                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                                    verticalAlignment = Alignment.CenterVertically) {
                                    Icon(painterResource(page.icon),
                                        contentDescription = null, modifier = Modifier.size(20.dp), tint = itemColor)
                                    Text(page.label, style = MaterialTheme.typography.labelSmall,
                                        maxLines = 1, softWrap = false, color = itemColor)
                                }
                            }
                        }
                        if (navigationScroll.canScrollForward || navigationScroll.canScrollBackward) {
                            val movingForward = navigationScroll.canScrollForward
                            IconButton(onClick = {
                                navigationScrollScope.launch {
                                    navigationScroll.animateScrollTo(if (movingForward) navigationScroll.maxValue else 0)
                                }
                            }, modifier = Modifier.align(Alignment.CenterEnd)
                                .clip(MaterialTheme.shapes.large)
                                .background(MaterialTheme.colorScheme.surface)) {
                                Icon(painterResource(if (movingForward) R.drawable.ic_chevron_forward else R.drawable.ic_back),
                                    contentDescription = if (movingForward) "More destinations" else "Previous destinations",
                                    tint = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                        }
                    }
                } else {
                    AppDestination.primary.forEach { page ->
                        NavigationBarItem(selected = navigation.destination == page,
                            onClick = { navigation.select(page, pairing.peers.isEmpty()) },
                            icon = { Icon(painterResource(page.icon), contentDescription = null) },
                            label = { Text(page.label, style = MaterialTheme.typography.labelSmall, maxLines = 1) })
                    }
                }
            }
        }, snackbarHost = { SnackbarHost(snackbars) }
    ) { innerPadding ->
        // Consume Scaffold insets here so nested sheets and feature content do not apply the same padding twice.
        val content = Modifier.padding(innerPadding).consumeWindowInsets(innerPadding).fillMaxSize()
        Column(content) {
            if (pairing.busy && !(navigation.destination == AppDestination.Devices && navigation.route == DeviceRoute.Pairing)) {
                PendingRequestRow(if (pairing.phase == "approval") "Review pairing" else "Pairing in progress", pairing.status, navigation::pair)
            }
            val incoming = session.transfer.state as? io.github.anisharyal09.anice.features.transfer.TransferState.IncomingOffer
            if (incoming != null && navigation.destination != AppDestination.Home &&
                !(navigation.destination == AppDestination.Features && navigation.featurePanel == AppFeature.Files)) {
                PendingRequestRow("Incoming files", "${incoming.batch.files.size} files from ${incoming.batch.peerName}") {
                    navigation.openFeature(AppFeature.Files)
                }
            }
            Box(Modifier.weight(1f)) {
                // Destination keys retain scroll and local presentation state while another section is shown.
                pageState.SaveableStateProvider(navigation.destination.name) {
                    when (navigation.destination) {
                        AppDestination.Home, AppDestination.Devices -> pageState.SaveableStateProvider("devices-" + navigation.route.name) {
                            DevicesScreen(pairing, discovery, session, navigation, nearbyOwner, automaticAfterPairing, { automaticAfterPairing=it }, automaticLanAfterPairing, { automaticLanAfterPairing=it }, identity = identity)
                        }
                        AppDestination.Features -> FeaturesScreen(session, pairing.peers, navigation)
                        AppDestination.Favourites -> FeaturesScreen(session, pairing.peers, navigation, favouritesOnly = true)
                        AppDestination.About, AppDestination.Settings -> SettingsScreen(identity, snackbars, navigation, context, pairing.peers)
                    }
                }
            }
        }
    }
}

private val AppDestination.icon: Int
    get() = when (this) {
        AppDestination.Home -> R.drawable.ic_home
        AppDestination.Devices -> R.drawable.ic_devices
        AppDestination.Features -> R.drawable.ic_features
        AppDestination.Favourites -> R.drawable.ic_star
        AppDestination.Settings -> R.drawable.ic_settings
        AppDestination.About -> R.drawable.ic_about
    }

@Composable
internal fun PendingRequestRow(title: String, detail: String, onReview: () -> Unit) {
    Surface(onClick = onReview, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp),
        shape = androidx.compose.ui.graphics.RectangleShape, color = MaterialTheme.colorScheme.surfaceVariant,
        contentColor = MaterialTheme.colorScheme.onSurface) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(title, style = MaterialTheme.typography.titleSmall)
                Text(detail, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            Text("Review", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.primary)
        }
    }
}
