// SPDX-License-Identifier: GPL-3.0-or-later
// Hosts shared inline setup and Android's native approval without an extra settings activity.
@file:Suppress("DEPRECATION") // Android 12/12L return EXTRA_DEVICE in the activity result.
package io.github.anisharyal09.anice.features.backgroundprobe

import android.app.Activity
import android.bluetooth.BluetoothDevice
import android.companion.AssociationInfo
import android.companion.CompanionDeviceManager
import android.os.Build
import androidx.activity.compose.LocalActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.IntentSenderRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.ViewModelStoreOwner
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import io.github.anisharyal09.anice.infrastructure.connections.displayName
import io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity

/**
 * Labels saved ID/fingerprint metadata only; never authorizes a native chooser or connection.
 * DeviceIdentity validation binds that fingerprint to the public key. trustedPeer/arm and
 * CompanionSetupTarget still compare the full credential before fresh EDHOC or enrollment.
 */
internal fun hasConnectionSetup(peer: DeviceIdentity?, selectedId: String?, selectedFingerprint: String?) =
    peer != null && peer.deviceId == selectedId && peer.fingerprint == selectedFingerprint

internal object CompanionSetupCopy {
    const val title = "Auto connect"
    const val explanation = "Reconnect when nearby, even in the background."
}

@Composable
internal fun rememberCompanionSetup(): CompanionSetupViewModel {
    val activity = requireNotNull(LocalActivity.current)
    return remember(activity) {
        ViewModelProvider(activity as ViewModelStoreOwner)[CompanionSetupViewModel::class.java]
    }
}

/** One result owner for nearby pairing, manual pairing and the existing Devices preference. */
@Composable
internal fun CompanionSetupEffects(model: CompanionSetupViewModel) {
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val activity = LocalActivity.current
    DisposableEffect(model, lifecycle, activity) {
        val observer = androidx.lifecycle.LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_STOP) model.presentationStopped(activity?.isChangingConfigurations == true)
        }
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer) }
    }
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
        model.approvalReturned(result.resultCode == Activity.RESULT_OK, association)
    }
    LaunchedEffect(model.phase, model.startRequested, lifecycle) {
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
            // Readiness/target validation is already owned by claimApproval. Do not
            // deliberately draw an extra preparation frame before Android's native UI.
            model.claimApproval(pending)?.let { sender ->
                try { approval.launch(IntentSenderRequest.Builder(sender).build()) }
                catch (_: Exception) { model.approvalLaunchFailed(pending.generation) }
            }
        }
    }
}

@Composable
internal fun CompanionSetupStatus(model: CompanionSetupViewModel) {
    if (!model.showing) return
    Surface(color = MaterialTheme.colorScheme.surface, modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(horizontal = 20.dp, vertical = 8.dp),
            // Material progress exposes an expanded accessibility area; keep it clear of the action row.
            verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(Modifier.fillMaxWidth().heightIn(min = 48.dp),
                verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(CompanionSetupCopy.title, style = MaterialTheme.typography.titleSmall)
                    Text(model.notice.ifBlank {
                        if (model.phase == CompanionSetupPhase.CONNECTING) "Connecting to ${model.peer?.displayName ?: "your Mac"}…"
                        else CompanionSetupCopy.explanation
                    }, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                TextButton(onClick = model::dismiss, modifier = Modifier.heightIn(min = 48.dp),
                    shape = MaterialTheme.shapes.small) { Text("Not now") }
                if (model.phase == CompanionSetupPhase.FAILED) TextButton(
                    enabled = model.canRetry, onClick = model::retry,
                    modifier = Modifier.heightIn(min = 48.dp), shape = MaterialTheme.shapes.small) { Text("Try again") }
            }
            Box(Modifier.fillMaxWidth().height(4.dp)) {
                if (model.phase.showsProgress) LinearProgressIndicator(Modifier.fillMaxWidth())
            }
        }
    }
}
