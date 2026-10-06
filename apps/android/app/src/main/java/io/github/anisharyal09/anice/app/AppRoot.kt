// SPDX-License-Identifier: GPL-3.0-or-later
package io.github.anisharyal09.anice.app

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
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
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import io.github.anisharyal09.anice.R
import io.github.anisharyal09.anice.features.deviceidentity.DeviceIdentityScreen
import io.github.anisharyal09.anice.features.deviceidentity.DeviceIdentityViewModel

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AppRoot(identity: DeviceIdentityViewModel) {
    var details by rememberSaveable { mutableStateOf(false) }
    val snackbars = remember { SnackbarHostState() }
    BackHandler(details) { details = false }
    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        contentWindowInsets = WindowInsets.safeDrawing,
        topBar = {
            TopAppBar(
                title = { Text(stringResource(if (details) R.string.this_device else R.string.app_name)) },
                navigationIcon = {
                    if (details) TextButton(onClick = { details = false }) { Text(stringResource(R.string.back)) }
                },
                actions = {
                    if (!details) TextButton(onClick = { details = true }) { Text(stringResource(R.string.this_device)) }
                },
                colors = TopAppBarDefaults.topAppBarColors(
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
            targetState = details,
            transitionSpec = { fadeIn() togetherWith fadeOut() },
            label = "screen_transition",
            modifier = content.fillMaxSize(),
        ) { isDetails ->
            if (isDetails) {
                DeviceIdentityScreen(identity.state, snackbars, identity::retry, identity::reset)
            } else {
                NoDevicesScreen()
            }
        }
    }
}

@Composable
private fun NoDevicesScreen(modifier: Modifier = Modifier) {
    Box(
        modifier = modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(24.dp),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            modifier = Modifier.fillMaxWidth(),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
        ) {
            Text(stringResource(R.string.no_devices_paired), style = MaterialTheme.typography.headlineSmall,
                textAlign = TextAlign.Center)
            Spacer(Modifier.height(12.dp))
            Text(stringResource(R.string.pairing_later), style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center)
        }
    }
}
