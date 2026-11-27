// SPDX-License-Identifier: GPL-3.0-or-later
// Presents update review, release-check settings and the Android installation handoff.
package io.github.anisharyal09.anice.update

import android.content.Intent
import android.net.Uri
import android.provider.Settings
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.LayoutDirection
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import io.github.anisharyal09.anice.app.PendingRequestRow
import io.github.anisharyal09.anice.ui.AutomaticConnectionToggle
import io.github.anisharyal09.anice.R
import java.util.Locale

@Composable
internal fun UpdateNotice(manager: AndroidUpdateManager) {
    val release by manager.available.collectAsState()
    val status by manager.status.collectAsState()
    val showing by manager.reviewing.collectAsState()
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(manager, lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME && manager.status.value == UpdateStatus.PermissionRequired &&
                context.packageManager.canRequestPackageInstalls()) manager.install()
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }
    release?.let { update ->
        PendingRequestRow("Update ${update.version.tag} available", "Review release notes and install", manager::review)
        if (showing) {
            UpdateReviewSheet(update, status, manager::dismissReview, { manager.skip(update.version) }, manager::cancel,
                onInstall = {
                    when (val state = status) {
                        UpdateStatus.PermissionRequired -> try {
                            context.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${context.packageName}"))
                                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                        } catch (_: Exception) { manager.settingsFailed() }
                        is UpdateStatus.AwaitingConfirmation -> try {
                            context.startActivity(state.intent); manager.confirmationOpened()
                        } catch (_: Exception) { manager.confirmationFailed() }
                        else -> manager.downloadAndInstall(update.version)
                    }
                },
                onGitHub = {
                    try {
                        context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(update.pageUrl)))
                    } catch (_: Exception) {}
                })
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun UpdateReviewSheet(
    release: AvailableRelease,
    status: UpdateStatus,
    onDismiss: () -> Unit,
    onSkip: () -> Unit,
    onCancel: () -> Unit,
    onInstall: () -> Unit,
    onGitHub: () -> Unit,
) {
    val density = LocalDensity.current
    val height = with(density) { LocalWindowInfo.current.containerSize.height.toDp() * 0.9f }
    val notesScroll = rememberScrollState()
    var moreActions by remember { mutableStateOf(false) }
    val dismissSheet = {
        moreActions = false
        onDismiss()
    }
    DisposableEffect(Unit) { onDispose { moreActions = false } }
    LaunchedEffect(release.version.tag) {
        notesScroll.scrollTo(0)
        moreActions = false
    }
    LaunchedEffect(status) {
        if (status is UpdateStatus.Failed || status == UpdateStatus.PermissionRequired || status is UpdateStatus.AwaitingConfirmation) {
            notesScroll.scrollTo(0)
        }
    }
    ModalBottomSheet(onDismissRequest = dismissSheet,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        // Native dialog and popup roots reset density; retain the app's text-size preference.
        CompositionLocalProvider(LocalDensity provides density) {
            Column(Modifier.fillMaxWidth().heightIn(max = height)) {
                Row(Modifier.fillMaxWidth().padding(start = 24.dp, end = 12.dp),
                    horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Text("App update", style = MaterialTheme.typography.titleMedium)
                        Surface(color = MaterialTheme.colorScheme.secondaryContainer, shape = MaterialTheme.shapes.small) {
                            Text(release.version.tag, Modifier.padding(horizontal = 8.dp, vertical = 4.dp),
                                style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.Medium)
                        }
                    }
                    IconButton(onClick = dismissSheet, modifier = Modifier.size(48.dp)) {
                        Icon(painterResource(R.drawable.ic_close), contentDescription = "Close update review", Modifier.size(20.dp))
                    }
                }
                Column(Modifier.weight(1f, fill = false).fillMaxWidth().verticalScroll(notesScroll)
                    .padding(horizontal = 24.dp, vertical = 16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    when (status) {
                        UpdateStatus.PermissionRequired -> Text("Allow aniCe to install apps in Android Settings, then return here.",
                            style = MaterialTheme.typography.bodyMedium)
                        UpdateStatus.Installing -> Text("Preparing the Android installer…", style = MaterialTheme.typography.bodyMedium)
                        is UpdateStatus.AwaitingConfirmation -> Text("Android needs your confirmation to install this update.",
                            style = MaterialTheme.typography.bodyMedium)
                        is UpdateStatus.Failed -> Text(status.message, style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.error)
                        else -> Unit
                    }
                    ReleaseNotesBody(release.notes, version = release.version.tag)
                }
                HorizontalDivider()
                Column(Modifier.fillMaxWidth().padding(horizontal = 24.dp).padding(top = 12.dp, bottom = 8.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    when (status) {
                        is UpdateStatus.Downloading -> {
                            val total = status.total?.takeIf { it > 0 }
                            if (total == null) {
                                LinearProgressIndicator(Modifier.fillMaxWidth())
                            } else {
                                val progress by animateFloatAsState(
                                    (status.bytes.toDouble() / total).toFloat().coerceIn(0f, 1f),
                                    animationSpec = ProgressIndicatorDefaults.ProgressAnimationSpec, label = "Update download")
                                LinearProgressIndicator(progress = { progress }, modifier = Modifier.fillMaxWidth())
                            }
                            Text(downloadSummary(status.bytes, total), style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                        else -> Unit
                    }
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp),
                        verticalAlignment = Alignment.CenterVertically) {
                        Button(onClick = if (status is UpdateStatus.Downloading) onCancel else onInstall,
                            modifier = Modifier.weight(1f).heightIn(min = 48.dp),
                            shape = MaterialTheme.shapes.small,
                            contentPadding = PaddingValues(horizontal = 16.dp, vertical = 8.dp),
                            enabled = status != UpdateStatus.Checking && status != UpdateStatus.Installing) {
                            Text(when (status) {
                                UpdateStatus.PermissionRequired -> "Open Settings"
                                is UpdateStatus.AwaitingConfirmation -> "Continue installation"
                                is UpdateStatus.Downloading -> "Cancel download"
                                UpdateStatus.Installing -> "Preparing installation…"
                                else -> "Install update"
                            }, textAlign = TextAlign.Center)
                        }
                        Box {
                            TextButton(shape = MaterialTheme.shapes.small,
                                contentPadding = PaddingValues(horizontal = 10.dp, vertical = 4.dp),
                                onClick = { moreActions = true }) { Text("More") }
                            DropdownMenu(expanded = moreActions, onDismissRequest = { moreActions = false }) {
                                CompositionLocalProvider(LocalDensity provides density) {
                                    DropdownMenuItem(text = { Text("Skip version") }, onClick = { moreActions = false; onSkip() },
                                        enabled = status != UpdateStatus.Checking && status !is UpdateStatus.Downloading && status != UpdateStatus.Installing && status !is UpdateStatus.AwaitingConfirmation)
                                    DropdownMenuItem(text = { Text("View on GitHub") }, onClick = { moreActions = false; onGitHub() })
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

internal fun downloadSummary(bytes: Long, total: Long?): String {
    fun megabytes(value: Long) = String.format(Locale.getDefault(), "%.1f MB", value.coerceAtLeast(0L) / 1_000_000.0)
    return "Downloaded ${megabytes(bytes)}" + (total?.takeIf { it > 0 }?.let { " of ${megabytes(it)}" } ?: "")
}

@Composable
internal fun UpdateSettings(manager: AndroidUpdateManager) {
    val beta by manager.includeBeta.collectAsState()
    val automaticChecks by manager.automaticChecks.collectAsState()
    val status by manager.status.collectAsState()
    val release by manager.available.collectAsState()
    UpdateSettingsContent(beta, automaticChecks, status, release?.version?.tag,
        manager::setIncludeBeta, manager::setAutomaticChecks) { manager.check(force = true) }
}

@Composable
internal fun UpdateSettingsContent(
    beta: Boolean,
    automaticChecks: Boolean,
    status: UpdateStatus,
    availableVersion: String?,
    onBetaChange: (Boolean) -> Unit,
    onAutomaticChecksChange: (Boolean) -> Unit,
    onCheck: () -> Unit,
) {
    var optionsExpanded by rememberSaveable { mutableStateOf(false) }
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
    if (summary != null) {
        Text(summary, Modifier.fillMaxWidth().padding(top = 4.dp),
            style = MaterialTheme.typography.bodySmall,
            color = if (status is UpdateStatus.Failed) MaterialTheme.colorScheme.error
                else MaterialTheme.colorScheme.onSurfaceVariant)
    }
    BoxWithConstraints(Modifier.fillMaxWidth()) {
        val density = LocalDensity.current
        val textMeasurer = rememberTextMeasurer()
        val optionsWidth = with(density) {
            textMeasurer.measure("More options", MaterialTheme.typography.labelMedium).size.width.toDp()
        } + 20.dp // Chevron and the 4 dp label gap.
        val checkLabel = if (status == UpdateStatus.Checking) "Checking…" else "Check for updates"
        val checkWidth = with(density) {
            textMeasurer.measure(checkLabel, MaterialTheme.typography.labelLarge).size.width.toDp()
        } + if (status == UpdateStatus.Checking) 20.dp else 0.dp
        if (maxWidth < optionsWidth + checkWidth + 8.dp) {
            Column(Modifier.fillMaxWidth()) {
                UpdateOptionsDisclosure(optionsExpanded) { optionsExpanded = !optionsExpanded }
                Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.CenterEnd) {
                    UpdateCheckAction(status, idle, onCheck)
                }
            }
        } else {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween) {
                UpdateOptionsDisclosure(optionsExpanded) { optionsExpanded = !optionsExpanded }
                UpdateCheckAction(status, idle, onCheck)
            }
        }
    }
    if (optionsExpanded) {
        AutomaticConnectionToggle(
            checked = automaticChecks,
            enabled = true,
            onCheckedChange = onAutomaticChecksChange,
            label = "Check for updates automatically",
            description = if (automaticChecks) "On launch when due; daily at 7:30 PM NPT."
                else "Manual checks remain available.",
            compact = true,
            descriptionBottomPadding = 0.dp,
        )
    } else if (!automaticChecks) {
        Text("Automatic checks are off.", style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun UpdateOptionsDisclosure(expanded: Boolean, onClick: () -> Unit) {
    val layoutDirection = LocalLayoutDirection.current
    TextButton(
        onClick = onClick,
        shape = MaterialTheme.shapes.small,
        colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.onSurfaceVariant),
        contentPadding = PaddingValues(0.dp),
        modifier = Modifier.heightIn(min = 48.dp)
            .semantics { stateDescription = if (expanded) "Expanded" else "Collapsed" },
    ) {
        Text("More options", style = MaterialTheme.typography.labelMedium)
        Spacer(Modifier.width(4.dp))
        Icon(painterResource(R.drawable.ic_chevron_forward), contentDescription = null,
            modifier = Modifier.size(16.dp).graphicsLayer(
                rotationZ = if (!expanded) 0f else if (layoutDirection == LayoutDirection.Ltr) 90f else -90f))
    }
}

@Composable
private fun UpdateCheckAction(status: UpdateStatus, enabled: Boolean, onClick: () -> Unit) {
    TextButton(
        onClick = onClick,
        enabled = enabled,
        modifier = Modifier.heightIn(min = 48.dp),
        contentPadding = PaddingValues(0.dp),
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
        compact = true,
        descriptionBottomPadding = 0.dp,
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
