// SPDX-License-Identifier: GPL-3.0-or-later
// Offers explicit notification-listener access and a per-app mirroring allowlist.
package io.github.anisharyal09.anice.features.notifications

import android.content.Intent
import android.provider.Settings
import android.provider.Telephony
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.core.app.NotificationManagerCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner

internal data class NotificationAppChoice(val packageName: String, val label: String)

internal fun sortNotificationAppChoices(
    choices: List<NotificationAppChoice>,
    selectedPackages: Set<String>,
): List<NotificationAppChoice> = choices.sortedWith(
    compareBy<NotificationAppChoice> { it.packageName !in selectedPackages }
        .thenBy { it.label.lowercase() }
        .thenBy { it.packageName },
)

@Composable
fun NotificationSettings(owner: NotificationMirrorController) {
    val context = LocalContext.current
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    var access by remember { mutableStateOf(false) }
    var mirrorIncomingCalls by remember { mutableStateOf(owner.preferences.mirrorIncomingCalls()) }
    fun refresh() {
        access = context.packageName in NotificationManagerCompat.getEnabledListenerPackages(context)
        owner.accessChanged(access)
        mirrorIncomingCalls = owner.preferences.mirrorIncomingCalls()
    }
    DisposableEffect(lifecycle) {
        val observer = androidx.lifecycle.LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) refresh()
        }
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer) }
    }
    LaunchedEffect(Unit) { refresh() }
    Column(Modifier.fillMaxWidth().padding(top = 8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(
            if (access) "Notification access enabled. Choose apps below."
            else "Grant aniCe notification access in Android settings.",
            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        if (!access) {
            OutlinedButton(
                shape = MaterialTheme.shapes.small,
                colors = ButtonDefaults.outlinedButtonColors(containerColor = MaterialTheme.colorScheme.surfaceVariant),
                contentPadding = PaddingValues(horizontal = 10.dp, vertical = 2.dp),
                onClick = { context.startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)) },
                modifier = Modifier.defaultMinSize(minHeight = 32.dp),
            ) {
                Text("Enable notification access")
            }
        }
        Row(
            Modifier.fillMaxWidth().heightIn(min = 52.dp).padding(vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text("Mirror incoming calls", style = MaterialTheme.typography.bodyMedium)
                Text(
                    "Mirror supported call alerts with Answer/Decline. Audio stays on the phone.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            Switch(checked = mirrorIncomingCalls, onCheckedChange = { enabled ->
                owner.preferences.setMirrorIncomingCalls(enabled)
                mirrorIncomingCalls = enabled
                owner.selectionChanged()
            })
        }
    }
}

@Composable
fun NotificationAppSelection(owner: NotificationMirrorController) {
    val context = LocalContext.current
    var apps by remember { mutableStateOf(emptyList<NotificationAppChoice>()) }
    var selected by remember { mutableStateOf(owner.preferences.selectedPackages()) }
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
        if (apps.isEmpty()) {
            Text("No launchable apps are available.", style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        apps.forEach { app ->
            Row(
                Modifier.fillMaxWidth().heightIn(min = 52.dp).padding(vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(app.label, Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
                Switch(checked = app.packageName in selected, onCheckedChange = { enabled ->
                    owner.preferences.setSelected(app.packageName, enabled)
                    selected = owner.preferences.selectedPackages()
                    apps = sortNotificationAppChoices(apps, selected)
                    owner.selectionChanged()
                })
            }
            if (app != apps.last()) HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
        }
    }
}
