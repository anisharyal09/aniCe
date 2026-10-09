// SPDX-License-Identifier: GPL-3.0-or-later
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
import io.github.anisharyal09.anice.infrastructure.bluetooth.BlePayloadCodec
import io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity
import io.github.anisharyal09.anice.ui.theme.AniCeTheme
import java.util.UUID
import kotlinx.coroutines.*

/** Debug activity for testing companion device association and background presence. */
class CompanionProbeActivity : ComponentActivity() {
  private val probe get() = CompanionProbe.get(this)
  private var peer: DeviceIdentity? by mutableStateOf(null)
  private var notice by mutableStateOf("")
  private var setup = false
  // Activity callbacks and suspended probe setup have separate generations; Stop invalidates both.
  private var generation = 0
  private var probeToken = 0

  @OptIn(ExperimentalMaterial3Api::class)
  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    enableEdgeToEdge()
    lifecycleScope.launch {
      try { peer = probe.trustedPeer(requireNotNull(intent.getStringExtra("peer"))) }
      catch (_: Exception) { notice = "Select an active trusted Mac from Home before starting this test." }
    }
    setContent {
      val controller = (application as AniCeApplication).sessionController
      var showEvents by remember { mutableStateOf(false) }
      val permissions = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { result ->
        notice = if (result.values.all { it }) "Permission granted. Tap Associate Mac." else "Bluetooth access is required; manual connections remain available."
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
        Scaffold(topBar = { TopAppBar(title = { Text("Background test") }, navigationIcon = {
          TextButton(onClick = { finish() }) { Text("Back") }
        }) }, contentWindowInsets = WindowInsets.safeDrawing) { padding ->
          Column(Modifier.padding(padding).consumeWindowInsets(padding).fillMaxSize()
            .verticalScroll(rememberScrollState()).padding(24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Text(peer?.deviceName ?: "Trusted Mac", style = MaterialTheme.typography.titleLarge)
            val manualConnected = controller.state == io.github.anisharyal09.anice.infrastructure.session.ConnectionState.SECURED && !controller.hasCompanionOwner
            Text(if (manualConnected) "Your current connection stays active. Start setup will disconnect it to associate your Mac." else "On Mac, reopen Allow connections. Tap Associate Mac below, then select it in Android's dialog.")
            Text("After connection succeeds, try locking the phone or leaving this screen. No ongoing notification is added; the two-minute idle limit still applies.", style = MaterialTheme.typography.bodySmall)
            if (!probe.available) Text("Companion presence is unavailable here. Continue using manual connections.")
            Text(notice.ifBlank { if (manualConnected) controller.status.ifBlank { "Manual connection active." } else probe.status }, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
              Button(enabled = peer != null && probe.available && !probe.armed && !setup, onClick = {
                if (manualConnected) {
                  // Discovery needs the Mac to advertise again; make the disruptive transition explicit.
                  controller.cancel()
                  notice = "Now reopen Allow connections on Mac, then tap Associate Mac."
                } else if (controller.missingPermissions().isNotEmpty()) permissions.launch(controller.missingPermissions())
                else {
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
              }) { Text(if (manualConnected) "Start setup" else "Associate Mac") }
              TextButton(onClick = { generation++; setup = false; probe.stop(); notice = "" }) { Text("Stop test") }
            }
            if (controller.state == io.github.anisharyal09.anice.infrastructure.session.ConnectionState.SECURED) {
              TextButton(onClick = controller::checkConnection) { Text("Send connection check") }
            }
            TextButton(onClick = { showEvents = !showEvents }) {
              Text(if (showEvents) "Hide test events" else "Show test events")
            }
            if (showEvents) Text(probe.events.ifBlank { "No events yet." }, style = MaterialTheme.typography.bodySmall)
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
      catch (_: Exception) { notice = "Could not observe this association. Stop and retry; manual connections remain available." }
      finally {
        setup = false
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
