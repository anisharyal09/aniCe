// SPDX-License-Identifier: GPL-3.0-or-later
// Keeps incoming Find Phone notification recovery in Settings, separate from outbound Mac requests.
package io.github.anisharyal09.anice.features.finddevice

import android.Manifest
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import io.github.anisharyal09.anice.R
import io.github.anisharyal09.anice.ui.PermissionStatusRow

@Composable
fun FindDevicePermissionSettings(
    allowed: Boolean,
    showGranted: Boolean,
    onPermissionsChanged: () -> Unit = {},
) {
    val context = LocalContext.current
    val native = (context.applicationContext as io.github.anisharyal09.anice.AniCeApplication).findDeviceNotification
    val changed by rememberUpdatedState(onPermissionsChanged)
    var refused by rememberSaveable { mutableStateOf(false) }
    fun missingRuntimePermission(): Boolean = Build.VERSION.SDK_INT >= 33 &&
        ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        refused = !granted
        changed()
    }
    FindPhonePermissionRow(
        allowed = allowed,
        showGranted = showGranted,
        requestable = missingRuntimePermission() && !refused,
        request = {
            if (native.permitted()) changed()
            else if (missingRuntimePermission()) permission.launch(Manifest.permission.POST_NOTIFICATIONS)
            else context.startActivity(findPhoneNotificationSettingsIntent(context))
        },
        openSettings = { context.startActivity(findPhoneNotificationSettingsIntent(context)) },
    )
}

@Composable
internal fun FindPhonePermissionRow(
    allowed: Boolean,
    showGranted: Boolean,
    requestable: Boolean,
    request: () -> Unit,
    openSettings: () -> Unit,
) {
    PermissionStatusRow(
        stringResource(R.string.find_phone_permission_title), allowed,
        stringResource(R.string.find_phone_permission_purpose), showGranted,
    ) {
        OutlinedButton(
            onClick = if (requestable) request else openSettings,
            shape = MaterialTheme.shapes.small,
            contentPadding = PaddingValues(horizontal = 10.dp, vertical = 2.dp),
            modifier = Modifier.heightIn(min = 48.dp),
        ) { Text(stringResource(if (requestable) R.string.find_phone_permission_action else R.string.find_settings)) }
    }
}

internal fun findPhoneNotificationSettingsIntent(context: Context): Intent =
    if (context.getSystemService(NotificationManager::class.java).areNotificationsEnabled()) {
        Intent(Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS)
            .putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
            .putExtra(Settings.EXTRA_CHANNEL_ID, FindDeviceNotification.CHANNEL)
    } else {
        Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
    }

@Composable
internal fun findDeviceFeedbackText(key: String): String {
    val resource = when (key) {
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
    return stringResource(resource)
}
