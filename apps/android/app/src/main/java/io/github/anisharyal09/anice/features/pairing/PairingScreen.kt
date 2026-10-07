// SPDX-License-Identifier: GPL-3.0-or-later
package io.github.anisharyal09.anice.features.pairing

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner

@Composable
fun PairingScreen(model: PairingViewModel) {
    val context = LocalContext.current
    var camera by remember { mutableStateOf(false) }
    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_STOP) camera = false
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }
    var pin by remember { mutableStateOf("") }
    var resettingTrust by remember { mutableStateOf(false) }
    var forget by remember { mutableStateOf<String?>(null) }
    val permission =
        rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
            result ->
            val activity = context as? android.app.Activity
            val permanent =
                result.any {
                    !it.value && activity?.shouldShowRequestPermissionRationale(it.key) == false
                }
            model.permissionReturned(permanent)
        }
    fun start() {
        val missing = model.missingPermissions()
        if (missing.isNotEmpty()) {
            model.permissionStarted()
            permission.launch(missing)
        } else model.start()
    }
    val cameraPermission =
        rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
            camera = granted
            if (!granted) model.cameraUnavailable()
        }
    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Text("Find your Mac", style = MaterialTheme.typography.headlineSmall)
        Text("On your Mac, open aniCe → Pair a device and show a QR code or six-digit code.")
        Text(model.status, color = MaterialTheme.colorScheme.onSurfaceVariant)
        if (camera) {
            PairingCamera(
                onCode = { text ->
                    camera = false
                    model.beginQR(text)
                    if (model.phase == "permission") start()
                },
                onUnavailable = {
                    camera = false
                    model.cameraUnavailable()
                },
            )
            TextButton(onClick = { camera = false }) { Text("Cancel camera") }
        } else if (!model.busy) {
            Button(
                onClick = {
                    if (
                        ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) ==
                            PackageManager.PERMISSION_GRANTED
                    )
                        camera = true
                    else cameraPermission.launch(Manifest.permission.CAMERA)
                }
            ) {
                Text("Scan QR code")
            }
            OutlinedTextField(
                value = pin,
                onValueChange = { pin = it.filter { c -> c in '0'..'9' }.take(6) },
                label = { Text("Six-digit code") },
                singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.NumberPassword),
                modifier = Modifier.fillMaxWidth(),
            )
            Button(
                onClick = {
                    model.beginPIN(pin)
                    if (model.phase == "permission") start()
                },
                enabled = pin.length == 6,
            ) {
                Text("Find Mac and enter code")
            }
            if (
                ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) !=
                    PackageManager.PERMISSION_GRANTED
            ) {
                TextButton(
                    onClick = {
                        context.startActivity(
                            Intent(
                                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                Uri.parse("package:${context.packageName}"),
                            )
                        )
                    }
                ) {
                    Text("Camera permission settings")
                }
            }
        }
        if (model.phase == "scan") {
            LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
            if (model.choosingCandidate) {
                Text(
                    "Nearby devices keep their names private during scanning. Tap your Mac to connect and verify its name.",
                    style = MaterialTheme.typography.bodySmall,
                )
                model.rows.forEachIndexed { index, id ->
                    OutlinedButton(
                        onClick = { model.select(id) },
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Text(
                            if (model.rows.size == 1) "Connect to your Mac"
                            else "Connect to nearby Mac ${index + 1}"
                        )
                    }
                }
            }
        } else if (
            model.phase in listOf("preparing", "connecting", "authenticating", "saving", "cleanup")
        ) {
            CircularProgressIndicator()
        }
        model.peer?.let { peer ->
            Text(peer.deviceName, style = MaterialTheme.typography.titleMedium)
            Text(peer.platform)
            Text(
                peer.fingerprint.chunked(4).joinToString(" "),
                style = MaterialTheme.typography.bodySmall,
            )
        }
        if (model.phase == "approval")
            Button(onClick = model::approve) { Text("Pair with this Mac") }
        if (model.busy) {
            if (model.remaining > 0)
                Text(
                    if (model.phase == "scan") "Scan ends in ${model.remaining} seconds"
                    else "This step ends in ${model.remaining} seconds"
                )
            TextButton(onClick = model::cancel) { Text("Cancel") }
        }
        when (model.recovery) {
            "trustStore" ->
                TextButton(onClick = { resettingTrust = true }) { Text("Reset local trust…") }
            "settings",
            "permission" ->
                TextButton(
                    onClick = {
                        context.startActivity(
                            Intent(
                                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                Uri.parse("package:${context.packageName}"),
                            )
                        )
                    }
                ) {
                    Text("Permission settings")
                }
            "bluetooth" ->
                TextButton(
                    onClick = { context.startActivity(Intent(Settings.ACTION_BLUETOOTH_SETTINGS)) }
                ) {
                    Text("Bluetooth settings")
                }
            "location" ->
                TextButton(
                    onClick = {
                        context.startActivity(Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS))
                    }
                ) {
                    Text("Location settings")
                }
        }
        HorizontalDivider()
        Text("Trusted devices", style = MaterialTheme.typography.titleMedium)
        if (model.peers.isEmpty()) Text("No trusted devices on this phone.")
        model.peers.forEach { r ->
            Text(r.peer.deviceName)
            Text(
                r.peer.fingerprint.chunked(4).joinToString(" "),
                style = MaterialTheme.typography.bodySmall,
            )
            TextButton(onClick = { forget = r.peer.deviceId }) { Text("Forget device…") }
        }
        TextButton(onClick = model::refresh) { Text("Refresh trusted devices") }
    }
    if (resettingTrust)
        AlertDialog(
            onDismissRequest = { resettingTrust = false },
            title = { Text("Reset local trust?") },
            text = {
                Text(
                    "The unreadable trust file will be preserved separately. Local pairings will be removed and must be paired again. Your identity key stays the same."
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        resettingTrust = false
                        model.recoverTrustStore()
                    }
                ) {
                    Text("Reset local trust")
                }
            },
            dismissButton = { TextButton(onClick = { resettingTrust = false }) { Text("Cancel") } },
        )
    if (forget != null)
        AlertDialog(
            onDismissRequest = { forget = null },
            title = { Text("Forget this device?") },
            text = {
                Text(
                    "This removes trust on this phone. Pair again to reconnect in a future secure session."
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        model.forget(forget!!)
                        forget = null
                    }
                ) {
                    Text("Forget device")
                }
            },
            dismissButton = { TextButton(onClick = { forget = null }) { Text("Cancel") } },
        )
}
