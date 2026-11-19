// SPDX-License-Identifier: GPL-3.0-or-later
// Hosts stable device-reconnection setup while one retained model owns Android's approval attempt.
@file:Suppress("DEPRECATION") // Android 12/12L return EXTRA_DEVICE in the activity result.
package io.github.anisharyal09.anice.features.backgroundprobe

import android.bluetooth.BluetoothDevice
import android.companion.CompanionDeviceManager
import android.companion.AssociationInfo
import android.content.Context
import android.content.Intent
import android.os.*
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.IntentSenderRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.repeatOnLifecycle
import io.github.anisharyal09.anice.AniCeApplication
import io.github.anisharyal09.anice.R
import io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity
import io.github.anisharyal09.anice.ui.AutomaticConnectionToggle
import io.github.anisharyal09.anice.ui.theme.AniCeTheme

internal fun hasConnectionSetup(peer: DeviceIdentity?, selectedId: String?, selectedFingerprint: String?) =
    peer != null && peer.deviceId == selectedId && peer.fingerprint == selectedFingerprint
internal fun automaticSetupReady(peer: DeviceIdentity?, available: Boolean, busy: Boolean) =
    peer != null && available && !busy

// Preview application IDs differ from their compiled activity namespace.
internal fun companionSetupIntent(context: Context, peerId: String, enable: Boolean = false) =
    Intent(context, CompanionProbeActivity::class.java).putExtra("peer", peerId).putExtra("enable", enable)
internal fun quickCompanionSetupIntent(context: Context, peerId: String) =
    Intent(context, CompanionQuickSetupActivity::class.java).putExtra("peer", peerId).putExtra("enable", true)

internal object CompanionSetupCopy {
    const val title = "Reconnect automatically"
    const val explanation = "Let aniCe reconnect to your Mac when it's nearby, even in the background, for sharing and device control."
    const val permissions = "Permissions for individual features stay separate."
}

open class CompanionProbeActivity : ComponentActivity() {
    private lateinit var model: CompanionSetupViewModel
    protected open val quick get() = false

    @OptIn(ExperimentalMaterial3Api::class)
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (!quick) enableEdgeToEdge()
        model = ViewModelProvider(this)[CompanionSetupViewModel::class.java]
        model.initialize(intent.getStringExtra("peer"), quick, intent.getBooleanExtra("enable", false), savedInstanceState != null)
        setContent {
            val lifecycle = LocalLifecycleOwner.current.lifecycle
            val permissions = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
                model.permissionsReturned()
            }
            val approval = rememberLauncherForActivityResult(ActivityResultContracts.StartIntentSenderForResult()) { result ->
                val association = if (Build.VERSION.SDK_INT >= 33)
                    result.data?.getParcelableExtra(CompanionDeviceManager.EXTRA_ASSOCIATION, AssociationInfo::class.java)?.let {
                        CompanionAssociation(it.deviceMacAddress?.toString(), it.id)
                    }
                else result.data?.getParcelableExtra<BluetoothDevice>(CompanionDeviceManager.EXTRA_DEVICE)?.let {
                    CompanionAssociation(it.address, -1)
                }
                model.approvalReturned(result.resultCode == RESULT_OK, association)
            }
            LaunchedEffect(model.phase, lifecycle) {
                lifecycle.repeatOnLifecycle(Lifecycle.State.RESUMED) {
                    withFrameNanos { }
                    model.startWhenReady()
                }
            }
            LaunchedEffect(model.permissionRequest, lifecycle) {
                lifecycle.repeatOnLifecycle(Lifecycle.State.RESUMED) {
                    val op = model.permissionRequest ?: return@repeatOnLifecycle
                    val missing = model.claimPermission(op)
                    if (missing.isEmpty()) model.permissionsReturned()
                    else try { permissions.launch(missing) } catch (_: Exception) { model.permissionLaunchFailed(op) }
                }
            }
            LaunchedEffect(model.pendingApproval, lifecycle) {
                lifecycle.repeatOnLifecycle(Lifecycle.State.RESUMED) {
                    val pending = model.pendingApproval ?: return@repeatOnLifecycle
                    // Draw one stable panel before Android overlays its own approval. Never relaunch on focus/rotation.
                    withFrameNanos { }
                    model.claimApproval(pending)?.let { sender ->
                        try { approval.launch(IntentSenderRequest.Builder(sender).build()) }
                        catch (_: Exception) { model.approvalLaunchFailed(pending.generation) }
                    }
                }
            }
            LaunchedEffect(model.complete) { if (model.complete) finish() }
            BackHandler { model.cancel(); finish() }
            AniCeTheme {
                if (quick) {
                    CompanionSetupPanel(model.peerName, model.phase, model.notice,
                        onClose = { model.cancel(); finish() }, onRetry = model::enable, canRetry = model.canEnable)
                } else {
                    Scaffold(topBar = { TopAppBar(title = { Text("Connection settings") }, navigationIcon = {
                        IconButton(onClick = { model.cancel(); finish() }) {
                            Icon(painterResource(R.drawable.ic_back), contentDescription = stringResource(R.string.back))
                        }
                    }) }, contentWindowInsets = WindowInsets.safeDrawing) { padding ->
                        Column(Modifier.padding(padding).consumeWindowInsets(padding).fillMaxSize()
                            .verticalScroll(rememberScrollState()).padding(24.dp),
                            verticalArrangement = Arrangement.spacedBy(16.dp)) {
                            Text(model.peerName, style = MaterialTheme.typography.titleLarge)
                            Text(CompanionSetupCopy.explanation, style = MaterialTheme.typography.bodyMedium)
                            Text(CompanionSetupCopy.permissions, style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant)
                            Text("Turn on Connect automatically on your Mac too.", style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant)
                            AutomaticConnectionToggle(checked = model.armed, enabled = model.canEnable,
                                onCheckedChange = { if (it) model.enable() else model.disable() })
                            if (!model.available) Text("Background auto-reconnect requires Android 12 or newer and companion-device support.",
                                style = MaterialTheme.typography.bodySmall)
                            Text(model.notice.ifBlank {
                                if (model.configured) model.policyStatus
                                else if (model.replacesOtherMac) "Enabling this Mac replaces the other Mac's automatic connection setup."
                                else "Automatic reconnection is off for this Mac."
                            }, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            if (model.phase.busy) {
                                LinearProgressIndicator(Modifier.fillMaxWidth())
                                TextButton(onClick = model::cancel) { Text("Cancel setup") }
                            }
                            if (model.configured) TextButton(onClick = model::reset, enabled = !model.phase.busy) {
                                Text("Reset connection setup")
                            }
                        }
                    }
                }
            }
        }
    }

    override fun onStart() {
        super.onStart()
        val app = application as AniCeApplication
        app.nowPlaying.foreground(this)
        app.sessionController.foreground(this)
        app.lanSessionController.foreground(this)
    }
    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        (application as AniCeApplication).clipboard.focus(hasFocus, this)
    }
    override fun onStop() {
        super.onStop()
        val app = application as AniCeApplication
        app.clipboard.focus(false, this)
        app.nowPlaying.background(this, isChangingConfigurations)
        app.sessionController.background(this, isChangingConfigurations)
        app.lanSessionController.background(this, isChangingConfigurations)
    }
}

