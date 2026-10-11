// SPDX-License-Identifier: GPL-3.0-or-later
// Presents explicit new pairing and trust management while retaining mutual approval.
package io.github.anisharyal09.anice.features.pairing

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import io.github.anisharyal09.anice.ui.AutomaticConnectionToggle
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner

@Composable
fun PairingScreen(model: PairingViewModel, automaticAvailable: Boolean = false,
    automatic: Boolean = false, onAutomaticChanged: (Boolean) -> Unit = {}) {
    val context = LocalContext.current
    var camera by remember { mutableStateOf(false) }
    var addingDevice by rememberSaveable { mutableStateOf(false) }
    val showPairing = model.peers.isEmpty() || model.busy || addingDevice
    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_STOP) camera = false
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }
    var pin by rememberSaveable { mutableStateOf("") }
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
        Text(if (showPairing) "Pair your Mac" else "Manage devices", style = MaterialTheme.typography.headlineSmall)
        if (showPairing) {
            AutomaticConnectionToggle(checked = automaticAvailable && automatic,
                enabled = automaticAvailable && model.phase != "paired", onCheckedChange = onAutomaticChanged)
            if (!automaticAvailable) Text("Automatic Bluetooth is unavailable in this build.", style = MaterialTheme.typography.bodySmall)
            Text("On your Mac, open aniCe → Pair a device and show a QR code or six-digit code.")
            Text(model.status, color = MaterialTheme.colorScheme.onSurfaceVariant)
        } else {
            OutlinedButton(shape = MaterialTheme.shapes.small, contentPadding = PaddingValues(horizontal = 10.dp, vertical = 4.dp), onClick = { addingDevice = true }, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) {
                Text("Pair another Mac")
            }
        }
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
            TextButton(shape = MaterialTheme.shapes.small, contentPadding = PaddingValues(horizontal = 10.dp, vertical = 4.dp), onClick = { camera = false }) { Text("Cancel camera") }
        } else if (showPairing && !model.busy && model.phase != "paired") {
            OutlinedButton(shape = MaterialTheme.shapes.small, contentPadding = PaddingValues(horizontal = 10.dp, vertical = 4.dp),
                modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp),
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
            OutlinedButton(shape = MaterialTheme.shapes.small, contentPadding = PaddingValues(horizontal = 10.dp, vertical = 4.dp),
                modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp),
                onClick = {
                    model.beginPIN(pin)
                    if (model.phase == "permission") start()
                },
                enabled = pin.length == 6,
            ) {
                Text("Pair using code")
            }
            if (
                ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) !=
                    PackageManager.PERMISSION_GRANTED
            ) {
                TextButton(shape = MaterialTheme.shapes.small, contentPadding = PaddingValues(horizontal = 10.dp, vertical = 4.dp),
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
                    OutlinedButton(shape = MaterialTheme.shapes.small, contentPadding = PaddingValues(horizontal = 10.dp, vertical = 4.dp),
                        onClick = { model.select(id) },
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Text(
                            if (model.rows.size == 1) "Verify nearby Mac"
                            else "Verify nearby Mac ${index + 1}"
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
            Text("Mac")
            Text(
                peer.fingerprint.chunked(4).joinToString(" "),
                style = MaterialTheme.typography.bodySmall,
            )
        }
        if (model.phase == "approval")
            OutlinedButton(shape = MaterialTheme.shapes.small, contentPadding = PaddingValues(horizontal = 10.dp, vertical = 4.dp), onClick = model::approve, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) {
                Text("Approve pairing")
            }
        if (model.busy) {
            if (model.remaining > 0)
                Text(
                    if (model.phase == "scan") "Scan ends in ${model.remaining} seconds"
                    else "This step ends in ${model.remaining} seconds"
                )
            TextButton(shape = MaterialTheme.shapes.small, contentPadding = PaddingValues(horizontal = 10.dp, vertical = 4.dp), onClick = model::cancel) { Text("Cancel") }
        }
        when (model.recovery) {
            "trustStore" ->
                TextButton(shape = MaterialTheme.shapes.small, contentPadding = PaddingValues(horizontal = 10.dp, vertical = 4.dp), onClick = { resettingTrust = true }) { Text("Reset local trust…") }
            "settings",
            "permission" ->
                TextButton(shape = MaterialTheme.shapes.small, contentPadding = PaddingValues(horizontal = 10.dp, vertical = 4.dp),
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
                TextButton(shape = MaterialTheme.shapes.small, contentPadding = PaddingValues(horizontal = 10.dp, vertical = 4.dp),
                    onClick = { context.startActivity(Intent(Settings.ACTION_BLUETOOTH_SETTINGS)) }
                ) {
                    Text("Bluetooth settings")
                }
            "location" ->
                TextButton(shape = MaterialTheme.shapes.small, contentPadding = PaddingValues(horizontal = 10.dp, vertical = 4.dp),
                    onClick = {
                        context.startActivity(Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS))
                    }
                ) {
                    Text("Location settings")
                }
        }
        if (!model.busy && model.peers.isNotEmpty()) {
            HorizontalDivider()
            Text("Trusted devices", style = MaterialTheme.typography.titleMedium)
            model.peers.forEach { r ->
                Surface(modifier = Modifier.fillMaxWidth(), shape = MaterialTheme.shapes.medium,
                    color = MaterialTheme.colorScheme.surface) {
                    Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Row(Modifier.fillMaxWidth(), verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
                            Text(r.peer.deviceName, Modifier.weight(1f), style = MaterialTheme.typography.titleMedium)
                            TextButton(shape = MaterialTheme.shapes.small,
                                contentPadding = PaddingValues(horizontal = 10.dp, vertical = 4.dp),
                                onClick = { forget = r.peer.deviceId }) { Text("Forget…") }
                        }
                        Text("Mac fingerprint", style = MaterialTheme.typography.labelMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                        SelectionContainer {
                            Text(r.peer.fingerprint.chunked(4).joinToString(" "),
                                style = MaterialTheme.typography.bodySmall, fontFamily = FontFamily.Monospace)
                        }
                    }
                }
            }
            TextButton(shape = MaterialTheme.shapes.small, contentPadding = PaddingValues(horizontal = 10.dp, vertical = 4.dp), onClick = model::refresh, modifier = Modifier.heightIn(min = 48.dp)) { Text("Refresh trusted devices") }
        }
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
                TextButton(shape = MaterialTheme.shapes.small, contentPadding = PaddingValues(horizontal = 10.dp, vertical = 4.dp),
                    onClick = {
                        resettingTrust = false
                        model.recoverTrustStore()
                    }
                ) {
                    Text("Reset local trust")
                }
            },
            dismissButton = { TextButton(shape = MaterialTheme.shapes.small, contentPadding = PaddingValues(horizontal = 10.dp, vertical = 4.dp), onClick = { resettingTrust = false }) { Text("Cancel") } },
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
                TextButton(shape = MaterialTheme.shapes.small, contentPadding = PaddingValues(horizontal = 10.dp, vertical = 4.dp),
                    onClick = {
                        model.forget(forget!!)
                        forget = null
                    }
                ) {
                    Text("Forget device")
                }
            },
            dismissButton = { TextButton(shape = MaterialTheme.shapes.small, contentPadding = PaddingValues(horizontal = 10.dp, vertical = 4.dp), onClick = { forget = null }) { Text("Cancel") } },
        )
}
