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
import io.github.anisharyal09.anice.ui.PermissionStatusRow
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

internal data class NotificationPermissionSnapshot(
    val notificationAccess: Boolean,
    val phoneState: Boolean,
    val answerCalls: Boolean,
    val callLog: Boolean,
    val contacts: Boolean,
) {
    val phoneAccess: Boolean get() = phoneState && answerCalls
    val callerIdAccess: Boolean get() = callLog && contacts
    val allAllowed: Boolean get() = notificationAccess && phoneAccess && callerIdAccess
}

internal fun notificationPermissionSnapshot(context: android.content.Context): NotificationPermissionSnapshot {
    fun granted(permission: String): Boolean =
        ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED
    return NotificationPermissionSnapshot(
        notificationAccess = context.packageName in NotificationManagerCompat.getEnabledListenerPackages(context),
        phoneState = granted(Manifest.permission.READ_PHONE_STATE),
        answerCalls = granted(Manifest.permission.ANSWER_PHONE_CALLS),
        callLog = granted(Manifest.permission.READ_CALL_LOG),
        contacts = granted(Manifest.permission.READ_CONTACTS),
    )
}

@Composable
fun NotificationSettings(
    owner: NotificationMirrorController,
    permissionsOnly: Boolean = false,
    showGranted: Boolean = true,
    onPermissionsChanged: () -> Unit = {},
) {
    val context = LocalContext.current
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    var permissions by remember(context) { mutableStateOf(notificationPermissionSnapshot(context)) }
    var mirrorIncomingCalls by remember { mutableStateOf(owner.preferences.mirrorIncomingCalls()) }
    val changed = androidx.compose.runtime.rememberUpdatedState(onPermissionsChanged)
    fun refresh() {
        permissions = notificationPermissionSnapshot(context)
        owner.accessChanged(permissions.notificationAccess)
        mirrorIncomingCalls = owner.preferences.mirrorIncomingCalls()
        owner.phoneCallPermissionsChanged()
        changed.value()
    }
    val callPermissionLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { refresh() }
    val permissionButtonModifier = Modifier.defaultMinSize(minHeight = 32.dp)
    DisposableEffect(lifecycle, owner) {
        val observer = androidx.lifecycle.LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) refresh()
        }
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer) }
    }
    LaunchedEffect(owner) { refresh() }
    val notificationAction: @Composable () -> Unit = {
        OutlinedButton(
            shape = MaterialTheme.shapes.small,
            contentPadding = PaddingValues(horizontal = 10.dp, vertical = 2.dp),
            onClick = { context.startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)) },
            modifier = permissionButtonModifier,
        ) { Text("Enable notification access") }
    }
    val phoneAction: @Composable () -> Unit = {
        OutlinedButton(
            shape = MaterialTheme.shapes.small,
            contentPadding = PaddingValues(horizontal = 10.dp, vertical = 2.dp),
            onClick = {
                val missing = arrayOf(Manifest.permission.READ_PHONE_STATE, Manifest.permission.ANSWER_PHONE_CALLS)
                    .filter { ContextCompat.checkSelfPermission(context, it) != PackageManager.PERMISSION_GRANTED }
                if (missing.isNotEmpty()) callPermissionLauncher.launch(missing.toTypedArray())
                else refresh()
            },
            modifier = permissionButtonModifier,
        ) { Text("Allow phone access") }
    }
    val callerIdAction: @Composable () -> Unit = {
        OutlinedButton(
            shape = MaterialTheme.shapes.small,
            contentPadding = PaddingValues(horizontal = 10.dp, vertical = 2.dp),
            onClick = {
                val missing = arrayOf(Manifest.permission.READ_CALL_LOG, Manifest.permission.READ_CONTACTS)
                    .filter { ContextCompat.checkSelfPermission(context, it) != PackageManager.PERMISSION_GRANTED }
                if (missing.isNotEmpty()) callPermissionLauncher.launch(missing.toTypedArray())
                else refresh()
            },
            modifier = permissionButtonModifier,
        ) { Text("Allow caller ID") }
    }
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        if (permissionsOnly) {
            PermissionStatusRow("Notification Access", permissions.notificationAccess,
                "Read selected phone alerts for mirroring to Mac.", showGranted, notificationAction)
            if (showGranted || !permissions.phoneAccess) {
                Column(Modifier.fillMaxWidth()) {
                    PermissionStatusRow("Answer phone calls", permissions.answerCalls,
                        "Answer or decline ringing SIM calls from Mac; audio stays on the phone.", showGranted)
                    if (!permissions.phoneAccess) phoneAction()
                }
            }
            if (showGranted || !permissions.callerIdAccess) {
                Column(Modifier.fillMaxWidth()) {
                    PermissionStatusRow("Call log", permissions.callLog,
                        "Receive incoming caller numbers without querying call history.", showGranted)
                    PermissionStatusRow("Contacts", permissions.contacts,
                        "Resolve incoming caller names locally without saving caller details.", showGranted)
                    if (!permissions.callerIdAccess) callerIdAction()
                }
            }
        } else {
            if (!permissions.notificationAccess) {
                Text("Allow notification access to mirror selected alerts.",
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                notificationAction()
            }
            AutomaticConnectionToggle(
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
            if (mirrorIncomingCalls && !permissions.phoneAccess) {
                Text("Allow phone access for SIM call controls.",
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                phoneAction()
            }
            if (mirrorIncomingCalls && !permissions.callerIdAccess) {
                Text("Optional caller ID uses incoming numbers and Contacts.",
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                callerIdAction()
            }
        }
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
