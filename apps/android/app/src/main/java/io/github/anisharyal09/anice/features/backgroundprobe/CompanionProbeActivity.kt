// SPDX-License-Identifier: GPL-3.0-or-later
// Presents device-scoped automatic connection settings and the native association chooser.
@file:Suppress("DEPRECATION") // API 31/32 association results use EXTRA_DEVICE.
package io.github.anisharyal09.anice.features.backgroundprobe
import io.github.anisharyal09.anice.infrastructure.connections.displayName

import io.github.anisharyal09.anice.infrastructure.connections.CompanionProbe
import android.bluetooth.BluetoothDevice
import android.bluetooth.le.ScanFilter
import android.companion.*
import android.content.IntentSender
import android.content.Context
import android.content.Intent
import android.os.*
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.compose.BackHandler
import androidx.activity.result.IntentSenderRequest
import androidx.activity.result.contract.ActivityResultContracts
import io.github.anisharyal09.anice.ui.AutomaticConnectionToggle
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import io.github.anisharyal09.anice.R
import androidx.compose.ui.unit.dp
import androidx.lifecycle.lifecycleScope
import io.github.anisharyal09.anice.AniCeApplication
import io.github.anisharyal09.anice.infrastructure.bluetooth.BlePayloadCodec
import io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity
import io.github.anisharyal09.anice.ui.theme.AniCeTheme
import java.util.UUID
import kotlinx.coroutines.*

/** Presentation scope only; association and pinned active trust are revalidated before connection. */
internal fun hasConnectionSetup(peer: DeviceIdentity?, selectedId: String?, selectedFingerprint: String?) =
  peer != null && peer.deviceId == selectedId && peer.fingerprint == selectedFingerprint

internal fun automaticSetupReady(peer: DeviceIdentity?, available: Boolean, busy: Boolean) =
  peer != null && available && !busy

// Application IDs gain preview suffixes; compiled activity classes retain the Kotlin namespace.
internal fun companionSetupIntent(context: Context, peerId: String, enable: Boolean = false) =
  Intent(context, CompanionProbeActivity::class.java).putExtra("peer", peerId).putExtra("enable", enable)

internal fun quickCompanionSetupIntent(context: Context, peerId: String) =
  companionSetupIntent(context, peerId, enable = true).putExtra("quick", true)

/** Native device-scoped setup; the system chooser grants ownership, never peer authentication. */
class CompanionProbeActivity : ComponentActivity() {
  private val probe get() = CompanionProbe.get(this)
  private var peer: DeviceIdentity? by mutableStateOf(null)
  private var notice by mutableStateOf("")
  private var setup by mutableStateOf(false)
  // Activity callbacks and suspended probe setup have separate generations; Stop invalidates both.
  private var generation = 0
  private var probeToken = -1
  private var chooserGeneration: Int? = null
  private var setupWork: Job? = null
  private var setupExpiry: Job? = null
  private var setupTarget: io.github.anisharyal09.anice.infrastructure.connections.CompanionSetupTarget? = null
  private val quick get() = intent.getBooleanExtra("quick", false)

