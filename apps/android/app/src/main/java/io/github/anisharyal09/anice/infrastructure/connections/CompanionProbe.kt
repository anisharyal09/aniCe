// SPDX-License-Identifier: GPL-3.0-or-later
// Owns pinned companion setup, background connection retries and persisted pause policy.
@file:Suppress("DEPRECATION") // Address-based companion APIs are required on Android 12–15.
package io.github.anisharyal09.anice.infrastructure.connections

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.companion.DeviceNotAssociatedException
import android.companion.CompanionDeviceManager
import android.companion.ObservingDevicePresenceRequest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.os.Build
import android.os.SystemClock
import androidx.compose.runtime.*
import androidx.core.content.ContextCompat
import io.github.anisharyal09.anice.AniCeApplication
import io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity
import io.github.anisharyal09.anice.infrastructure.connections.ConnectionState
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.MutableStateFlow
import io.github.anisharyal09.anice.infrastructure.session.SessionFailure
import io.github.anisharyal09.anice.R
import java.util.Locale

/** Foreground or OS-owned nearby connection policy; association locates candidates, EDHOC alone authenticates them. */
@SuppressLint("UseKtx") // commit() success gates the probe; KTX edit(commit=true) discards that result.
internal class CompanionProbe private constructor(
  private val app: AniCeApplication,
  private val preferences: SharedPreferences = app.getSharedPreferences("companion_feasibility", Context.MODE_PRIVATE),
  private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate),
) {
  private val pauseUntilKey = "paused_until"
  private val manager get() = app.getSystemService(CompanionDeviceManager::class.java)
  private val pauseNotice = PauseNoticeTransition(scope)
  // Setup tokens are process-local; persisted association locators support a fresh attempt after restart.
  private var setupGeneration = 0
  private var armedPreference by mutableStateOf(preferences.getBoolean("armed", false)
    && preferences.getBoolean("automatic", false) && !preferences.getBoolean("paused", false))
  private var owner: Any? = null
  // Native binding/presence is independent of policy; pause releases work, not this OS fact.
  private var presentOwner: Any? = null
  private var monitor: Job? = null
  private var connectResume: Job? = null
  private var timedPauseJob: Job? = null
  private var suspended = false
  private var attemptCancelled by mutableStateOf(false)
  private val retry = NearbyRetry()
  private val radioReady = MutableStateFlow(false)
  private val pauseEvents = object : BroadcastReceiver() {
    override fun onReceive(context: Context?, intent: Intent?) { reconcileTimedPause() }
  }
  var status by mutableStateOf("Automatic connection is off.")
    private set
  var connectionPaused by mutableStateOf(preferences.getBoolean("paused", false))
    private set
  var connectionPauseUntil by mutableStateOf(preferences.getLong(pauseUntilKey, 0L).takeIf { it > 0L })
    private set
  var events by mutableStateOf(preferences.getString("events", "") ?: "")
    private set
  init {
    app.sessionController.beforeDisconnect = { pause() }
    app.sessionController.beforeRequest = { peer ->
      pauseNotice.cancel()
      attemptCancelled = false
      app.connectionPause.clear()
      if (armed && peer.deviceId != peerId) pause("Automatic connection is paused for the previously selected Mac.")
      if (available && peerId == peer.deviceId && fingerprint == peer.fingerprint &&
        preferences.getBoolean("automatic", false) && !armed && app.sessionController.missingPermissions().isEmpty()) {
        resumeForExplicitConnect()
      } else if (armed && peerId == peer.deviceId && fingerprint == peer.fingerprint) {
        presentOwner?.let { appeared(it) } ?: reconcileForeground()
      }
    }
    app.sessionController.beforeCancelAttempt = {
      // Cancel also fences a Resume lookup already suspended by explicit Connect.
      setupGeneration++
      cancelConnectResume()
      attemptCancelled = true
      monitor?.cancel(); monitor = null
      status = "Connection canceled. Auto connect remains enabled for the next connection event."
    }
    app.sessionController.radioChanged = { radioReady.value = it }
    app.sessionController.foregroundChanged = {
      if (app.sessionController.foreground) attemptCancelled = false
      reconcileForeground()
    }
    app.sessionController.automaticRecoveryReserved = { suspended || attemptCancelled || (monitor?.isActive == true && armed) }
    ContextCompat.registerReceiver(app, pauseEvents, IntentFilter().apply {
      addAction(Intent.ACTION_TIME_CHANGED)
      addAction(Intent.ACTION_TIMEZONE_CHANGED)
      addAction(Intent.ACTION_SCREEN_ON)
    }, ContextCompat.RECEIVER_NOT_EXPORTED)
    restoreTimedPause()
  }
  val armed get() = available && armedPreference
  val waiting get() = armed && !attemptCancelled
  val associationId get() = preferences.getInt("association", -1)
  val address get() = preferences.getString("address", null)
  val peerId get() = preferences.getString("peer", null)
  val fingerprint get() = preferences.getString("fingerprint", null)
  val automaticEnabled get() = preferences.getBoolean("automatic", false)
  val pauseStatus: String? get() = if (!connectionPaused || !automaticEnabled) null else connectionPauseUntil?.let {
    "Paused until ${android.text.format.DateFormat.getTimeFormat(app).format(java.util.Date(it))}"
  } ?: "Paused"
  val available get() = Build.VERSION.SDK_INT >= 31 && app.resources.getBoolean(R.bool.companion_probe_supported) &&
    app.packageManager.hasSystemFeature(PackageManager.FEATURE_COMPANION_DEVICE_SETUP)
  init { reconcileForeground() }

  private fun cancelConnectResume() {
    connectResume?.cancel(); connectResume = null
  }

  private fun resumeForExplicitConnect() {
    if (connectResume?.isActive == true) return
    val generation = setupGeneration
    val work = scope.launch(start = CoroutineStart.LAZY) {
      try {
        if (generation != setupGeneration || attemptCancelled) return@launch
        resume()
        ensureActive()
        if (!attemptCancelled) app.lanSessionController.resumeAfterTimedPause()
      } catch (error: CancellationException) { throw error }
      catch (_: Exception) { pause("Check device setup before enabling automatic connection again.") }
      finally { if (connectResume === currentCoroutineContext().job) connectResume = null }
    }
    // Publish ownership before dispatch: Cancel must invalidate even a not-yet-started Resume.
    connectResume = work
    work.start()
  }

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
    pauseNotice.cancel()
    armedPreference = false
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
      .putBoolean("automatic", true).putBoolean("paused", false).putBoolean("armed", true)
      .remove(pauseUntilKey).commit())
    timedPauseJob?.cancel(); timedPauseJob = null
    connectionPaused = false
    connectionPauseUntil = null
    attemptCancelled = false
    retry.reset()
    armedPreference = true
    try {
      if (Build.VERSION.SDK_INT >= 36) manager.startObservingDevicePresence(
        ObservingDevicePresenceRequest.Builder().setAssociationId(id).build())
      else if (Build.VERSION.SDK_INT >= 31) manager.startObservingDevicePresence(locator)
      else error("Companion presence requires Android 12 or later")
      record("observation registered; authentication pending")
      status = "Waiting nearby."
      presentOwner?.let { appeared(it) } ?: reconcileForeground()
    } catch (error: Exception) {
      stop("Presence observation unavailable. Manual connections remain available.")
      throw error
    }
  }

  /** Native presence owns background retries; a foreground presentation can retain the same recovery policy. */
  @SuppressLint("MissingPermission")
  fun appeared(service: Any) {
    if (owner != null && owner !== service) return
    val newPresence = presentOwner !== service
    presentOwner = service
    if (newPresence) attemptCancelled = false
    reconcileTimedPause()
    if (!armed) return
    if (owner == null) { monitor?.cancel(); monitor = null }
    owner = service
    if (suspended || attemptCancelled || monitor?.isActive == true) return
    startMonitor(service)
  }

  private fun eligible(service: Any?): Boolean = armed && !suspended && !attemptCancelled &&
    if (service == null) owner == null && app.sessionController.foreground else owner === service

  private fun startMonitor(service: Any?) {
    record(if (service == null) "foreground recovery started" else "system presence appeared")
    monitor = scope.launch(start = CoroutineStart.LAZY) {
      try {
        val controller = app.sessionController
        if (service != null) controller.acquireCompanion(service)
        // Ownership handoffs retain failures; stable readiness or explicit setup resets history.
        while (isActive && eligible(service)) {
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
          delay(retry.exclusionDelay(locator, SystemClock.elapsedRealtime()))
          ensureActive()
          if (!eligible(service)) return@launch
          while (!app.sessionPeers.permits(peer)) {
            status = "Waiting for the other device connection to end."
            app.sessionPeers.changes.first { app.sessionPeers.permits(peer) }
            ensureActive()
          }
          var rediscover = false
          if (!controller.adoptAutomatic(peer)) {
            rediscover = retry.claimRediscovery()
            if (rediscover) record("rediscovering after repeated Bluetooth failures")
            controller.connect(peer, if (rediscover) null else adapter.getRemoteDevice(locator), automatic = true)
          }
          var authenticated = false
          var stable: Job? = null
          try { controller.progress.first {
            if (controller.state == ConnectionState.SECURED && !authenticated) {
              // Explicit Connect may have replaced the attempt while this service still owns the lease.
              check(controller.adoptAutomatic(peer)) { "The selected connection changed." }
              authenticated = true
              retry.secured(SystemClock.elapsedRealtime())
              stable = launch {
                delay(15_000)
                if (eligible(service) && controller.state == ConnectionState.SECURED) retry.tick(SystemClock.elapsedRealtime())
              }
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
          } finally { stable?.cancel(); retry.retired() }
          if (!eligible(service)) return@launch
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
            if (!rediscover && !preferences.getBoolean("verified", false)) {
              stop("That device did not match your trusted Mac. Set up automatic connection again.")
              return@launch
            }
            if (!rediscover) retry.reject(locator, SystemClock.elapsedRealtime())
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
    monitor?.start()
    app.sessionController.automaticPolicyChanged()
  }

  private fun reconcileForeground() {
    reconcileTimedPause()
    owner?.let {
      // A new foreground event can rearm a retained native owner without another presence callback.
      if (eligible(it) && monitor?.isActive != true) startMonitor(it)
      return
    }
    if (!armed || suspended || attemptCancelled || !app.sessionController.foreground) {
      monitor?.cancel(); monitor = null
      app.sessionController.automaticPolicyChanged()
      return
    }
    if (monitor?.isActive != true) startMonitor(null)
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
    reconcileForeground()
  }

  fun suspend() {
    suspended = true
    app.sessionController.automaticPolicyChanged()
    monitor?.cancel(); monitor = null
    owner?.let { app.sessionController.releaseCompanion(it) }
  }
  fun resumeAfterOperation() {
    suspended = false
    attemptCancelled = false
    if (armed) { owner?.let { appeared(it) } ?: reconcileForeground() }
    app.sessionController.automaticPolicyChanged()
  }

  /** Pause retains native observation for Resume; disable also stops observation. Disable may retain a secured foreground session as manual work. */
  fun pause(message: String = "Automatic connection is off.", disable: Boolean = false, until: Long? = null,
    preserveNoticeChannel: Boolean = false): Boolean {
    pauseNotice.cancel()
    setupGeneration++
    cancelConnectResume()
    timedPauseJob?.cancel(); timedPauseJob = null
    val foregroundOwned = owner == null && monitor?.isActive == true
    armedPreference = false
    connectionPaused = true
    connectionPauseUntil = if (disable) null else until
    monitor?.cancel(); monitor = null
    owner?.let { app.sessionController.releaseCompanion(it, preserveForegroundSession = disable || preserveNoticeChannel) }; owner = null
    if (foregroundOwned) app.sessionController.releaseForegroundAutomatic(disable || preserveNoticeChannel)
    val edit = preferences.edit().putBoolean("paused", true).putBoolean("armed", false)
    if (disable || until == null) edit.remove(pauseUntilKey) else edit.putLong(pauseUntilKey, until)
    if (disable) {
      edit.putBoolean("automatic", false).remove(pauseUntilKey)
    }
    val saved = edit.commit()
    // Pause cancels application work, retaining native facts for Resume. Disable stops observation too.
    if (disable) stopObservation()
    status = if (saved) message else "Stopped, but the setting could not be saved. Retry before enabling."
    return saved
  }
  fun disable() { pause(disable = true) }

  fun pauseFor(durationMillis: Long?) {
    require(durationMillis == null || durationMillis in 60_000L..2_592_000_000L)
    val until = durationMillis?.let { System.currentTimeMillis() + it }
    val message = until?.let {
      "Paused until ${android.text.format.DateFormat.getTimeFormat(app).format(java.util.Date(it))}"
    } ?: "Paused"
    val retireBluetooth = app.sessionController.preparePause()
    val retireLan = app.lanSessionController.preparePause()
    val saved = pause(message, until = until, preserveNoticeChannel = true)
    pauseNotice.start(announce = { app.connectionPause.announcePause(until ?: 0L) },
      teardown = { retireBluetooth(); retireLan() })
    if (saved) scheduleTimedPauseResume()
  }

  suspend fun resumeNow() {
    cancelConnectResume()
    pauseNotice.cancel()
    timedPauseJob?.cancel(); timedPauseJob = null
    app.connectionPause.clear()
    scope.launch { app.connectionPause.announceResume() }
    resume()
    app.lanSessionController.resumeAfterTimedPause()
  }

  private fun restoreTimedPause() {
    reconcileTimedPause()
  }

  private fun reconcileTimedPause() {
    app.connectionPause.reconcileTime()
    connectionPaused = preferences.getBoolean("paused", false)
    connectionPauseUntil = preferences.getLong(pauseUntilKey, 0L).takeIf { it > 0L }
    val until = connectionPauseUntil ?: return
    if (!connectionPaused) return
    // Handler delays exclude deep sleep; a foreground/presence event must catch up using wall time.
    if (until <= System.currentTimeMillis() || timedPauseJob?.isActive != true) scheduleTimedPauseResume()
  }

  private fun scheduleTimedPauseResume() {
    val expectedUntil = connectionPauseUntil ?: return
    timedPauseJob?.cancel()
    timedPauseJob = scope.launch {
      try {
        while (true) {
          delay((expectedUntil - System.currentTimeMillis()).coerceAtLeast(0L))
          ensureActive()
          if (preferences.getLong(pauseUntilKey, 0L) != expectedUntil || !preferences.getBoolean("paused", false)) return@launch
          if (expectedUntil <= System.currentTimeMillis()) break
        }
        // Consume the elapsed pause before validation can suspend; a newer pause cannot be resumed by this job.
        if (!preferences.edit().putBoolean("paused", false).remove(pauseUntilKey).commit()) {
          status = "Could not end the connection pause. Try Resume now."
          return@launch
        }
        connectionPaused = false
        connectionPauseUntil = null
        app.connectionPause.clear()
        if (automaticEnabled) {
          app.lanSessionController.resumeAfterTimedPause()
          resume()
        } else {
          status = "Automatic connection is off."
        }
      } catch (error: CancellationException) {
        throw error
      } catch (_: Exception) {
        pause("Auto connect could not resume. Check device setup, then try again.")
      } finally {
        if (timedPauseJob === currentCoroutineContext().job) timedPauseJob = null
      }
    }
  }

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
    pauseNotice.cancel()
    setupGeneration++
    cancelConnectResume()
    suspended = false
    timedPauseJob?.cancel(); timedPauseJob = null
    presentOwner = null
    val oldAddress = address
    val oldId = associationId
    // Retire application access before disk work: a failed preference write cannot keep keys usable.
    armedPreference = false
    monitor?.cancel(); monitor = null
    owner?.let { app.sessionController.releaseCompanion(it) }; owner = null
    val saved = preferences.edit().putBoolean("armed", false).remove("peer").remove("fingerprint")
      .remove("local").remove("address").remove("association").remove("automatic").remove("paused")
      .remove(pauseUntilKey).remove("verified").commit()
    connectionPaused = false
    connectionPauseUntil = null
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
    internal val connectionPauseActive get() = instance?.let {
      it.connectionPaused && it.automaticEnabled &&
        (it.connectionPauseUntil == null || requireNotNull(it.connectionPauseUntil) > System.currentTimeMillis())
    } == true
    fun get(context: Context): CompanionProbe = synchronized(this) {
      instance ?: CompanionProbe(context.applicationContext as AniCeApplication).also { instance = it }
    }

    /** Network return can finish an elapsed pause without constructing a probe no owner requested. */
    internal fun reconcileIfPresent() { instance?.reconcileTimedPause() }
  }
}