/** Android knows this is a floating window before launching it, not after a full-screen starting window. */
class CompanionQuickSetupActivity : CompanionProbeActivity() {
    override val quick get() = true
}

/** Stable compact surface behind Android's native chooser, with no transient retry button or changing title. */
@Composable
internal fun CompanionSetupPanel(peerName: String, phase: CompanionSetupPhase, notice: String,
    onClose: () -> Unit, onRetry: () -> Unit, canRetry: Boolean = true) {
    Surface(color = MaterialTheme.colorScheme.surface, shape = MaterialTheme.shapes.extraLarge,
        modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.fillMaxWidth().navigationBarsPadding().verticalScroll(rememberScrollState()).padding(24.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Row(verticalAlignment = androidx.compose.ui.Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Icon(painterResource(R.drawable.ic_laptop), contentDescription = null,
                    tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(24.dp))
                Text(CompanionSetupCopy.title, style = MaterialTheme.typography.titleLarge)
            }
            Text(peerName, style = MaterialTheme.typography.bodyMedium)
            Text(CompanionSetupCopy.explanation, style = MaterialTheme.typography.bodyMedium)
            Text(CompanionSetupCopy.permissions, style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
            // Constant progress/status area avoids resizing while preparation hands off to OS approval.
            Column(Modifier.fillMaxWidth().heightIn(min = 60.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                // READY is only the frame before automatic start in this quick presentation.
                if (phase !in listOf(CompanionSetupPhase.FAILED, CompanionSetupPhase.COMPLETE))
                    LinearProgressIndicator(Modifier.fillMaxWidth())
                Text(notice.ifBlank { when (phase) {
                    CompanionSetupPhase.APPROVAL -> "Review Android's approval to finish."
                    CompanionSetupPhase.PERMISSION -> "Allow Bluetooth access to continue."
                    CompanionSetupPhase.SAVING -> "Finishing setup…"
                    CompanionSetupPhase.COMPLETE -> "Auto-reconnect is enabled."
                    else -> "Preparing Android's approval…"
                } },
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                TextButton(onClick = onClose, modifier = Modifier.heightIn(min = 48.dp)) {
                    Text(if (phase == CompanionSetupPhase.FAILED) "Close" else "Not now")
                }
                if (phase == CompanionSetupPhase.FAILED) TextButton(onClick = onRetry,
                    enabled = canRetry, modifier = Modifier.heightIn(min = 48.dp)) { Text("Try again") }
            }
        }
    }
}
