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
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import io.github.anisharyal09.anice.app.PendingRequestRow
import io.github.anisharyal09.anice.ui.AutomaticConnectionToggle

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
    UpdateSettingsContent(beta, status, release?.version?.tag, manager::setIncludeBeta) { manager.check(force = true) }
}

@Composable
internal fun UpdateSettingsContent(
    beta: Boolean,
    status: UpdateStatus,
    availableVersion: String?,
    onBetaChange: (Boolean) -> Unit,
    onCheck: () -> Unit,
) {
    BetaUpdatePreference(checked = beta, onCheckedChange = onBetaChange)
    val summary = when (val state = status) {
        UpdateStatus.Checking -> null
        UpdateStatus.UpToDate -> "You’re up to date."
        is UpdateStatus.Failed -> state.message
        is UpdateStatus.Downloading -> "Downloading update…"
        UpdateStatus.PermissionRequired -> "Allow installation in Android Settings."
        UpdateStatus.Installing -> "Preparing the Android installer…"
        is UpdateStatus.AwaitingConfirmation -> "Android needs your installation confirmation."
        UpdateStatus.Idle -> availableVersion?.let { "Update $it is available." }
    }
    val idle = status != UpdateStatus.Checking && status !is UpdateStatus.Downloading &&
        status != UpdateStatus.Installing && status !is UpdateStatus.AwaitingConfirmation &&
        status != UpdateStatus.PermissionRequired
    BoxWithConstraints(Modifier.fillMaxWidth()) {
        val stacked = maxWidth < 280.dp || LocalDensity.current.fontScale >= 1.4f
        val summaryColor = if (status is UpdateStatus.Failed) MaterialTheme.colorScheme.error
            else MaterialTheme.colorScheme.onSurfaceVariant
        Column(Modifier.fillMaxWidth()) {
            if (stacked && summary != null) {
                Text(summary, Modifier.fillMaxWidth().padding(top = 4.dp),
                    style = MaterialTheme.typography.bodySmall, color = summaryColor)
            }
            Row(Modifier.fillMaxWidth().heightIn(min = 48.dp), verticalAlignment = Alignment.CenterVertically) {
                if (!stacked && summary != null) {
                    Text(summary, Modifier.weight(1f).padding(end = 12.dp),
                        style = MaterialTheme.typography.bodySmall, color = summaryColor)
                } else {
                    Spacer(Modifier.weight(1f))
                }
                TextButton(
                    onClick = onCheck,
                    enabled = idle,
                    contentPadding = PaddingValues(horizontal = 4.dp, vertical = 0.dp),
                ) {
                    if (status == UpdateStatus.Checking) {
                        CircularProgressIndicator(Modifier.size(14.dp), strokeWidth = 2.dp)
                        Spacer(Modifier.width(6.dp))
                        Text("Checking…")
                    } else {
                        Text("Check for updates")
                    }
                }
            }
        }
    }
}

@Composable
internal fun BetaUpdatePreference(checked: Boolean, onCheckedChange: (Boolean) -> Unit) {
    var confirming by rememberSaveable { mutableStateOf(false) }
    LaunchedEffect(checked) { if (checked) confirming = false }
    AutomaticConnectionToggle(
        checked = checked,
        enabled = true,
        onCheckedChange = { requested ->
            if (requested && !checked) confirming = true else if (!requested) onCheckedChange(false)
        },
        label = "Include beta releases",
        description = if (checked) "Turning this off keeps your installed version."
            else "Get early builds and help test aniCe.",
    )
    if (confirming && !checked) {
        AlertDialog(
            onDismissRequest = { confirming = false },
            title = { Text("Try beta updates?") },
            text = {
                Text("You’ll be helping test aniCe. Beta builds may have bugs, interrupt connections or file transfers, " +
                    "and occasionally need recovery or re-adding trusted devices. " +
                    "Normal updates are intended to keep your settings and pairings.",
                    modifier = Modifier.heightIn(max = 360.dp).verticalScroll(rememberScrollState()))
            },
            confirmButton = {
                TextButton(onClick = { confirming = false; onCheckedChange(true) }) { Text("Enable beta updates") }
            },
            dismissButton = {
                TextButton(onClick = { confirming = false }) { Text("Not now") }
            },
        )
    }
}
