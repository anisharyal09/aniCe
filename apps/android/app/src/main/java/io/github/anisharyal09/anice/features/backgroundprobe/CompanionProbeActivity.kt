// SPDX-License-Identifier: GPL-3.0-or-later
// Presents device-scoped automatic connection settings and the native association chooser.
@file:Suppress("DEPRECATION") // API 31/32 association results use EXTRA_DEVICE.
package io.github.anisharyal09.anice.features.backgroundprobe

import android.bluetooth.BluetoothDevice
import android.bluetooth.le.ScanFilter
import android.companion.*
import android.content.IntentSender
import android.os.*
import androidx.activity.ComponentActivity
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
import androidx.compose.ui.unit.dp
import androidx.lifecycle.lifecycleScope
import io.github.anisharyal09.anice.AniCeApplication
import android.content.pm.ApplicationInfo
import io.github.anisharyal09.anice.infrastructure.bluetooth.BlePayloadCodec
import io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity
import io.github.anisharyal09.anice.ui.theme.AniCeTheme
import java.util.UUID
import kotlinx.coroutines.*

/** Presentation scope only; association and pinned active trust are revalidated before connection. */
internal fun hasConnectionSetup(peer: DeviceIdentity?, selectedId: String?, selectedFingerprint: String?) =
  peer != null && peer.deviceId == selectedId && peer.fingerprint == selectedFingerprint

/** Native device-scoped setup; the system chooser grants ownership, never peer authentication. */
class CompanionProbeActivity : ComponentActivity() {
  private val probe get() = CompanionProbe.get(this)
  private var peer: DeviceIdentity? by mutableStateOf(null)
  private var notice by mutableStateOf("")
  private var setup by mutableStateOf(false)
  // Activity callbacks and suspended probe setup have separate generations; Stop invalidates both.
  private var generation = 0
  private var probeToken = 0

