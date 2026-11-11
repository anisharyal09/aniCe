// SPDX-License-Identifier: GPL-3.0-or-later
// Presents user-initiated update checks and the Android installation handoff.
package io.github.anisharyal09.anice.update

import android.content.Intent
import android.net.Uri
import android.provider.Settings
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import io.github.anisharyal09.anice.app.PendingRequestRow

@Composable
internal fun UpdateNotice(manager: AndroidUpdateManager) {
    val release by manager.available.collectAsState()
    val status by manager.status.collectAsState()
    var showing by remember { mutableStateOf(false) }
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    LaunchedEffect(manager) { manager.check() }
    DisposableEffect(manager, lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME && manager.status.value == UpdateStatus.PermissionRequired &&
                context.packageManager.canRequestPackageInstalls()) manager.install()
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }
    release?.let { update ->
        PendingRequestRow("Update ${update.version.tag} available", "Review release notes and install") { showing = true }
        if (showing) {
            AlertDialog(onDismissRequest = { showing = false }, title = { Text("Update ${update.version.tag}") },
                text = {
                    Column(Modifier.heightIn(max = 360.dp).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        Text(update.notes.ifBlank { "No release notes provided." }, style = MaterialTheme.typography.bodyMedium)
                        TextButton(onClick = { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(update.pageUrl))) }) { Text("View release on GitHub") }
                        when (val state = status) {
                            is UpdateStatus.Downloading -> {
                                LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
                                Text("Downloaded ${state.bytes / 1_048_576} MB" + (state.total?.let { " of ${it / 1_048_576} MB" } ?: ""))
                            }
                            UpdateStatus.PermissionRequired -> Text("Allow aniCe to install apps in Android Settings, then return here.")
                            UpdateStatus.Installing -> Text("Preparing the Android installer…")
                            is UpdateStatus.AwaitingConfirmation -> Text("Android needs your confirmation to install this update.")
                            is UpdateStatus.Failed -> Text(state.message, color = MaterialTheme.colorScheme.error)
                            else -> Unit
                        }
                    }
                },
                confirmButton = {
                    when (val state = status) {
                        is UpdateStatus.Downloading -> TextButton(onClick = manager::cancel) { Text("Cancel download") }
                        UpdateStatus.Installing -> Unit
                        UpdateStatus.PermissionRequired -> TextButton(onClick = {
                            try {
                                context.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${context.packageName}"))
                                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                            } catch (_: Exception) { manager.settingsFailed() }
                        }) { Text("Open Settings") }
                        is UpdateStatus.AwaitingConfirmation -> TextButton(onClick = {
                            try { context.startActivity(state.intent); manager.confirmationOpened() }
                            catch (_: Exception) { manager.confirmationFailed() }
                        }) { Text("Continue installation") }
                        else -> TextButton(onClick = manager::downloadAndInstall, enabled = status != UpdateStatus.Checking) { Text("Install update") }
                    }
                },
                dismissButton = {
                    Row {
                        TextButton(onClick = { manager.skip(); showing = false }, enabled = status !is UpdateStatus.Downloading && status != UpdateStatus.Installing && status !is UpdateStatus.AwaitingConfirmation) { Text("Skip version") }
                        TextButton(onClick = { showing = false }) { Text("Later") }
                    }
                })
        }
    }
}

@Composable
internal fun UpdateSettings(manager: AndroidUpdateManager) {
    val beta by manager.includeBeta.collectAsState()
    val status by manager.status.collectAsState()
    val release by manager.available.collectAsState()
    Row(Modifier.fillMaxWidth().heightIn(min = 48.dp), horizontalArrangement = Arrangement.SpaceBetween) {
        Column(Modifier.weight(1f)) {
            Text("Include beta releases")
            Text("Turning this off keeps an installed beta until a newer stable release is available.", style = MaterialTheme.typography.bodySmall)
        }
        Switch(checked = beta, onCheckedChange = manager::setIncludeBeta)
    }
    TextButton(onClick = { manager.check(force = true) }, enabled = status != UpdateStatus.Checking && status !is UpdateStatus.Downloading) { Text("Check for updates") }
    when (val state = status) {
        UpdateStatus.Checking -> Text("Checking for updates…")
        UpdateStatus.UpToDate -> Text("You’re up to date.")
        is UpdateStatus.Failed -> Text(state.message, color = MaterialTheme.colorScheme.error)
        else -> if (release != null) Text("Update ${release!!.version.tag} is available.")
    }
}