  @OptIn(ExperimentalMaterial3Api::class)
  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    enableEdgeToEdge()
    lifecycleScope.launch {
      try { peer = probe.trustedPeer(requireNotNull(intent.getStringExtra("peer"))) }
      catch (error: CancellationException) { throw error }
      catch (_: Exception) {
        if (quick) setupFailed("Select a trusted Mac in Devices before enabling auto-reconnect.", generation)
        else notice = "Select a trusted Mac in Devices before configuring connections."
      }
    }
    setContent {
      val controller = (application as AniCeApplication).sessionController
      val configured = hasConnectionSetup(peer, probe.peerId, probe.fingerprint)
      val connected = controller.state == io.github.anisharyal09.anice.infrastructure.connections.ConnectionState.SECURED &&
        hasConnectionSetup(peer, controller.selected?.deviceId, controller.selected?.fingerprint)
      val policyStatus = probe.status
      var startRequested by rememberSaveable { mutableStateOf(intent.getBooleanExtra("enable", false)) }
      val permissions = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { result ->
        if (result.values.all { it }) startRequested = true
        notice = if (result.values.all { it }) "Permission granted. Enable automatic connection." else "Bluetooth access is required; manual connections remain available."
      }
      val association = rememberLauncherForActivityResult(ActivityResultContracts.StartIntentSenderForResult()) { result ->
        // API 31/32 returns the device here; API 33+ supplies the association through the manager callback.
        if (Build.VERSION.SDK_INT < 33) {
          val op = chooserGeneration
          chooserGeneration = null
          if (result.resultCode == RESULT_OK) {
            val device = result.data?.getParcelableExtra<BluetoothDevice>(CompanionDeviceManager.EXTRA_DEVICE)
            if (op == generation && setup && device != null) arm(device.address, -1, op)
            else {
              if (device != null) removeAssociation(device.address, -1)
              if (op == generation) setupFailed("No device association returned.", op)
            }
          } else if (op == generation) setupFailed("Auto-reconnect wasn't enabled. Your devices are still paired.", op)
        } else if (result.resultCode != RESULT_OK && chooserGeneration == generation) {
          setupFailed("Auto-reconnect wasn't enabled. Your devices are still paired.", generation)
        }
      }
      fun enableAutomatic() {
        if (!automaticSetupReady(peer, probe.available, setup)) return
        if (controller.missingPermissions().isNotEmpty()) permissions.launch(controller.missingPermissions())
        else if (hasConnectionSetup(peer, probe.peerId, probe.fingerprint) && probe.address != null) {
          setup = true
          val op = ++generation
          setupWork = lifecycleScope.launch {
            try {
              probe.resume(stillCurrent = { !isDestroyed && op == generation })
              if (op == generation) { notice = ""; if (intent.getBooleanExtra("enable", false)) finish() }
            }
            catch (error: CancellationException) { throw error }
            catch (_: Exception) { setupFailed("Device setup is unavailable. Reset setup, then try again.", op) }
            finally {
              if (op == generation) setup = false
              if (setupWork === currentCoroutineContext().job) setupWork = null
            }
          }
        } else {
          // Only one Mac owns automatic setup; explicit replacement retires its old association.
          if (probe.peerId != null || probe.address != null) probe.stop("Connection setup changed.")
          setupTarget = peer?.let(controller::beginCompanionSetup)
          if (setupTarget == null && !quick) controller.cancel()
          setup = true; notice = "Preparing auto-reconnect…"
          val op = ++generation
          probeToken = probe.beginSetup()
          setupTarget?.let { target ->
            setupExpiry = lifecycleScope.launch {
              delay((target.expiresAt - SystemClock.elapsedRealtime()).coerceAtLeast(0))
              setupFailed("Auto-reconnect setup expired. Try again in Devices; your devices are still paired.", op)
            }
          }
           val manager = getSystemService(CompanionDeviceManager::class.java)
           val callback = object : CompanionDeviceManager.Callback() {
            override fun onDeviceFound(sender: IntentSender) = pending(sender)
            override fun onAssociationPending(sender: IntentSender) = pending(sender)
            private fun pending(sender: IntentSender) {
              if (!isDestroyed && op == generation && setup && chooserGeneration != op) {
                val target = setupTarget
                if (target != null && !controller.companionSetupCurrent(target)) {
                  setupFailed("Auto-reconnect setup expired. Try again in Devices.", op)
                  return
                }
                chooserGeneration = op
                association.launch(IntentSenderRequest.Builder(sender).build())
              }
            }
            override fun onAssociationCreated(info: AssociationInfo) {
              if (Build.VERSION.SDK_INT < 33) return
              val address = info.deviceMacAddress?.toString()
              // A late chooser approval must not survive cancellation or a destroyed activity.
              if (isDestroyed || op != generation || !setup || address == null || quick && setupTarget == null)
                removeAssociation(address, info.id)
              else arm(address, info.id, op)
            }
            override fun onFailure(error: CharSequence?) {
              setupFailed("Auto-reconnect setup couldn't finish. You can try again in Devices.", op)
            }
          }
          setupWork = lifecycleScope.launch {
            try {
              val target = setupTarget
              if (target != null) {
                check((application as AniCeApplication).companionSetup.prepare(target))
                check(op == generation && controller.companionSetupCurrent(target))
              } else if (quick) error("Connect before quick enrollment")
              val filter = ScanFilter.Builder().setServiceUuid(ParcelUuid(UUID.fromString(BlePayloadCodec.SERVICE_UUID)))
              if (target != null) filter.setDeviceAddress(target.address)
              val request = AssociationRequest.Builder().addDeviceFilter(BluetoothLeDeviceFilter.Builder()
                .setScanFilter(filter.build()).build()).setSingleDevice(target != null).build()
              notice = if (target != null) "Allow auto-reconnect to your verified Mac."
                else "Choose your Mac in Android's approval dialog."
              if (Build.VERSION.SDK_INT >= 33) manager.associate(request, mainExecutor, callback)
              else manager.associate(request, callback, Handler(Looper.getMainLooper()))
            } catch (error: CancellationException) { throw error }
            catch (_: Exception) {
              setupFailed("Your devices are paired. You can enable auto-reconnect later in Devices.", op)
            } finally { if (setupWork === currentCoroutineContext().job) setupWork = null }
          }
        }
      }
      LaunchedEffect(peer, startRequested) {
        if (peer != null && startRequested) {
          startRequested = false
          enableAutomatic()
        }
      }
      BackHandler(setup) {
        setupFailed("Auto-reconnect wasn't enabled. Your devices are still paired.", generation)
        if (!quick) finish()
      }
      AniCeTheme {
        if (quick) {
          Surface(color = MaterialTheme.colorScheme.background, modifier = Modifier.fillMaxSize()) {
            Box(Modifier.fillMaxSize().systemBarsPadding().padding(24.dp), contentAlignment = androidx.compose.ui.Alignment.Center) {
              Column(verticalArrangement = Arrangement.spacedBy(16.dp), modifier = Modifier.widthIn(max = 440.dp)) {
                Icon(painterResource(R.drawable.ic_laptop), contentDescription = null,
                  tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(28.dp))
                Text(peer?.displayName ?: "Your Mac", style = MaterialTheme.typography.titleLarge)
                Text(notice.ifBlank { "Allow Android to reconnect when your Mac is nearby." },
                  style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                if (setup || peer == null && notice.isBlank()) LinearProgressIndicator(Modifier.fillMaxWidth())
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                  TextButton(onClick = { generation++; endQuickSetup(); finish() }) { Text("Not now") }
                  if (!setup && peer != null) OutlinedButton(onClick = ::enableAutomatic,
                    shape = MaterialTheme.shapes.small) { Text("Try again") }
                }
              }
            }
          }
        } else {
        Scaffold(topBar = { TopAppBar(title = { Text("Connection settings") }, navigationIcon = {
          IconButton(onClick = { finish() }) {
            Icon(painterResource(R.drawable.ic_back), contentDescription = stringResource(R.string.back))
          }
        }) }, contentWindowInsets = WindowInsets.safeDrawing) { padding ->
          Column(Modifier.padding(padding).consumeWindowInsets(padding).fillMaxSize()
            .verticalScroll(rememberScrollState()).padding(24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Text(peer?.displayName ?: "Trusted Mac", style = MaterialTheme.typography.titleLarge)
            Text("Reconnect to this Mac when nearby. Turn on Connect automatically on your Mac too.",
              style = MaterialTheme.typography.bodyMedium)
            if (!configured && connected) {
              Text("Android will ask you to allow auto-reconnect to this Mac.", style = MaterialTheme.typography.bodySmall)
            }
            AutomaticConnectionToggle(checked = configured && probe.armed, enabled = peer != null && probe.available && !setup, onCheckedChange = { enabled ->
                // Recheck at action time: another settings activity may have changed the selected Mac.
                if (!enabled) {
                  if (hasConnectionSetup(peer, probe.peerId, probe.fingerprint)) { generation++; probe.disable(); notice = "" }
                }
                else enableAutomatic()
            })
            if (!probe.available) Text("Automatic connection is awaiting compatibility verification for this build. Manual Connect remains available.",
              style = MaterialTheme.typography.bodySmall)
            Text(notice.ifBlank {
              if (configured) policyStatus
              else if (probe.peerId != null) "Enabling this Mac replaces the other Mac's automatic connection setup."
              else "Automatic connection is off for this Mac."
            }, color = MaterialTheme.colorScheme.onSurfaceVariant)
            if (setup) TextButton(shape = MaterialTheme.shapes.small, contentPadding = PaddingValues(horizontal = 10.dp, vertical = 4.dp), onClick = {
              generation++; setup = false
              endQuickSetup()
              if (probe.peerId == null || hasConnectionSetup(peer, probe.peerId, probe.fingerprint)) probe.stop()
              notice = "Setup cancelled."
            }) { Text("Cancel setup") }
            if (configured && probe.address != null) TextButton(shape = MaterialTheme.shapes.small, contentPadding = PaddingValues(horizontal = 10.dp, vertical = 4.dp), onClick = {
              if (hasConnectionSetup(peer, probe.peerId, probe.fingerprint)) {
                generation++; setup = false; endQuickSetup(); probe.stop(); notice = ""
              }
            }) { Text("Reset connection setup") }

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
    (application as AniCeApplication).clipboard.focus(false, this)
    val app = application as AniCeApplication
    app.nowPlaying.background(this, isChangingConfigurations)
    app.sessionController.background(this, isChangingConfigurations)
    app.lanSessionController.background(this, isChangingConfigurations)
  }

  private fun arm(address: String, id: Int, op: Int) {
    lifecycleScope.launch {
      try {
        val target = requireNotNull(peer)
        if (op != generation) return@launch
        if (quick) check(setupTarget != null)
        setupTarget?.let { expected ->
          check(address.equals(expected.address, ignoreCase = true) &&
            (application as AniCeApplication).sessionController.companionSetupCurrent(expected))
        }
        val expected = setupTarget
        probe.arm(target, address, id, probeToken, stillCurrent = {
          !isDestroyed && op == generation && (!quick || expected != null) &&
            (expected == null || (application as AniCeApplication).sessionController.companionSetupCurrent(expected))
        })
        if (op == generation) { notice = ""; if (intent.getBooleanExtra("enable", false)) finish() }
      } catch (error: CancellationException) { throw error }
      catch (_: Exception) { setupFailed("Auto-reconnect couldn't be enabled. Try again in Devices; your devices are still paired.", op) }
      finally {
        endQuickSetup(op)
        if (op == generation) setup = false
        // A destroyed chooser cannot leave an untracked association authorizing later work.
        removeAssociation(address, id)
      }
    }
  }
  private fun endQuickSetup(op: Int = generation) {
    if (op != generation) return
    setupWork?.cancel(); setupWork = null
    setupExpiry?.cancel(); setupExpiry = null
    chooserGeneration = null
    probe.cancelSetup(probeToken)
    probeToken = -1
    val app = application as AniCeApplication
    setupTarget?.let {
      app.companionSetup.finish(it)
      app.sessionController.endCompanionSetup(it)
    }
    setupTarget = null
  }
  private fun setupFailed(message: String, op: Int) {
    if (op != generation || isDestroyed) return
    generation++
    endQuickSetup()
    setup = false
    notice = message
    if (quick) {
      android.widget.Toast.makeText(this, message, android.widget.Toast.LENGTH_LONG).show()
      finish()
    }
  }
  private fun removeAssociation(address: String?, id: Int) {
    // Never remove a successfully armed relationship or one adopted by a newer setup.
    val tracked = if (Build.VERSION.SDK_INT >= 33 && id >= 0) probe.associationId == id &&
      address != null && address.equals(probe.address, ignoreCase = true)
    else address != null && address.equals(probe.address, ignoreCase = true)
    if (tracked) return
    val manager = getSystemService(CompanionDeviceManager::class.java)
    try {
      if (Build.VERSION.SDK_INT >= 33 && id >= 0) manager.disassociate(id)
      else if (address != null) manager.disassociate(address)
    } catch (_: IllegalArgumentException) {} catch (_: SecurityException) {}
  }
  override fun onDestroy() {
    generation++
    endQuickSetup()
    super.onDestroy()
  }
}
