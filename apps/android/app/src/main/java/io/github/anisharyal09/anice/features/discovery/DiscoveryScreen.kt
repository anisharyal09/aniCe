// SPDX-License-Identifier: GPL-3.0-or-later
// Presents bounded Bluetooth discovery progress and compatibility results.
package io.github.anisharyal09.anice.features.discovery

import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.content.Intent
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Card
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.core.net.toUri
import androidx.core.app.ActivityCompat
import io.github.anisharyal09.anice.infrastructure.bluetooth.RecoveryReason

@Composable
fun DiscoveryScreen(model: DiscoveryViewModel) {
    val context = LocalContext.current
    val activity = context as? Activity
    val permissions = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { result ->
        val permanent = result.any { (permission, granted) -> !granted && activity != null && !ActivityCompat.shouldShowRequestPermissionRationale(activity, permission) }
        model.permissionsReturned(permanent)
    }
    val enable = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { /* Explicit Scan again after recovery. */ }
    fun start() {
        val missing = model.permissionsToRequest()
        if (missing.isNotEmpty()) { model.permissionRequestStarted(); permissions.launch(missing) }
        else model.start()
    }
    val state = model.state
    Column(Modifier.verticalScroll(rememberScrollState()).padding(24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Text("Nearby compatibility check", style = MaterialTheme.typography.headlineSmall)
        Text("Starting a scan closes Bluetooth connections. Local network stays connected.",
            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text("On your Mac, open aniCe and choose Make this Mac discoverable. Then scan here.",
            color = MaterialTheme.colorScheme.onSurfaceVariant)
        Card(Modifier.fillMaxWidth()) {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(state.message, style = MaterialTheme.typography.bodyLarge)
                if (state.busy) CircularProgressIndicator()
                if (state.scanning) Text("Scan ends in ${state.remainingSeconds} seconds")
                state.candidates.forEach { candidate ->
                    TextButton(shape = MaterialTheme.shapes.small, contentPadding = PaddingValues(horizontal = 10.dp, vertical = 4.dp), onClick = { model.select(candidate.rowId) }, modifier = Modifier.fillMaxWidth()) {
                        Text("Nearby aniCe device ${candidate.number}")
                    }
                }
                if (state.busy) {
                    TextButton(shape = MaterialTheme.shapes.small, contentPadding = PaddingValues(horizontal = 10.dp, vertical = 4.dp), onClick = model::cancel) { Text("Cancel") }
                } else {
                    when (state.recovery) {
                        RecoveryReason.permanentDenial -> OutlinedButton(shape = MaterialTheme.shapes.small, contentPadding = PaddingValues(horizontal = 10.dp, vertical = 4.dp), onClick = {
                            context.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, "package:${context.packageName}".toUri()))
                        }) { Text("Open app settings") }
                        RecoveryReason.bluetoothDisabled -> OutlinedButton(shape = MaterialTheme.shapes.small, contentPadding = PaddingValues(horizontal = 10.dp, vertical = 4.dp), onClick = {
                            enable.launch(Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE))
                        }) { Text("Turn on Bluetooth") }
                        RecoveryReason.locationServicesDisabled -> OutlinedButton(shape = MaterialTheme.shapes.small, contentPadding = PaddingValues(horizontal = 10.dp, vertical = 4.dp), onClick = {
                            context.startActivity(Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS))
                        }) { Text("Open location settings") }
                        RecoveryReason.unsupported -> Unit
                        else -> OutlinedButton(shape = MaterialTheme.shapes.small, contentPadding = PaddingValues(horizontal = 10.dp, vertical = 4.dp), onClick = ::start) { Text(if (state.recovery == RecoveryReason.permission) "Allow discovery access" else "Scan for nearby devices") }
                    }
                    if (state.recovery in listOf(RecoveryReason.permanentDenial, RecoveryReason.bluetoothDisabled, RecoveryReason.locationServicesDisabled)) {
                        TextButton(shape = MaterialTheme.shapes.small, contentPadding = PaddingValues(horizontal = 10.dp, vertical = 4.dp), onClick = ::start) { Text("Try again") }
                    }
                }
            }
        }
        Text("Nearby discovery does not identify or trust a device. Use Find your Mac from the home screen to pair with a QR code or six-digit code.", color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}
