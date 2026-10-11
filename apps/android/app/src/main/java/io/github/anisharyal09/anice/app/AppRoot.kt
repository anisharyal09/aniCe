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

enum class AppDestination(val label: String) { Home("Home"), Devices("Devices"), Features("Features"), Settings("Settings") }
enum class DeviceRoute { Overview, Pairing, Discovery }
enum class SettingsRoute { Overview, Identity }

@Stable
class AppNavigation(destination: AppDestination = AppDestination.Home,
    route: DeviceRoute = DeviceRoute.Overview, focusedPeer: String? = null, settingsRoute: SettingsRoute = SettingsRoute.Overview) {
    var destination by mutableStateOf(destination)
    var route by mutableStateOf(route)
    var focusedPeer by mutableStateOf(focusedPeer)
    var mediaDetails by mutableStateOf(false)
    var settingsRoute by mutableStateOf(settingsRoute)
    fun select(page: AppDestination, unpaired: Boolean) {
        destination = page
        if (page == AppDestination.Devices && unpaired) route = DeviceRoute.Pairing
    }
    fun openDevice(id: String) { focusedPeer = id; route = DeviceRoute.Overview; destination = AppDestination.Devices }
    fun pair() { route = DeviceRoute.Pairing; destination = AppDestination.Devices }
    fun paired() { route = DeviceRoute.Overview; destination = AppDestination.Home }
    fun back() {
        if (destination == AppDestination.Devices && route != DeviceRoute.Overview) route = DeviceRoute.Overview
        else if (destination == AppDestination.Features && mediaDetails) mediaDetails=false
        else if (destination == AppDestination.Settings && settingsRoute != SettingsRoute.Overview) settingsRoute = SettingsRoute.Overview
        else destination = AppDestination.Home
    }
    companion object {
        val saver = listSaver<AppNavigation, String>(
            save = { listOf(it.destination.name, it.route.name, it.focusedPeer.orEmpty(), it.settingsRoute.name, it.mediaDetails.toString()) },
            restore = { AppNavigation(AppDestination.valueOf(it[0]), DeviceRoute.valueOf(it[1]), it[2].ifEmpty { null }, SettingsRoute.valueOf(it.getOrNull(3) ?: SettingsRoute.Overview.name)).also { value -> value.mediaDetails=it.getOrNull(4)=="true" } })
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AppRoot(identity: DeviceIdentityViewModel, discovery: DiscoveryViewModel,
    pairing: PairingViewModel, session: SessionViewModel) {
    val navigation = rememberSaveable(saver = AppNavigation.saver) { AppNavigation() }
    LaunchedEffect(identity.state.snapshot?.identity?.fingerprint) {
        if (identity.state.snapshot != null) pairing.refresh()
    }

    var automaticAfterPairing by rememberSaveable { mutableStateOf(true) }
    val context = LocalContext.current
    val nearbyOwner = io.github.anisharyal09.anice.features.backgroundprobe.CompanionProbe.get(LocalContext.current)
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
                        if (session.media.playback?.source?.isNotEmpty()==true) io.github.anisharyal09.anice.features.media.MediaView(session.media,compact=true) { navigation.destination=AppDestination.Features;navigation.mediaDetails=true }
                        if (pairing.busy) {
                            Text(pairing.status, style = MaterialTheme.typography.bodyMedium)
                            TextButton(onClick = { navigation.pair() }) { Text("Review pairing") }
                        }
                    }, sessions = {
                        SessionPanel(session, pairing.peers, onDiscoveryCheck = {}, compact = true,
                            onOpenDevice = { id -> navigation.openDevice(id) })
                    })
                    AppDestination.Devices -> pageState.SaveableStateProvider("devices-" + navigation.route.name) { when (navigation.route) {
                        DeviceRoute.Pairing -> {
                            PairingScreen(pairing, nearbyOwner.available, automaticAfterPairing) { automaticAfterPairing = it }
                        }
                        DeviceRoute.Discovery -> DiscoveryScreen(discovery)
                        DeviceRoute.Overview -> {
                            if (pairing.peers.isEmpty()) HomeScreen(false, onPair = { navigation.route = DeviceRoute.Pairing }, sessions = {})
                            else HomeScreen(true, onPair = { navigation.route = DeviceRoute.Pairing }, sessions = {
                                if (pairing.busy) TextButton(onClick = { navigation.route = DeviceRoute.Pairing }) { Text("Review pairing") }
                                SessionPanel(session, pairing.peers,
                                    onDiscoveryCheck = { navigation.route = DeviceRoute.Discovery }, focusedPeer = navigation.focusedPeer,
                                    onFocusConsumed = { navigation.focusedPeer = null })
                            })
                        }
                    }
                    }
                    AppDestination.Features -> Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(24.dp),verticalArrangement=Arrangement.spacedBy(16.dp)) {
                        if(navigation.mediaDetails) {
                            TextButton(onClick={navigation.mediaDetails=false}) { Text("Back to Features") }
                            io.github.anisharyal09.anice.features.media.MediaView(session.media)
                        } else {
                            Text("Mac controls",style=MaterialTheme.typography.titleMedium)
                            Surface(shape=MaterialTheme.shapes.medium,color=MaterialTheme.colorScheme.surfaceContainer, onClick={navigation.mediaDetails=true}) {
                                Column(Modifier.fillMaxWidth().padding(16.dp),verticalArrangement=Arrangement.spacedBy(6.dp)) {
                                    Text("Now Playing",style=MaterialTheme.typography.titleMedium)
                                    Text(session.media.playback?.title?.takeIf { it.isNotEmpty() } ?: "Playback and controls from your Mac",style=MaterialTheme.typography.bodyMedium)
                                }
                            }
                        }
                    }
                    AppDestination.Settings -> {
                        if (navigation.settingsRoute == SettingsRoute.Identity) {
                            DeviceIdentityScreen(identity.state, snackbars, identity::retry, identity::reset, onRename = identity::rename)
                        } else Column(Modifier.fillMaxSize().padding(24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                            Text("Appearance", style = MaterialTheme.typography.titleMedium)
                            val appearance = appearancePreference()
                            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                Appearance.entries.forEach { mode ->
                                    FilterChip(selected = appearance == mode,
                                        onClick = { saveAppearance(context, mode) }, label = { Text(mode.name) })
                                }
                            }
                            HorizontalDivider()
                            Row(Modifier.fillMaxWidth().clickable(role = androidx.compose.ui.semantics.Role.Button, onClickLabel = "Open this device") {
                                navigation.settingsRoute = SettingsRoute.Identity
                            }.heightIn(min = 48.dp), verticalAlignment = Alignment.CenterVertically) {
                                Column(Modifier.weight(1f)) {
                                    Text("This device", style = MaterialTheme.typography.titleMedium)
                                    Text(identity.state.snapshot?.identity?.deviceName ?: "Device identity",
                                        style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                }
                                Icon(painterResource(R.drawable.ic_back), contentDescription = null,
                                    modifier = Modifier.size(18.dp).graphicsLayer { rotationZ = 180f })
                            }
                        }
                    }
                }
            }
        }
    }
}
