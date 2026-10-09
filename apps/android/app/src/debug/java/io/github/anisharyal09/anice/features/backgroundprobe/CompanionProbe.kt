// SPDX-License-Identifier: GPL-3.0-or-later
@file:Suppress("DEPRECATION") // Address-based companion APIs are required on Android 12–15.
package io.github.anisharyal09.anice.features.backgroundprobe

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.companion.DeviceNotAssociatedException
import android.companion.CompanionDeviceManager
import android.companion.ObservingDevicePresenceRequest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.SystemClock
import androidx.compose.runtime.*
import io.github.anisharyal09.anice.AniCeApplication
import io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity
import io.github.anisharyal09.anice.infrastructure.session.ConnectionState
import kotlinx.coroutines.*
import java.util.Locale

/** Debug-only OS association experiment for testing background presence. */
@SuppressLint("UseKtx") // commit() success gates the probe; KTX edit(commit=true) discards that result.
internal class CompanionProbe private constructor(private val app: AniCeApplication) {
  private val preferences = app.getSharedPreferences("companion_feasibility", Context.MODE_PRIVATE)
  private val manager get() = app.getSystemService(CompanionDeviceManager::class.java)
  private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
  // Setup tokens are process-local; persisted association locators support a fresh attempt after restart.
  private var setupGeneration = 0
  private var stopping = false
  private var owner: Any? = null
  private var monitor: Job? = null
  var status by mutableStateOf("Not running. Open Allow connections on your Mac before associating.")
    private set
  var events by mutableStateOf(preferences.getString("events", "") ?: "")
    private set
  val armed get() = !stopping && preferences.getBoolean("armed", false)
  val associationId get() = preferences.getInt("association", -1)
  val address get() = preferences.getString("address", null)
  val available get() = Build.VERSION.SDK_INT >= 31 &&
    app.packageManager.hasSystemFeature(PackageManager.FEATURE_COMPANION_DEVICE_SETUP)

  /** Resolve exactly one active record; a restored probe must also match its original local identity. */
  suspend fun trustedPeer(id: String, fingerprint: String? = null): DeviceIdentity = withContext(Dispatchers.IO) {
    val local = app.identityService.getOrCreateIdentity().identity
    val savedLocal = preferences.getString("local", null)
    if (fingerprint != null) check(savedLocal == local.fingerprint) { "Local identity changed. Stop and set up again." }
    app.trustStore.list(local.fingerprint).map { it.peer }.filter {
      it.deviceId == id && (fingerprint == null || it.fingerprint == fingerprint)
    }.single()
  }

  /** A new chooser receives a token that Stop invalidates before any later result can arm observation. */
  fun beginSetup(): Int {
    check(!preferences.getBoolean("armed", false))
    stopping = false
    return ++setupGeneration
  }

  /** Register presence only after active-trust validation; EDHOC authenticates the candidate afterward. */
  suspend fun arm(peer: DeviceIdentity, address: String, id: Int, token: Int) {
    check(token == setupGeneration) { "Setup was cancelled." }
    check(available)
    val locator = bluetoothAddress(address)
    val trusted = trustedPeer(peer.deviceId)
    check(trusted.deviceId == peer.deviceId && trusted.fingerprint == peer.fingerprint && trusted.publicKey == peer.publicKey)
    val local = withContext(Dispatchers.IO) { app.identityService.getOrCreateIdentity().identity }
    // Trust/identity reads suspend: Stop may have invalidated this chooser while they were running.
    check(token == setupGeneration) { "Setup was cancelled." }
    // The address/id locate an OS association only. Authentication still pins the complete peer credential.
    check(preferences.edit().putString("peer", peer.deviceId).putString("fingerprint", peer.fingerprint)
      .putString("local", local.fingerprint).putString("address", locator).putInt("association", id)
      .putBoolean("armed", true).commit())
    try {
      if (Build.VERSION.SDK_INT >= 36) manager.startObservingDevicePresence(
        ObservingDevicePresenceRequest.Builder().setAssociationId(id).build())
      else if (Build.VERSION.SDK_INT >= 31) manager.startObservingDevicePresence(locator)
      else error("Companion presence requires Android 12 or later")
      record("observation registered; authentication pending")
      status = "Waiting for the system to bind the companion service."
    } catch (error: Exception) {
      stop("Presence observation unavailable. Manual connections remain available.")
      throw error
    }
  }

