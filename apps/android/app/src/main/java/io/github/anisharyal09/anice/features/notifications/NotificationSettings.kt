// SPDX-License-Identifier: GPL-3.0-or-later
// Offers explicit notification-listener access and a per-app mirroring allowlist.
package io.github.anisharyal09.anice.features.notifications

import android.content.Intent
import android.content.pm.PackageManager
import android.provider.Settings
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
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
import android.provider.Telephony

private data class AppChoice(val packageName: String, val label: String)

@Composable
fun NotificationSettings(owner: NotificationMirrorController) {
    val context = LocalContext.current
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    var access by remember { mutableStateOf(false) }
    var apps by remember { mutableStateOf(emptyList<AppChoice>()) }
    var selected by remember { mutableStateOf(owner.preferences.selectedPackages()) }
    fun refresh() {
        access = context.packageName in NotificationManagerCompat.getEnabledListenerPackages(context)
        owner.accessChanged(access)
        val smsPackage = runCatching { Telephony.Sms.getDefaultSmsPackage(context) }.getOrNull()
        val launcher = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        @Suppress("DEPRECATION")
        apps = context.packageManager.queryIntentActivities(launcher, 0).mapNotNull { row ->
            val packageName = row.activityInfo?.packageName ?: return@mapNotNull null
            if (packageName == context.packageName || packageName == smsPackage) return@mapNotNull null
            val label = runCatching { row.loadLabel(context.packageManager).toString() }.getOrDefault(packageName)
            AppChoice(packageName, label.ifBlank { packageName })
        }.distinctBy { it.packageName }.sortedBy { it.label.lowercase() }
        selected = owner.preferences.selectedPackages()
    }
    DisposableEffect(lifecycle) {
        val observer = androidx.lifecycle.LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) refresh()
        }
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer) }
    }
    LaunchedEffect(Unit) { refresh() }
    Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(
            if (access) "Notification Access is on. Choose which apps can send alerts to your connected Mac."
            else "Allow Notification Access, then choose which apps can send alerts to your connected Mac.",
            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        OutlinedButton(onClick = { context.startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)) }) {
            Text(if (access) "Manage Notification Access" else "Allow Notification Access")
        }
        if (apps.isEmpty()) {
            Text("No launchable apps are available.", style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        apps.forEach { app ->
            Row(
                Modifier.fillMaxWidth().heightIn(min = 52.dp).padding(vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(app.label, style = MaterialTheme.typography.bodyMedium)
                    Text(app.packageName, style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                Switch(checked = app.packageName in selected, onCheckedChange = { enabled ->
                    owner.preferences.setSelected(app.packageName, enabled)
                    selected = owner.preferences.selectedPackages()
                    owner.selectionChanged()
                })
            }
            if (app != apps.last()) HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
        }
    }
}
