// SPDX-License-Identifier: GPL-3.0-or-later
// Routes existing device, pairing and diagnostic presentations while preserving native lifecycle ownership.
package io.github.anisharyal09.anice.app

import android.content.Intent
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
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
import androidx.compose.ui.unit.dp
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
    val navigation = rememberSaveable(saver = AppNavigation.saver) { AppNavigation() }
    LaunchedEffect(session.media.openWorkspaceRequest) {
        if(session.media.openWorkspaceRequest) { navigation.destination=AppDestination.Features;navigation.mediaDetails=true;session.media.workspaceOpened() }
    }
    LaunchedEffect(identity.state.snapshot?.identity?.fingerprint) {
        if (identity.state.snapshot != null) pairing.refresh()
    }

    var automaticAfterPairing by rememberSaveable { mutableStateOf(true) }
    val context = LocalContext.current
    val nearbyOwner = io.github.anisharyal09.anice.infrastructure.connections.CompanionProbe.get(LocalContext.current)
    LaunchedEffect(pairing.busy) {
        if (pairing.busy || discovery.state.busy) nearbyOwner.suspend() else nearbyOwner.resumeAfterOperation()
    }
    LaunchedEffect(pairing.phase, pairing.peers, identity.state.snapshot?.identity?.fingerprint) {
        val paired = completedPairingPeer(pairing.phase, pairing.peer,
            identity.state.snapshot?.identity?.fingerprint, pairing.peers)
        if (paired != null) {
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
    BackHandler(navigation.destination != AppDestination.Home) { back() }
    Scaffold(containerColor = MaterialTheme.colorScheme.background,
        contentWindowInsets = WindowInsets.safeDrawing,
        topBar = {
            TopAppBar(title = { Text(if (navigation.destination == AppDestination.Devices && navigation.route != DeviceRoute.Overview)
                if (navigation.route == DeviceRoute.Pairing) "Manage devices" else "Nearby discovery"
                else if (navigation.destination == AppDestination.Settings && navigation.settingsRoute == SettingsRoute.Identity) "This device"
                else if (navigation.destination == AppDestination.Settings) "aniCe Settings" else "aniCe",
                style = MaterialTheme.typography.titleMedium) }, navigationIcon = {
                if ((navigation.destination == AppDestination.Devices && navigation.route != DeviceRoute.Overview) ||
                    (navigation.destination == AppDestination.Settings && navigation.settingsRoute == SettingsRoute.Identity)) {
                    IconButton(onClick = { back() }) {
                        Icon(painterResource(R.drawable.ic_back), contentDescription = "Back")
                    }
                }
            }, expandedHeight = maxOf(48.dp, (24 * LocalDensity.current.fontScale + 16).dp),
                colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.surface))
        }, bottomBar = {
            NavigationBar {
                AppDestination.entries.forEach { page ->
                    NavigationBarItem(selected = navigation.destination == page,
                        onClick = { navigation.select(page, pairing.peers.isEmpty()) },
                        icon = { Icon(painterResource(when(page) { AppDestination.Home -> R.drawable.ic_home; AppDestination.Devices -> R.drawable.ic_devices; AppDestination.Features -> R.drawable.ic_features; AppDestination.Settings -> R.drawable.ic_settings }), contentDescription = null) },
                        label = { Text(page.label) })
                }
            }
        }, snackbarHost = { SnackbarHost(snackbars) }
    ) { innerPadding ->
        val content = Modifier.padding(innerPadding).consumeWindowInsets(innerPadding).fillMaxSize()
        Box(content) {
            pageState.SaveableStateProvider(navigation.destination.name) {
                when (navigation.destination) {
                    AppDestination.Home -> HomeScreen(pairing.peers.isNotEmpty(), onPair = {
                        navigation.pair()
                    }, compact = true, attention = {
                        if (session.media.compactVisible) io.github.anisharyal09.anice.features.nowplaying.MediaView(session.media,compact=true) { navigation.destination=AppDestination.Features;navigation.mediaDetails=true }
                        if (pairing.busy) {
                            Text(pairing.status, style = MaterialTheme.typography.bodyMedium)
                            TextButton(onClick = { navigation.pair() }) { Text("Review pairing") }
                        }
                    }, sessions = {
                        SessionPanel(session, pairing.peers, onDiscoveryCheck = {}, compact = true,
                            onOpenDevice = { id -> navigation.openDevice(id) })
                    })
                    AppDestination.Devices -> pageState.SaveableStateProvider("devices-" + navigation.route.name) {
                        DevicesScreen(pairing, discovery, session, navigation, nearbyOwner, automaticAfterPairing) { automaticAfterPairing=it }
                    }
                    AppDestination.Features -> FeaturesScreen(session.media, navigation)
                    AppDestination.Settings -> SettingsScreen(identity, snackbars, navigation, context)
                }
            }
        }
    }
}