  @OptIn(ExperimentalMaterial3Api::class)
  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    enableEdgeToEdge()
    lifecycleScope.launch {
      try { peer = probe.trustedPeer(requireNotNull(intent.getStringExtra("peer"))) }
      catch (_: Exception) { notice = "Select a trusted Mac from Home before configuring connections." }
    }
    setContent {
      val controller = (application as AniCeApplication).sessionController
      val configured = hasConnectionSetup(peer, probe.peerId, probe.fingerprint)
      val connected = controller.state == io.github.anisharyal09.anice.infrastructure.session.ConnectionState.SECURED &&
        hasConnectionSetup(peer, controller.selected?.deviceId, controller.selected?.fingerprint)
      val policyStatus = probe.status
      var showEvents by remember { mutableStateOf(false) }
      val permissions = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { result ->
        notice = if (result.values.all { it }) "Permission granted. Enable automatic connection." else "Bluetooth access is required; manual connections remain available."
      }
      val association = rememberLauncherForActivityResult(ActivityResultContracts.StartIntentSenderForResult()) { result ->
        // API 31/32 returns the device here; API 33+ supplies the association through the manager callback.
        if (Build.VERSION.SDK_INT < 33) {
          if (result.resultCode == RESULT_OK) {
            val device = result.data?.getParcelableExtra<BluetoothDevice>(CompanionDeviceManager.EXTRA_DEVICE)
            if (device != null) arm(device.address, -1, generation) else { setup = false; notice = "No device association returned." }
          } else { setup = false; notice = "Association cancelled." }
        } else if (result.resultCode != RESULT_OK) { setup = false; notice = "Association cancelled." }
      }
      AniCeTheme {
        Scaffold(topBar = { TopAppBar(title = { Text("Connection settings") }, navigationIcon = {
          TextButton(onClick = { finish() }) { Text("Back") }
        }) }, contentWindowInsets = WindowInsets.safeDrawing) { padding ->
          Column(Modifier.padding(padding).consumeWindowInsets(padding).fillMaxSize()
            .verticalScroll(rememberScrollState()).padding(24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Text(peer?.deviceName ?: "Trusted Mac", style = MaterialTheme.typography.titleLarge)
            Text("Reconnect to this Mac when nearby. Turn on Connect automatically on your Mac too.",
              style = MaterialTheme.typography.bodyMedium)
            if (!configured && connected)
              Text("First-time setup reconnects through the system association.", style = MaterialTheme.typography.bodySmall)
            Row(Modifier.fillMaxWidth().heightIn(min = 48.dp), verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
              Text("Connect automatically", Modifier.weight(1f))
              Switch(checked = configured && probe.armed, enabled = peer != null && probe.available && !setup, onCheckedChange = { enabled ->
                // Recheck at action time: another settings activity may have changed the selected Mac.
                if (!enabled) {
                  if (hasConnectionSetup(peer, probe.peerId, probe.fingerprint)) { generation++; probe.disable(); notice = "" }
                }
                else if (controller.missingPermissions().isNotEmpty()) permissions.launch(controller.missingPermissions())
                else if (hasConnectionSetup(peer, probe.peerId, probe.fingerprint) && probe.address != null) {
                  setup = true
                  val op = ++generation
                  lifecycleScope.launch {
                    try { probe.resume(); if (op == generation) notice = "" }
                    catch (error: CancellationException) { throw error }
                    catch (_: Exception) { if (op == generation) notice = "Device setup is unavailable. Reset setup, then try again." }
                    finally { if (op == generation) setup = false }
                  }
                } else {
                  // Only one Mac owns automatic setup; explicit replacement retires its old association.
                  if (probe.peerId != null || probe.address != null) probe.stop("Connection setup changed.")
                  controller.cancel()
                  setup = true; notice = "Choose your Mac in the system dialog."
                  val op = ++generation
                  probeToken = probe.beginSetup()
                  val manager = getSystemService(CompanionDeviceManager::class.java)
                  val request = AssociationRequest.Builder().addDeviceFilter(BluetoothLeDeviceFilter.Builder()
                    .setScanFilter(ScanFilter.Builder().setServiceUuid(ParcelUuid(UUID.fromString(BlePayloadCodec.SERVICE_UUID))).build()).build())
                    .setSingleDevice(false).build()
                  val callback = object : CompanionDeviceManager.Callback() {
                    override fun onDeviceFound(sender: IntentSender) = pending(sender)
                    override fun onAssociationPending(sender: IntentSender) = pending(sender)
                    private fun pending(sender: IntentSender) {
                      if (!isDestroyed && op == generation) association.launch(IntentSenderRequest.Builder(sender).build())
                    }
                    override fun onAssociationCreated(info: AssociationInfo) {
                      if (Build.VERSION.SDK_INT < 33) return
                      val address = info.deviceMacAddress?.toString()
                      // A late chooser approval must not survive cancellation or a destroyed activity.
                      if (isDestroyed || op != generation || address == null) manager.disassociate(info.id)
                      else arm(address, info.id, op)
                    }
                    override fun onFailure(error: CharSequence?) {
                      if (op == generation) { setup = false; notice = "Association failed. ${error ?: "Retry from the foreground."}" }
                    }
                  }
                  try {
                    if (Build.VERSION.SDK_INT >= 33) manager.associate(request, mainExecutor, callback)
                    else manager.associate(request, callback, Handler(Looper.getMainLooper()))
                  } catch (_: Exception) { setup = false; notice = "Association is unavailable. Manual connections remain available." }
                }
              })
            }
            if (!probe.available) Text("Automatic connection is awaiting compatibility verification for this build. Manual Connect remains available.",
              style = MaterialTheme.typography.bodySmall)
            Text(notice.ifBlank {
              if (configured) policyStatus
              else if (probe.peerId != null) "Enabling this Mac replaces the other Mac's automatic connection setup."
              else "Automatic connection is off for this Mac."
            }, color = MaterialTheme.colorScheme.onSurfaceVariant)
            if (setup) TextButton(onClick = {
              generation++; setup = false
              if (probe.peerId == null || hasConnectionSetup(peer, probe.peerId, probe.fingerprint)) probe.stop()
              notice = "Setup cancelled."
            }) { Text("Cancel setup") }
            if (configured && probe.address != null) TextButton(onClick = {
              if (hasConnectionSetup(peer, probe.peerId, probe.fingerprint)) { generation++; setup = false; probe.stop(); notice = "" }
            }) { Text("Reset connection setup") }
            if (connected) {
              TextButton(onClick = controller::checkConnection) { Text("Send connection check") }
            }
            if (configured && applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0) TextButton(onClick = { showEvents = !showEvents }) {
              Text(if (showEvents) "Hide diagnostics" else "Show diagnostics")
            }
            if (configured && showEvents) Text(probe.events.ifBlank { "No events yet." }, style = MaterialTheme.typography.bodySmall)
          }
        }
      }
    }
  }

  override fun onStart() {
    super.onStart()
    (application as AniCeApplication).sessionController.foreground(this)
  }

  override fun onStop() {
    super.onStop()
    (application as AniCeApplication).sessionController.background(this, isChangingConfigurations)
  }

  private fun arm(address: String, id: Int, op: Int) {
    lifecycleScope.launch {
      try {
        val target = requireNotNull(peer)
        if (op != generation) return@launch
        probe.arm(target, address, id, probeToken)
        if (op == generation) notice = ""
      } catch (error: CancellationException) { throw error }
      catch (_: Exception) { if (op == generation) notice = "Could not observe this association. Reset setup and retry; manual connections remain available." }
      finally {
        if (op == generation) setup = false
        // A destroyed chooser cannot leave an untracked association authorizing later work.
        if (!probe.armed || op != generation) {
          val manager = getSystemService(CompanionDeviceManager::class.java)
          try { if (Build.VERSION.SDK_INT >= 33 && id >= 0) manager.disassociate(id) else manager.disassociate(address) }
          catch (_: IllegalArgumentException) {} catch (_: SecurityException) {}
        }
      }
    }
  }
}
