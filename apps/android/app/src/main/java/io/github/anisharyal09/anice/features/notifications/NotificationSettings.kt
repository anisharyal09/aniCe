// SPDX-License-Identifier: GPL-3.0-or-later
// Offers explicit notification-listener access and a per-app mirroring allowlist.
package io.github.anisharyal09.anice.features.notifications

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.provider.Settings
import android.provider.Telephony
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.dp
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.core.graphics.drawable.toBitmap
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import io.github.anisharyal09.anice.R
import io.github.anisharyal09.anice.ui.AutomaticConnectionToggle
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

internal data class NotificationAppChoice(val packageName: String, val label: String)

internal fun sortNotificationAppChoices(
    choices: List<NotificationAppChoice>,
    selectedPackages: Set<String>,
): List<NotificationAppChoice> = choices.sortedWith(
    compareBy<NotificationAppChoice> { it.packageName !in selectedPackages }
        .thenBy { it.label.lowercase() }
        .thenBy { it.packageName },
)

internal fun filterNotificationAppChoices(
    choices: List<NotificationAppChoice>,
    query: String,
): List<NotificationAppChoice> {
    val term = query.trim()
    return if (term.isEmpty()) choices else choices.filter {
        it.label.contains(term, ignoreCase = true) || it.packageName.contains(term, ignoreCase = true)
    }
}

