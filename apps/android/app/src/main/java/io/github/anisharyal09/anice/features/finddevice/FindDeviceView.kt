// SPDX-License-Identifier: GPL-3.0-or-later
// Presents local notification setup and truthful request feedback using Android resources.
package io.github.anisharyal09.anice.features.finddevice

import android.Manifest
import android.content.Intent
import android.os.Build
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import io.github.anisharyal09.anice.R

@Composable fun FindDeviceSetup(owner: FindDeviceController) {
    val context = LocalContext.current
    val native = (context.applicationContext as io.github.anisharyal09.anice.AniCeApplication).findDeviceNotification
    var permitted by remember { mutableStateOf(native.permitted()) }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { permitted = native.permitted() }
    val lifecycle = androidx.lifecycle.compose.LocalLifecycleOwner.current.lifecycle
    DisposableEffect(lifecycle) {
        val observer = androidx.lifecycle.LifecycleEventObserver { _, event ->
            if (event == androidx.lifecycle.Lifecycle.Event.ON_RESUME) permitted = native.permitted()
        }
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer) }
    }
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(stringResource(R.string.find_title), style = MaterialTheme.typography.titleMedium)
        Text(stringResource(R.string.find_explanation))
        Text(stringResource(R.string.find_ring_explanation), style = MaterialTheme.typography.bodySmall)
        TextButton(onClick = {
            if (Build.VERSION.SDK_INT >= 33) permission.launch(Manifest.permission.POST_NOTIFICATIONS)
            else context.startActivity(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName))
        }) { Text(stringResource(R.string.find_permission)) }
        TextButton(onClick = { context.startActivity(Intent(Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS)
            .putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName).putExtra(Settings.EXTRA_CHANNEL_ID, FindDeviceNotification.CHANNEL)) }) {
            Text(stringResource(R.string.find_settings))
        }
        Text(stringResource(if (permitted) R.string.find_local_allowed else R.string.find_local_blocked), style = MaterialTheme.typography.bodySmall)
        if (!owner.compatible) Text(stringResource(if (owner.connected) R.string.find_not_advertised else R.string.find_connect_first), style = MaterialTheme.typography.bodySmall)
        owner.feedbackPeer?.let { Text(it.deviceName, style = MaterialTheme.typography.bodySmall) }
        FindDeviceFeedback(owner)
    }
}
@Composable fun FindDeviceFeedback(owner: FindDeviceController) {
    val resource = when (owner.feedbackKey) {
        "find_waiting" -> R.string.find_waiting
        "find_submitted" -> R.string.find_submitted
        "find_blocked" -> R.string.find_blocked
        "find_stale" -> R.string.find_stale
        "find_busy" -> R.string.find_busy
        "find_failed" -> R.string.find_failed
        "find_timeout" -> R.string.find_timeout
        "find_disconnected" -> R.string.find_disconnected
        else -> R.string.find_idle
    }
    Text(stringResource(resource), style = MaterialTheme.typography.bodySmall)
}