  /** Called from system presence callbacks; duplicate appearances never create a second attempt. */
  @SuppressLint("MissingPermission")
  fun appeared(service: Any) {
    if (!armed || owner != null) return
    owner = service
    record("system presence appeared")
    monitor = scope.launch {
      var step = "trust validation"
      try {
        val peer = trustedPeer(requireNotNull(preferences.getString("peer", null)),
          requireNotNull(preferences.getString("fingerprint", null)))
        if (!armed || owner !== service) return@launch
        val controller = app.sessionController
        step = "Bluetooth permission check"
        check(controller.missingPermissions().isEmpty())
        step = "companion ownership"
        controller.acquireCompanion(service)
        step = "associated Bluetooth device lookup"
        val device = app.getSystemService(BluetoothManager::class.java).adapter.getRemoteDevice(bluetoothAddress(requireNotNull(address)))
        step = "connection submission"
        controller.connect(peer, device)
        var authenticated = false
        // Association/presence is insufficient: success is recorded only after encrypted readiness.
        snapshotFlow { Triple(controller.state, controller.status, controller.receivedChecks) }.collect { (state, text, count) ->
          if (!armed || owner !== service) return@collect
          status = text.ifBlank { "Secured through the OS-bound companion service." }
          when (state) {
            ConnectionState.SECURED -> {
              if (!authenticated) { authenticated = true; record("EDHOC and readiness verified") }
              if (count > 0) record("authenticated checks received: $count")
            }
            ConnectionState.FAILED -> stop("Candidate authentication or transport failed. $text")
            ConnectionState.DISCONNECTED -> if (authenticated) {
              record("session ended: $text")
              status = "Session ended. Reopen Allow connections and restart the probe."
              // No background retry is inferred from a retained subscription or a stale presence event.
              stop(status)
            }
            else -> Unit
          }
        }
      } catch (error: CancellationException) { throw error }
      catch (error: Exception) {
        // Stage/type identifies the failure without exposing exception messages containing peer addresses.
        record("$step failed (${error.javaClass.simpleName})")
        stop("Background test failed during $step (${error.javaClass.simpleName}). Manual connections remain available.")
      }
    }
  }

  /** Release volatile session state while retaining observation for a later system appearance. */
  fun disappeared(service: Any) {
    if (owner !== service) return
    record("system presence disappeared or service unbound")
    monitor?.cancel(); monitor = null
    app.sessionController.releaseCompanion(service)
    owner = null
    status = "Waiting for presence. Reopen Allow connections on your Mac."
  }

  /** Stop invalidates chooser results, retires keys, then removes only this probe's OS association. */
  fun stop(message: String = "Stopped. The probe association has been removed.") {
    setupGeneration++
    val oldAddress = address
    val oldId = associationId
    // Retire application access before disk work: a failed preference write cannot keep keys usable.
    stopping = true
    monitor?.cancel(); monitor = null
    owner?.let { app.sessionController.releaseCompanion(it) }; owner = null
    val saved = preferences.edit().putBoolean("armed", false).remove("peer").remove("fingerprint")
      .remove("local").remove("address").remove("association").commit()
    if (oldAddress != null && available) {
      try {
        if (Build.VERSION.SDK_INT >= 36 && oldId >= 0) manager.stopObservingDevicePresence(
          ObservingDevicePresenceRequest.Builder().setAssociationId(oldId).build())
        else manager.stopObservingDevicePresence(oldAddress)
      } catch (_: DeviceNotAssociatedException) { record("association already absent") }
      catch (_: IllegalArgumentException) { record("association already absent") }
      catch (_: SecurityException) { record("observation permission unavailable") }
      try {
        if (Build.VERSION.SDK_INT >= 33 && oldId >= 0) manager.disassociate(oldId)
        else manager.disassociate(oldAddress)
      } catch (_: IllegalArgumentException) { record("association already removed") }
      catch (_: SecurityException) { record("association cleanup needs system settings") }
    }
    record("probe stopped")
    status = if (saved) message else "Stopped, but the preference could not be saved. Retry Stop before restarting."
  }

  /** Bounded monotonic-time diagnostics contain outcomes, never payloads, keys or transport addresses. */
  fun record(event: String) {
    val rows = (events.lines().filter { it.isNotBlank() } + "${SystemClock.elapsedRealtime()} $event").takeLast(64)
    events = rows.joinToString("\n")
    preferences.edit().putString("events", events).apply()
  }

  companion object {
    /** MacAddress renders lowercase; BluetoothAdapter accepts only uppercase hexadecimal locators. */
    internal fun bluetoothAddress(value: String): String = value.uppercase(Locale.ROOT).also {
      require(BluetoothAdapter.checkBluetoothAddress(it)) { "Invalid association address." }
    }

    @Volatile private var instance: CompanionProbe? = null
    fun get(context: Context): CompanionProbe = synchronized(this) {
      instance ?: CompanionProbe(context.applicationContext as AniCeApplication).also { instance = it }
    }
  }
}