@Composable
fun NotificationSettings(owner: NotificationMirrorController, permissionsOnly: Boolean = false) {
    val context = LocalContext.current
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    var access by remember { mutableStateOf(false) }
    var mirrorIncomingCalls by remember { mutableStateOf(owner.preferences.mirrorIncomingCalls()) }
    var callPermissions by remember { mutableStateOf(false) }
    var callerIdPermissions by remember { mutableStateOf(false) }
    var permissionRevision by remember { androidx.compose.runtime.mutableIntStateOf(0) }
    fun refresh() {
        access = context.packageName in NotificationManagerCompat.getEnabledListenerPackages(context)
        owner.accessChanged(access)
        mirrorIncomingCalls = owner.preferences.mirrorIncomingCalls()
        callPermissions = ContextCompat.checkSelfPermission(context, Manifest.permission.READ_PHONE_STATE) == PackageManager.PERMISSION_GRANTED &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.ANSWER_PHONE_CALLS) == PackageManager.PERMISSION_GRANTED
        callerIdPermissions = listOf(Manifest.permission.READ_CALL_LOG, Manifest.permission.READ_CONTACTS).all {
            ContextCompat.checkSelfPermission(context, it) == PackageManager.PERMISSION_GRANTED
        }
        owner.phoneCallPermissionsChanged()
        permissionRevision++
    }
    val callPermissionLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { refresh() }
    val permissionButtonModifier = Modifier.defaultMinSize(minHeight = 32.dp)
    DisposableEffect(lifecycle) {
        val observer = androidx.lifecycle.LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) refresh()
        }
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer) }
    }
    LaunchedEffect(Unit) { refresh() }
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        if (permissionsOnly || access) {
            Text("Notification Access · ${if (access) "Allowed" else "Not allowed"}",
                style = MaterialTheme.typography.bodyMedium)
            Text("Read selected app alerts for mirroring to Mac.",
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        if (!access) {
            Text(
                "Allow access to sync alerts to your Mac.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 6.dp),
            )
            OutlinedButton(
                shape = MaterialTheme.shapes.small,
                colors = ButtonDefaults.outlinedButtonColors(containerColor = MaterialTheme.colorScheme.surfaceVariant),
                contentPadding = PaddingValues(horizontal = 10.dp, vertical = 2.dp),
                onClick = { context.startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)) },
                modifier = permissionButtonModifier,
            ) {
                Text("Enable notification access")
            }
        }
        if (!permissionsOnly) AutomaticConnectionToggle(
            checked = mirrorIncomingCalls,
            enabled = true,
            label = "Mirror incoming calls",
            description = "Answer or decline calls from your Mac (audio stays on phone).",
            compact = true,
            onCheckedChange = { enabled ->
                owner.preferences.setMirrorIncomingCalls(enabled)
                mirrorIncomingCalls = enabled
                owner.selectionChanged()
            },
        )
        if (permissionsOnly) {
            androidx.compose.runtime.key(permissionRevision) { PermissionGrantRows(listOf(
                Manifest.permission.READ_PHONE_STATE to "Phone state — Detect incoming SIM calls and list SIM choices.",
                Manifest.permission.ANSWER_PHONE_CALLS to "Answer phone calls — Answer or decline ringing SIM calls from Mac.",
            )) }
        } else if (callPermissions) {
            Text("Phone state and Answer phone calls · Allowed",
                style = MaterialTheme.typography.bodySmall)
            Text("Detect and control ringing SIM calls; audio stays on the phone.",
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        if ((permissionsOnly || mirrorIncomingCalls) && !callPermissions) {
            Text(
                "Allow phone access to answer or decline SIM calls from your Mac.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            OutlinedButton(
                shape = MaterialTheme.shapes.small,
                colors = ButtonDefaults.outlinedButtonColors(containerColor = MaterialTheme.colorScheme.surfaceVariant),
                contentPadding = PaddingValues(horizontal = 10.dp, vertical = 2.dp),
                onClick = {
                    callPermissionLauncher.launch(arrayOf(
                        Manifest.permission.READ_PHONE_STATE,
                        Manifest.permission.ANSWER_PHONE_CALLS,
                    ).filter { ContextCompat.checkSelfPermission(context, it) != PackageManager.PERMISSION_GRANTED }.toTypedArray())
                },
                modifier = permissionButtonModifier,
            ) {
                Text("Allow phone access")
            }
        }
        if (permissionsOnly) {
            androidx.compose.runtime.key(permissionRevision) { PermissionGrantRows(listOf(
                Manifest.permission.READ_CALL_LOG to "Call log — Receive incoming caller numbers; no call-history query.",
                Manifest.permission.READ_CONTACTS to "Contacts — Resolve incoming caller names locally.",
            )) }
        } else if (callerIdPermissions) {
            Text("Call log and Contacts · Allowed", style = MaterialTheme.typography.bodySmall)
            Text("Resolve incoming caller identity locally; caller details are not saved.",
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        if ((permissionsOnly || mirrorIncomingCalls) && !callerIdPermissions) {
            Text(
                "Match incoming numbers against Contacts for caller names.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            OutlinedButton(
                onClick = { callPermissionLauncher.launch(arrayOf(Manifest.permission.READ_CALL_LOG, Manifest.permission.READ_CONTACTS)
                    .filter { ContextCompat.checkSelfPermission(context, it) != PackageManager.PERMISSION_GRANTED }.toTypedArray()) },
                modifier = permissionButtonModifier,
                shape = MaterialTheme.shapes.small,
                colors = ButtonDefaults.outlinedButtonColors(containerColor = MaterialTheme.colorScheme.surfaceVariant),
                contentPadding = PaddingValues(horizontal = 10.dp, vertical = 2.dp),
            ) { Text("Allow caller ID") }
        }

    }
}

@Composable
private fun PermissionGrantRows(permissions: List<Pair<String, String>>) {
    val context = LocalContext.current
    for ((permission, purpose) in permissions) {
        val allowed = ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED
        Text("${purpose.substringBefore(" —")} · ${if (allowed) "Allowed" else "Not allowed"}",
            style = MaterialTheme.typography.bodyMedium)
        Text(purpose.substringAfter(" — "), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
fun NotificationAppSelection(owner: NotificationMirrorController) {
    val context = LocalContext.current
    var apps by remember { mutableStateOf(emptyList<NotificationAppChoice>()) }
    var selected by remember { mutableStateOf(owner.preferences.selectedPackages()) }
    var searchQuery by rememberSaveable { mutableStateOf("") }
    fun refresh() {
        val smsPackage = runCatching { Telephony.Sms.getDefaultSmsPackage(context) }.getOrNull()
        val launcher = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        @Suppress("DEPRECATION")
        val choices = context.packageManager.queryIntentActivities(launcher, 0).mapNotNull { row ->
            val packageName = row.activityInfo?.packageName ?: return@mapNotNull null
            if (packageName == context.packageName || packageName == smsPackage) return@mapNotNull null
            val label = runCatching { row.loadLabel(context.packageManager).toString() }.getOrDefault(packageName)
            NotificationAppChoice(packageName, label.ifBlank { packageName })
        }.distinctBy { it.packageName }
        selected = owner.preferences.selectedPackages()
        apps = sortNotificationAppChoices(choices, selected)
    }
    LaunchedEffect(Unit) { refresh() }
    val visibleApps = remember(apps, searchQuery) { filterNotificationAppChoices(apps, searchQuery) }
    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 20.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text("Select apps", style = MaterialTheme.typography.titleMedium)
        Text(
            if (selected.isEmpty()) "Choose which app alerts appear on your connected Mac."
            else "${selected.size} app${if (selected.size == 1) "" else "s"} selected. Selected apps appear first.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        OutlinedTextField(
            value = searchQuery,
            onValueChange = { searchQuery = it },
            modifier = Modifier.fillMaxWidth(),
            singleLine = true,
            placeholder = { Text("Search apps") },
            shape = MaterialTheme.shapes.small,
            trailingIcon = if (searchQuery.isEmpty()) null else ({
                IconButton(onClick = { searchQuery = "" }) {
                    Icon(painterResource(R.drawable.ic_close), contentDescription = "Clear search", modifier = Modifier.size(18.dp))
                }
            }),
        )
        if (apps.isEmpty()) {
            Text("No launchable apps are available.", style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
        } else if (visibleApps.isEmpty()) {
            Text("No apps match \"$searchQuery\".", style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        visibleApps.forEachIndexed { index, app ->
            val appIcon by produceState<ImageBitmap?>(null, app.packageName) {
                value = withContext(Dispatchers.IO) {
                    runCatching {
                        val icon = runCatching {
                            context.packageManager.getApplicationIcon(app.packageName)
                        }.getOrElse { context.packageManager.defaultActivityIcon }
                        icon.toBitmap(96, 96, Bitmap.Config.ARGB_8888).asImageBitmap()
                    }.getOrNull()
                }
            }
            Row(
                Modifier.fillMaxWidth().heightIn(min = 52.dp).padding(vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                appIcon?.let { Image(it, contentDescription = null, modifier = Modifier.size(40.dp)) }
                    ?: Spacer(Modifier.size(40.dp))
                Spacer(Modifier.width(12.dp))
                Text(app.label, Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
                Box(Modifier.size(width = 52.dp, height = 48.dp), contentAlignment = Alignment.Center) {
                    Switch(
                        checked = app.packageName in selected,
                        onCheckedChange = { enabled ->
                            owner.preferences.setSelected(app.packageName, enabled)
                            selected = owner.preferences.selectedPackages()
                            apps = sortNotificationAppChoices(apps, selected)
                            owner.selectionChanged()
                        },
                        modifier = Modifier.graphicsLayer(scaleX = 0.9f, scaleY = 0.9f),
                    )
                }
            }
            if (index != visibleApps.lastIndex) HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
        }
    }
}
