// SPDX-License-Identifier: GPL-3.0-or-later
// Owns pinned companion setup, background connection retries and persisted pause policy.
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
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.MutableStateFlow
import io.github.anisharyal09.anice.infrastructure.session.NearbyRetry
import io.github.anisharyal09.anice.infrastructure.session.SessionFailure
import io.github.anisharyal09.anice.R
import java.util.Locale

/** OS-owned nearby connection policy; association locates candidates, EDHOC alone authenticates them. */
@SuppressLint("UseKtx") // commit() success gates the probe; KTX edit(commit=true) discards that result.
internal class CompanionProbe private constructor(private val app: AniCeApplication) {
  private val preferences = app.getSharedPreferences("companion_feasibility", Context.MODE_PRIVATE)
  private val manager get() = app.getSystemService(CompanionDeviceManager::class.java)
  private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
  // Setup tokens are process-local; persisted association locators support a fresh attempt after restart.
  private var setupGeneration = 0
  private var stopping = false
  private var owner: Any? = null
  // Native binding/presence is independent of policy; pause releases work, not this OS fact.
  private var presentOwner: Any? = null
  private var monitor: Job? = null
  private var suspended = false
  private val retry = NearbyRetry()
  private val radioReady = MutableStateFlow(false)
  init {
    app.sessionController.beforeDisconnect = { pause() }
    app.sessionController.beforeRequest = { peer ->
      if (armed && peer.deviceId != peerId) pause("Automatic connection is paused for the previously selected Mac.")
      if (available && peerId == peer.deviceId && preferences.getBoolean("automatic", false) && !armed) {
        scope.launch {
          try { resume() }
          catch (error: CancellationException) { throw error }
          catch (_: Exception) { pause("Check device setup before enabling automatic connection again.") }
        }
      }
    }
    app.sessionController.radioChanged = { radioReady.value = it }
  }
  var status by mutableStateOf("Automatic connection is off.")
    private set
  var events by mutableStateOf(preferences.getString("events", "") ?: "")
    private set
  val armed get() = !stopping && available && preferences.getBoolean("armed", false)
    && preferences.getBoolean("automatic", false) && !preferences.getBoolean("paused", false)
  val associationId get() = preferences.getInt("association", -1)
  val address get() = preferences.getString("address", null)
  val peerId get() = preferences.getString("peer", null)
  val fingerprint get() = preferences.getString("fingerprint", null)
  val available get() = Build.VERSION.SDK_INT >= 31 && app.resources.getBoolean(R.bool.companion_probe_supported) &&
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
      .putBoolean("verified", preferences.getBoolean("verified", false) && peerId == peer.deviceId &&
        preferences.getString("fingerprint", null) == peer.fingerprint && this.address == locator && associationId == id)
      .putBoolean("automatic", true).putBoolean("paused", false).putBoolean("armed", true).commit())
    try {
      if (Build.VERSION.SDK_INT >= 36) manager.startObservingDevicePresence(
        ObservingDevicePresenceRequest.Builder().setAssociationId(id).build())
      else if (Build.VERSION.SDK_INT >= 31) manager.startObservingDevicePresence(locator)
      else error("Companion presence requires Android 12 or later")
      record("observation registered; authentication pending")
      status = "Waiting nearby."
      presentOwner?.let { appeared(it) }
    } catch (error: Exception) {
      stop("Presence observation unavailable. Manual connections remain available.")
      throw error
    }
  }

  /** Only a live system-bound service may retry; disappearance cancels its entire attempt chain. */
  @SuppressLint("MissingPermission")
  fun appeared(service: Any) {
    if (owner != null && owner !== service) return
    presentOwner = service
    if (!armed) return
    owner = service
    if (suspended || monitor?.isActive == true) return
    record("system presence appeared")
    monitor = scope.launch {
      try {
        val controller = app.sessionController
        controller.acquireCompanion(service)
        retry.reset()
        while (isActive && armed && owner === service && !suspended) {
          val peer = trustedPeer(requireNotNull(peerId), requireNotNull(preferences.getString("fingerprint", null)))
          check(controller.missingPermissions().isEmpty()) { "Bluetooth permission unavailable." }
          checkAssociation()
          val adapter = requireNotNull(app.getSystemService(BluetoothManager::class.java).adapter)
          radioReady.value = adapter.isEnabled
          if (!radioReady.value) {
            status = "Waiting for Bluetooth."
            radioReady.first { it }
          }
          val locator = bluetoothAddress(requireNotNull(address))
          while (locator in retry.exclusions(SystemClock.elapsedRealtime())) delay(1000)
          ensureActive()
          if (!armed || owner !== service || suspended) return@launch
          while (!app.sessionPeers.permits(peer)) {
            status = "Waiting for the other device connection to end."
            app.sessionPeers.changes.first { app.sessionPeers.permits(peer) }
            ensureActive()
          }
          if (!controller.adoptAutomatic(peer)) controller.connect(peer, adapter.getRemoteDevice(locator), automatic = true)
          var authenticated = false
          controller.progress.first {
            if (controller.state == ConnectionState.SECURED && !authenticated) {
              // Explicit Connect may have replaced the attempt while this service still owns the lease.
              check(controller.adoptAutomatic(peer)) { "The selected connection changed." }
              authenticated = true
              retry.reset()
              preferences.edit().putBoolean("verified", true).apply()
              record("EDHOC and readiness verified")
            }
            status = when (controller.state) {
              ConnectionState.SECURED -> "Connected."
              ConnectionState.CONNECTING -> "Connecting…"
              else -> "Waiting nearby."
            }
            if (controller.receivedChecks > 0) record("authenticated checks received: ${controller.receivedChecks}")
            controller.controlSupport == false || controller.renewalReason != null ||
              controller.state == ConnectionState.FAILED || controller.state == ConnectionState.DISCONNECTED
          }
          if (!armed || owner !== service || suspended) return@launch
          if (controller.controlSupport == false) {
            pause("Update both apps before enabling automatic connections.")
            return@launch
          }
          if (controller.renewalReason != null) {
            record("fresh-session renewal")
            controller.retireForRenewal()
            continue
          }
          // Revalidate before retry: revoked trust blocks operation; an unexpected candidate does not replace it.
          trustedPeer(peer.deviceId, peer.fingerprint)
          if (controller.lastFailure == SessionFailure.UNTRUSTED_PEER) {
            if (!preferences.getBoolean("verified", false)) {
              stop("That device did not match your trusted Mac. Set up automatic connection again.")
              return@launch
            }
            retry.reject(locator, SystemClock.elapsedRealtime())
          }
          if (authenticated) preferences.edit().putBoolean("verified", true).apply()
          status = "Waiting nearby."
          delay(retry.next(kotlin.random.Random.nextDouble(-0.1, 0.1)))
        }
      } catch (error: CancellationException) { throw error }
      catch (error: Exception) {
        record("automatic operation blocked (${error.javaClass.simpleName})")
        pause("Check trust, Bluetooth permissions and device setup, then enable automatic connection again.")
      }
    }
  }

  private fun checkAssociation() {
    val found = if (Build.VERSION.SDK_INT >= 33) manager.myAssociations.any {
      it.id == associationId && it.deviceMacAddress?.toString()?.let(::bluetoothAddress) == address
    } else manager.associations.any { bluetoothAddress(it) == address }
    check(found) { "Association unavailable." }
  }

  /** Presence/lease loss cancels delayed retries; old services cannot release a newly acquired lease. */
  fun disappeared(service: Any) {
    if (presentOwner === service) presentOwner = null
    if (owner !== service) return
    monitor?.cancel(); monitor = null
    app.sessionController.releaseCompanion(service)
    owner = null
    status = "Waiting nearby."
    record("presence disappeared or service unbound")
  }

  fun suspend() {
    suspended = true
    monitor?.cancel(); monitor = null
    owner?.let { app.sessionController.releaseCompanion(it) }
  }
  fun resumeAfterOperation() {
    suspended = false
    if (armed) owner?.let { appeared(it) }
  }

  /** Pause retains native observation for Resume; disable also stops observation. Both retire session access. */
  fun pause(message: String = "Automatic connection is off.", disable: Boolean = false) {
    setupGeneration++
    stopping = true
    monitor?.cancel(); monitor = null
    owner?.let { app.sessionController.releaseCompanion(it) }; owner = null
    val edit = preferences.edit().putBoolean("paused", true).putBoolean("armed", false)
    if (disable) edit.putBoolean("automatic", false)
    val saved = edit.commit()
    // Pause cancels application work, retaining native facts for Resume. Disable stops observation too.
    if (disable) stopObservation()
    status = if (saved) message else "Stopped, but the setting could not be saved. Retry before enabling."
  }
  fun disable() = pause(disable = true)

  suspend fun resume(resolve: suspend () -> DeviceIdentity = {
    checkAssociation()
    trustedPeer(requireNotNull(peerId), requireNotNull(fingerprint))
  }) {
    check(available)
    // Reserve before any suspension: Stop must invalidate lookup failures as well as successful results.
    val token = beginSetup()
    try {
      val peer = resolve()
      arm(peer, requireNotNull(address), associationId, token)
    } catch (error: Exception) {
      // A retired Resume cannot let its caller pause or overwrite a newer setup.
      if (token != setupGeneration) throw CancellationException("Setup was cancelled.").apply { initCause(error) }
      throw error
    }
  }

  private fun stopObservation() {
    val locator = address ?: return
    if (!available || Build.VERSION.SDK_INT < 31) return
    try {
      if (Build.VERSION.SDK_INT >= 36 && associationId >= 0) manager.stopObservingDevicePresence(
        ObservingDevicePresenceRequest.Builder().setAssociationId(associationId).build())
      else manager.stopObservingDevicePresence(locator)
    } catch (_: DeviceNotAssociatedException) { record("association absent") }
    catch (_: IllegalArgumentException) { record("association absent") }
    catch (_: SecurityException) { record("observation permission unavailable") }
  }

  /** Stop invalidates chooser results, retires keys, then removes only this probe's OS association. */
  fun stop(message: String = "Stopped. The probe association has been removed.") {
    setupGeneration++
    suspended = false
    presentOwner = null
    val oldAddress = address
    val oldId = associationId
    // Retire application access before disk work: a failed preference write cannot keep keys usable.
    stopping = true
    monitor?.cancel(); monitor = null
    owner?.let { app.sessionController.releaseCompanion(it) }; owner = null
    val saved = preferences.edit().putBoolean("armed", false).remove("peer").remove("fingerprint")
      .remove("local").remove("address").remove("association").remove("automatic").remove("paused").remove("verified").commit()
    if (oldAddress != null && available && Build.VERSION.SDK_INT >= 31) {
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
