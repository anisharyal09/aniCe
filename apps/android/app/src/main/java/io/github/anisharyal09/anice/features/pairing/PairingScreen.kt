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
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.selection.selectable
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.LayoutDirection
import io.github.anisharyal09.anice.R
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner

@Composable
fun PairingScreen(model: PairingViewModel, automaticAvailable: Boolean = false,
    automatic: Boolean = false, onAutomaticChanged: (Boolean) -> Unit = {},
    automaticLan: Boolean = true, onAutomaticLanChanged: (Boolean) -> Unit = {},
    onDismiss: () -> Unit = {}) {
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
    var pin by rememberSaveable { mutableStateOf("") }
    var enterCode by rememberSaveable { mutableStateOf(false) }
    var resettingTrust by remember { mutableStateOf(false) }
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
        Modifier.fillMaxWidth().heightIn(max = 680.dp).verticalScroll(rememberScrollState()).padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Row(verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
            Text("Pair a device", style = MaterialTheme.typography.titleLarge, modifier = Modifier.weight(1f))
            IconButton(onClick = onDismiss) {
                Icon(painterResource(R.drawable.ic_close), contentDescription = "Close pairing")
            }
        }
        AutomaticConnectionToggle(
            checked = if (automaticAvailable) automatic && automaticLan else automaticLan,
            enabled = model.phase != "paired",
            onCheckedChange = { enabled ->
                if (automaticAvailable) onAutomaticChanged(enabled)
                onAutomaticLanChanged(enabled)
            },
            label = "Connect automatically after pairing")
        if (!automaticAvailable) Text("Automatic Bluetooth is unavailable in this build.", style = MaterialTheme.typography.bodySmall)
        if (!enterCode || model.phase != "idle") {
            Text(model.status,
                style = if (model.phase == "idle") MaterialTheme.typography.bodyMedium else MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
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
        } else if (!model.busy && model.phase != "paired") {
            Surface(shape = MaterialTheme.shapes.medium, color = MaterialTheme.colorScheme.surfaceVariant) {
                Row(Modifier.fillMaxWidth().padding(4.dp), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    listOf(false to "QR code", true to "Six-digit code").forEach { (codeMode, label) ->
                        val selected = enterCode == codeMode
                        Box(
                            Modifier.weight(1f).clip(MaterialTheme.shapes.small)
                                .background(if (selected) MaterialTheme.colorScheme.surface else Color.Transparent)
                                .selectable(selected = selected, role = Role.Tab) { enterCode = codeMode }
                                .heightIn(min = 48.dp)
                                .padding(horizontal = 8.dp),
                            contentAlignment = androidx.compose.ui.Alignment.Center,
                        ) {
                            Text(label, color = if (selected) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                }
            }
            if (enterCode) {
                OutlinedTextField(
                    value = pin,
                    onValueChange = { pin = it.filter { c -> c in '0'..'9' }.take(6) },
                    placeholder = { Text("090909", modifier = Modifier.fillMaxWidth(), textAlign = TextAlign.Center) },
                    supportingText = { Text("Enter the code shown on your Mac.") },
                    singleLine = true,
                    textStyle = MaterialTheme.typography.headlineSmall.copy(
                        fontFamily = FontFamily.Monospace,
                        letterSpacing = 2.sp,
                        textAlign = TextAlign.Center,
                    ),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    modifier = Modifier.fillMaxWidth().semantics { contentDescription = "Six-digit pairing code" },
                )
            }
            if (!enterCode &&
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
        if (!camera && !model.busy && model.phase != "paired") {
            Text("Pair only with a device you recognize.", style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End,
                verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
                TextButton(onClick = onDismiss) { Text("Cancel") }
                if (enterCode) {
                    OutlinedButton(shape = MaterialTheme.shapes.small,
                        contentPadding = PaddingValues(horizontal = 10.dp, vertical = 4.dp),
                        onClick = {
                            model.beginPIN(pin)
                            if (model.phase == "permission") start()
                        },
                        enabled = pin.length == 6,
                    ) { Text("Pair using code") }
                } else {
                    OutlinedButton(shape = MaterialTheme.shapes.small,
                        contentPadding = PaddingValues(horizontal = 10.dp, vertical = 4.dp),
                        onClick = {
                            if (ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) ==
                                PackageManager.PERMISSION_GRANTED
                            ) camera = true else cameraPermission.launch(Manifest.permission.CAMERA)
                        },
                    ) { Text("Scan & continue") }
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
            LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
        }
        model.peer?.let { peer ->
            Text(peer.deviceName, style = MaterialTheme.typography.titleMedium)
            Text("Mac")
            Text("Security fingerprint", style = MaterialTheme.typography.labelMedium)
            SelectionContainer {
                Text(peer.fingerprint.chunked(4).joinToString(" "),
                    style = MaterialTheme.typography.bodySmall, modifier = Modifier.fillMaxWidth())
            }
            Text("Approve on both devices to finish pairing.", style = MaterialTheme.typography.bodySmall)
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
}

@Composable
fun TrustedDevicesSection(model: PairingViewModel) {
    val rtl = LocalLayoutDirection.current == LayoutDirection.Rtl
    var trustedExpanded by rememberSaveable { mutableStateOf(false) }
    var credentialPeer by rememberSaveable { mutableStateOf<String?>(null) }
    var forget by remember { mutableStateOf<String?>(null) }
    Column {
        Row(Modifier.fillMaxWidth().heightIn(min = 48.dp)
            .clickable(role = androidx.compose.ui.semantics.Role.Button,
                onClickLabel = if (trustedExpanded) "Hide trust and saved devices" else "Show trust and saved devices",
                onClick = { trustedExpanded = !trustedExpanded })
            .semantics { stateDescription = if (trustedExpanded) "Expanded" else "Collapsed" }
            .padding(vertical = 12.dp),
            verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
            Text("▶", style = MaterialTheme.typography.bodyMedium.copy(fontSize = 14.sp, fontWeight = FontWeight.Bold),
                modifier = Modifier.clearAndSetSemantics { }
                    .graphicsLayer(rotationZ = when {
                    trustedExpanded -> 90f
                    rtl -> 180f
                    else -> 0f
                }))
            Spacer(Modifier.width(8.dp))
            Text("Trust and saved devices", Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
        }
        if (trustedExpanded) {
            when {
                model.busy -> Text("Loading saved devices…", style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(vertical = 12.dp))
                model.peers.isEmpty() -> Text("No saved devices yet", style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(vertical = 12.dp))
                else -> model.peers.forEachIndexed { index, r ->
                    if (index > 0) HorizontalDivider()
                    Row(Modifier.fillMaxWidth().heightIn(min = 56.dp).padding(vertical = 4.dp),
                        verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
                        Column(Modifier.weight(1f).clickable(role = androidx.compose.ui.semantics.Role.Button,
                            onClickLabel = "Show security fingerprint for ${r.peer.deviceName}",
                            onClick = { credentialPeer = if (credentialPeer == r.peer.deviceId) null else r.peer.deviceId })
                            .heightIn(min = 48.dp), verticalArrangement = Arrangement.Center) {
                            Text(r.peer.deviceName, style = MaterialTheme.typography.bodyMedium)
                            Text("Trusted device", style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                        TextButton(shape = MaterialTheme.shapes.small,
                            contentPadding = PaddingValues(horizontal = 10.dp, vertical = 4.dp),
                            onClick = { forget = r.peer.deviceId }) { Text("Forget…") }
                    }
                    if (credentialPeer == r.peer.deviceId) {
                        Column(Modifier.fillMaxWidth().padding(start = 16.dp, bottom = 12.dp),
                            verticalArrangement = Arrangement.spacedBy(4.dp)) {
                            Text("Security fingerprint", style = MaterialTheme.typography.labelMedium,
                                color = MaterialTheme.colorScheme.onSurfaceVariant)
                            SelectionContainer {
                                Text(r.peer.fingerprint.chunked(4).joinToString(" "),
                                    style = MaterialTheme.typography.bodySmall, fontFamily = FontFamily.Monospace)
                            }
                        }
                    }
                }
            }
            TextButton(shape = MaterialTheme.shapes.small,
                contentPadding = PaddingValues(horizontal = 0.dp, vertical = 4.dp),
                onClick = model::refresh, modifier = Modifier.heightIn(min = 48.dp)) {
                Text("Refresh trusted devices")
            }
        }
        HorizontalDivider()
    }
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
