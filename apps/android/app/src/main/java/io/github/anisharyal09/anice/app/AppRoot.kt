// SPDX-License-Identifier: GPL-3.0-or-later
package io.github.anisharyal09.anice.app

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import io.github.anisharyal09.anice.R
import io.github.anisharyal09.anice.features.deviceidentity.DeviceIdentityScreen
import io.github.anisharyal09.anice.features.deviceidentity.DeviceIdentityViewModel
import io.github.anisharyal09.anice.features.discovery.DiscoveryScreen
import io.github.anisharyal09.anice.features.discovery.DiscoveryViewModel
import io.github.anisharyal09.anice.features.pairing.PairingScreen
import io.github.anisharyal09.anice.features.pairing.PairingViewModel
import io.github.anisharyal09.anice.features.session.SessionPanel
import io.github.anisharyal09.anice.features.session.SessionViewModel

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AppRoot(
    identity: DeviceIdentityViewModel,
    discovery: DiscoveryViewModel,
    pairing: PairingViewModel,
    session: SessionViewModel,
) {
    LaunchedEffect(identity.state.snapshot?.identity?.fingerprint) {
        if (identity.state.snapshot != null) pairing.refresh()
    }
    var pairingScreen by rememberSaveable { mutableStateOf(false) }
    var details by rememberSaveable { mutableStateOf(false) }
    var nearby by rememberSaveable { mutableStateOf(false) }
    val snackbars = remember { SnackbarHostState() }
    BackHandler(details || nearby || pairingScreen) {
        if (pairingScreen) {
            pairing.cancel()
            pairingScreen = false
        } else if (nearby) {
            discovery.cancel()
            nearby = false
        } else details = false
    }
    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        contentWindowInsets = WindowInsets.safeDrawing,
        topBar = {
            TopAppBar(
                title = {
                    Text(stringResource(if (details) R.string.this_device else R.string.app_name))
                },
                navigationIcon = {
                    if (details || nearby || pairingScreen)
                        TextButton(
                            onClick = {
                                pairing.cancel()
                                pairingScreen = false
                                discovery.cancel()
                                details = false
                                nearby = false
                            }
                        ) {
                            Text(stringResource(R.string.back))
                        }
                },
                actions = {
                    if (!details)
                        TextButton(
                            onClick = {
                                pairing.cancel()
                                pairingScreen = false
                                discovery.cancel()
                                nearby = false
                                details = true
                            }
                        ) {
                            Text(stringResource(R.string.this_device))
                        }
                },
                colors =
                    TopAppBarDefaults.topAppBarColors(
                        containerColor = MaterialTheme.colorScheme.surface,
                        titleContentColor = MaterialTheme.colorScheme.primary,
                    ),
            )
        },
        snackbarHost = { SnackbarHost(snackbars) },
    ) { innerPadding ->
        // Consume Scaffold's padding once so child screens do not apply safe insets again.
        val content = Modifier.padding(innerPadding).consumeWindowInsets(innerPadding)
        AnimatedContent(
            targetState = if (pairingScreen) 3 else if (details) 1 else if (nearby) 2 else 0,
            transitionSpec = { fadeIn() togetherWith fadeOut() },
            label = "screen_transition",
            modifier = content.fillMaxSize(),
        ) { screen ->
            if (screen == 3) {
                PairingScreen(pairing)
            } else if (screen == 1) {
                DeviceIdentityScreen(identity.state, snackbars, identity::retry, identity::reset)
            } else if (screen == 2) {
                DiscoveryScreen(discovery)
            } else {
                HomeScreen(
                    hasTrustedDevices = pairing.peers.isNotEmpty(),
                    onPair = {
                        session.cancel()
                        pairingScreen = true
                    },
                    onCheck = {
                        session.cancel()
                        nearby = true
                    },
                    sessions = { SessionPanel(session, pairing.peers) },
                )
            }
        }
    }
}
