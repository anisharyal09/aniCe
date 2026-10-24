// SPDX-License-Identifier: GPL-3.0-or-later
// Owns serialized BLE sessions, native background leases and observable connection state.
package io.github.anisharyal09.anice.infrastructure.connections

import io.github.anisharyal09.anice.infrastructure.session.*
import android.Manifest
import android.annotation.SuppressLint
import android.app.Application
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.content.*
import android.content.pm.PackageManager
import android.location.LocationManager
import android.os.Build
import android.os.SystemClock
import androidx.compose.runtime.*
import androidx.core.content.ContextCompat
import io.github.anisharyal09.anice.AniCeApplication
import io.github.anisharyal09.anice.infrastructure.bluetooth.AndroidGattTransport
import io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity
import io.github.anisharyal09.anice.infrastructure.connections.sessionNotice
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.MutableStateFlow

enum class ConnectionState {
  DISCONNECTED,
  CONNECTING,
  SECURED,
  FAILED,
}

internal fun retainForegroundSession(requested: Boolean, presented: Boolean, state: ConnectionState, renewing: Boolean) =
  requested && presented && state == ConnectionState.SECURED && !renewing

/**
 * Application-scoped connection manager for GATT transport and EDHOC sessions.
 * Preserves active connection state across UI activity transitions.
 */
class SessionController(application: Application) {
  internal data class Progress(val state: ConnectionState, val controls: Boolean?, val renewal: Long?, val checks: Int)
  // Background owners cannot depend on Compose's snapshot apply notifications or an active Recomposer.
  internal val progress = MutableStateFlow(Progress(ConnectionState.DISCONNECTED, null, null, 0))
  private fun publishProgress() { progress.value = Progress(state, controlSupport, renewalReason, receivedChecks) }
  private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
  private var companionOwner: Any? = null
  private val app = application as AniCeApplication
  var state by mutableStateOf(ConnectionState.DISCONNECTED)
    private set

  var status by mutableStateOf("Open Allow connections on your Mac, then connect here.")
    private set

  var selected by mutableStateOf<DeviceIdentity?>(null)
    private set

  var receivedChecks by mutableIntStateOf(0)
    private set
  var controlSupport by mutableStateOf<Boolean?>(null)
    private set
  var renewalReason by mutableStateOf<Long?>(null)
    private set
  var lastFailure: SessionFailure? = null
    private set
  var beforeDisconnect: () -> Unit = {}
  var beforeRequest: (DeviceIdentity) -> Unit = {}
  var radioChanged: (Boolean) -> Unit = {}
  internal var foregroundChanged: () -> Unit = {}
  internal var automaticRecoveryReserved: () -> Boolean = { false }
  internal fun automaticPolicyChanged() = reconcileWorkRecovery()
  private var automaticAttempt = false

  @Volatile private var operation = 0L
  @Volatile private var connection: SessionConnection? = null
  private var input: Channel<ByteArray>? = null
  private var inputBytes = 0
  private var inputCount = 0
  // Both app activities may overlap during navigation; stopping one must not background the other.
  private val presentations = mutableSetOf<Any>()
  internal val foreground get() = presentations.isNotEmpty()
  private var awaitingPermissions = false
  private var workLease = false
  private var pickerLease = false
  private var worker: Job? = null
  private var workRecovery: Job? = null
  private var recoveryPaused = false
  var beforeConnect: () -> Unit = {}
  private var readySignal: CompletableDeferred<Unit>? = null
  private val maintenanceEvents = SessionMaintenance()
  private val transport =
    AndroidGattTransport(
      app,
      {},
      { readySignal?.complete(Unit) },
      { bytes ->
        if (
          inputCount >= 8 ||
            inputBytes + bytes.size > 32768 ||
            input?.trySend(bytes)?.isSuccess != true
        )
          fail("Incoming connection queue was full. Retry.")
        else {
          inputBytes += bytes.size
          inputCount++
        }
      },
      { _, reason ->
        if (state == ConnectionState.SECURED) {
          cancel()
          status = reason?.message ?: "Bluetooth connection ended."
        } else if (state == ConnectionState.CONNECTING) {
          fail(reason?.message ?: "Connection ended. Retry.")
        }
      },
      { _, _ -> },
      trustedSession = true,
      changed = { maintenanceEvents.request(); scope.launch { app.features.capacityAvailable("ble") } },
    )
  private val radio =
    object : BroadcastReceiver() {
      override fun onReceive(context: Context?, intent: Intent?) {
        if (
          (intent?.action == Intent.ACTION_SCREEN_OFF && companionOwner == null && !workLease && !pickerLease) ||
            (intent?.action == BluetoothAdapter.ACTION_STATE_CHANGED &&
              intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, -1) != BluetoothAdapter.STATE_ON)
        )
          cancel()
        if (intent?.action == BluetoothAdapter.ACTION_STATE_CHANGED)
          radioChanged(intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, -1) == BluetoothAdapter.STATE_ON)
      }
    }

  init {
    ContextCompat.registerReceiver(
      app,
      radio,
      IntentFilter().apply {
        addAction(Intent.ACTION_SCREEN_OFF)
        addAction(BluetoothAdapter.ACTION_STATE_CHANGED)
      },
      ContextCompat.RECEIVER_EXPORTED,
    )
  }

  fun missingPermissions(): Array<String> =
    (if (Build.VERSION.SDK_INT >= 31)
        listOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
      else listOf(Manifest.permission.ACCESS_FINE_LOCATION))
      .filter { ContextCompat.checkSelfPermission(app, it) != PackageManager.PERMISSION_GRANTED }
      .toTypedArray()

  fun request(peer: DeviceIdentity) {
    if (!app.sessionPeers.permits(peer)) return
    selected = peer
    recoveryPaused = false
    if (missingPermissions().isNotEmpty()) {
      awaitingPermissions = true
      status = "Allow Bluetooth access to connect."
      return
    }
    beforeRequest(peer)
    connect(peer)
  }

  fun permissionReturned() {
    awaitingPermissions = false
    selected?.let {
      if (missingPermissions().isEmpty()) { beforeRequest(it); connect(it) }
      else fail("Bluetooth access is needed. Allow it in app settings, then retry.")
    }
  }

  @SuppressLint("MissingPermission")
  fun connect(peer: DeviceIdentity, candidate: BluetoothDevice? = null, automatic: Boolean = false) {
    if (!foreground && companionOwner == null && !workLease) return
    if (!app.sessionPeers.permits(peer)) return
    if (selected?.deviceId == peer.deviceId && selected?.fingerprint == peer.fingerprint && selected?.publicKey == peer.publicKey &&
        (state == ConnectionState.CONNECTING || state == ConnectionState.SECURED)) {
      if (automatic) {
        automaticAttempt = true
        connection?.enableRenewal()
      }
      return
    }
    cancel()
    lastFailure = null
    automaticAttempt = automatic
    beforeConnect()
    selected = peer
    if (missingPermissions().isNotEmpty()) {
      fail("Allow Bluetooth access in app settings, then retry.")
      return
    }
    try {
      if (app.getSystemService(BluetoothManager::class.java)?.adapter?.isEnabled != true) {
        fail("Turn on Bluetooth, then retry.")
        return
      }
      if (
        Build.VERSION.SDK_INT <= 30 &&
          app.getSystemService(LocationManager::class.java)?.isLocationEnabled != true
      ) {
        fail("Turn on location services for nearby scanning, then retry.")
        return
      }
    } catch (_: SecurityException) {
      fail("Bluetooth permission changed. Allow access and retry.")
      return
    }
    state = ConnectionState.CONNECTING
    status = "Finding your trusted Mac…"
    receivedChecks = 0
    publishProgress()
    // Every callback belongs to this attempt; cancel/retry invalidates suspended results.
    val op = operation
    input = Channel(8)
    readySignal = CompletableDeferred()
    worker =
      scope.launch {
        try {
          val local = withContext(Dispatchers.IO) { app.identityService.getOrCreateIdentity().identity }
          ensureActive()
          if (!app.sessionPeers.acquire(this@SessionController, peer, local.fingerprint)) {
            fail("Another transport is connected to a different device.")
            return@launch
          }
          val trust = withContext(Dispatchers.IO) { app.trustStore }
          if (candidate == null) transport.startScan(qr = true) else transport.startCandidate(candidate)
          withTimeout(30000) { readySignal?.await() }
          if (op != operation) return@launch
          val handshake = SessionHandshakeEngine.initiator(app.identityService, trust, peer, SystemClock::elapsedRealtime)
          if (op != operation) {
            handshake.close()
            return@launch
          }
          val engine =
            SessionConnection(
              handshake,
              false,
              { bytes ->
                withContext(Dispatchers.Main.immediate) {
                  op == operation && transport.hasCapacity(bytes)
                }
              },
              { bytes ->
                if (op != operation) throw SessionException(SessionFailure.CANCELLED)
                else transport.submit(bytes)
              },
              { bytes ->
                withContext(Dispatchers.Main.immediate) {
                  if (op == operation && app.features.handle("ble", channelToken, bytes) == DataHandling.UNRECOGNIZED && bytes.contentEquals(CHECK)) {
                    receivedChecks++
                    status = "Connection check received."
                    publishProgress()
                  }
                }
              },
              {
                withContext(Dispatchers.Main.immediate) {
                  if (op == operation) {
                    android.util.Log.i("aniCe-ble", "secured operation=$op token=$channelToken")
                    state = ConnectionState.SECURED
                    publishChannel()
                    status = ""
                    publishProgress()
                  }
                }
              },
              controls = true,
              // Include deep sleep: OS suspension must not extend record lifetime or PONG deadlines.
              now = { SystemClock.elapsedRealtime() },
              renew = automaticAttempt,
              changed = { maintenanceEvents.request(); scope.launch { app.features.capacityAvailable("ble") } },
            )
          connection = engine
          launch {
            var controlWork: Job? = null
            try {
              while (isActive && op == operation) {
                val due = listOfNotNull(engine.nextDeadline(controlWork?.isActive != true), transport.nextDeadline).minOrNull()
                val requested = maintenanceEvents.await(due, SystemClock::elapsedRealtime)
                if (op != operation) break
                transport.tick()
                engine.checkDeadlines()
                if (requested) {
                  if (controlWork?.isActive == true) maintenanceEvents.deferWork()
                  else controlWork = launch {
                    try {
                      withContext(Dispatchers.IO) { engine.tick() }
                      if (op != operation) return@launch
                      controlSupport = engine.controlSupport
                      renewalReason = engine.renewalReason
                      publishProgress()
                      if (renewalReason != null && !automaticAttempt) {
                        this@SessionController.cancel("This session needs a fresh connection. Connect again.")
                      }
                    } catch (e: CancellationException) { throw e }
                    catch (e: Exception) { if (op == operation) finish(e, engine) }
                  }.also { work -> work.invokeOnCompletion { maintenanceEvents.resnapshot() } }
                }
              }
            } catch (e: CancellationException) {
              throw e
            } catch (e: Exception) {
              if (op == operation) finish(e, engine)
            }
          }
          engine.start()
          val queue = input ?: return@launch
          for (bytes in queue) {
            if (op != operation) break
            withContext(Dispatchers.IO) { engine.receive(bytes) }
            if (op != operation) break
            inputBytes -= bytes.size
            inputCount--
            if (engine.isClosed) {
              // CoroutineScope.cancel(String) only stops this worker; retire the controller and publish state.
              this@SessionController.cancel("Your Mac ended the connection.")
              break
            }
          }
        } catch (e: TimeoutCancellationException) {
          if (op == operation) fail("Bluetooth setup timed out. Retry the connection.")
        } catch (e: CancellationException) {
          throw e
        } catch (e: Exception) {
          if (op == operation) finish(e, connection)
        }
      }
  }

  internal fun securityInvalidated() {
    recoveryPaused = true
    workRecovery?.cancel(); workRecovery = null
    // Retire keys synchronously even when the mutation originates outside a presentation.
    val op = operation
    connection?.retire()
    scope.launch { if (op == operation) this@SessionController.cancel("Trust or identity changed. Connect again.") }
  }

  fun checkConnection() {
    if (state != ConnectionState.SECURED || renewalReason != null) return
    val op = operation
    val engine = connection ?: return
    scope.launch {
      try {
        engine.sendData(CHECK)
        if (op == operation) status = "Connection check sent."
      } catch (_: SessionBackpressure) {
        if (op == operation) status = "Connection is busy. Try again."
      } catch (e: Exception) {
        if (op == operation) finish(e, engine)
      }
    }
  }

  fun disconnect() {
    recoveryPaused = true
    workRecovery?.cancel(); workRecovery = null
    beforeDisconnect()
    val engine = connection
    val op = operation
    state = ConnectionState.DISCONNECTED
    controlSupport = null
    status = "Disconnecting…"
    publishProgress()
    scope.launch {
      // Peer-close submission is bounded; synchronous retirement remains necessary if it stalls.
      withTimeoutOrNull(2000) {
        try {
          engine?.disconnect()
        } catch (_: Exception) {}
      }
      if (op == operation) this@SessionController.cancel()
    }
  }

  fun cancel(message: String = "Open Allow connections on your Mac to reconnect.") {
    app.features.retired("ble")
    // Retire access synchronously; cleanup cannot rely on a scope that may be clearing.
    operation++
    controlSupport = null
    renewalReason = null
    input?.close()
    input = null
    inputBytes = 0
    inputCount = 0
    readySignal?.cancel()
    readySignal = null
    transport.close()
    worker?.cancel()
    worker = null
    val old = connection
    connection = null
    old?.retire()
    app.sessionPeers.release(this)
    scope.launch(Dispatchers.IO) { old?.close() }
    state = ConnectionState.DISCONNECTED
    // Publish terminal feedback with state; a resumed retry may immediately replace both.
    status = message
    publishProgress()
    reconcileWorkRecovery()
  }

  private fun finish(error: Exception, engine: SessionConnection?) {
    android.util.Log.i("aniCe-ble", "session ended type=${error.javaClass.simpleName} reason=${(error as? SessionException)?.reason} state=$state expiry=${engine?.expiration} peerClosed=${engine?.closedByPeer}")
    val notice =
      sessionNotice(
        (error as? SessionException)?.reason,
        engine?.expiration,
        engine?.closedByPeer == true,
        state == ConnectionState.SECURED,
      )
    cancel()
    lastFailure = (error as? SessionException)?.reason
    state = notice.state
    status = if (error is java.io.IOException) error.message ?: notice.text else notice.text
    publishProgress()
  }

  private fun fail(reason: String) {
    cancel()
    state = ConnectionState.FAILED
    status = reason
    publishProgress()
  }

  suspend fun retireForRenewal() {
    val engine = connection ?: return
    val op = operation
    state = ConnectionState.CONNECTING
    status = "Renewing connection…"
    publishProgress()
    try {
      withTimeoutOrNull(2000) { withContext(Dispatchers.IO) { engine.disconnect() } }
    } catch (error: CancellationException) {
      throw error
    } catch (_: Exception) {
      // A failed close submission still retires this channel; the owned retry loop starts fresh.
    } finally {
      // Stop/cancellation wins over renewal; a retired operation cannot publish another attempt.
      if (op == operation) cancel()
      withContext(NonCancellable + Dispatchers.IO) { engine.close() }
    }
  }

  fun adoptAutomatic(peer: DeviceIdentity): Boolean {
    if ((state != ConnectionState.SECURED && state != ConnectionState.CONNECTING) ||
      (!hasCompanionOwner && !foreground && !workLease) || selected?.deviceId != peer.deviceId ||
      selected?.fingerprint != peer.fingerprint || selected?.publicKey != peer.publicKey) return false
    automaticAttempt = true
    connection?.enableRenewal()
    return true
  }

  fun updateWorkLease(approved: Boolean, picking: Boolean) {
    val withdrawing = workLease || pickerLease
    workLease = approved
    pickerLease = picking && state == ConnectionState.SECURED
    if (withdrawing && !foreground && companionOwner == null && !workLease && !pickerLease) cancel()
    reconcileWorkRecovery()
  }

  private fun reconcileWorkRecovery() {
    if (!workLease || recoveryPaused || companionOwner != null || automaticRecoveryReserved()) {
      workRecovery?.cancel(); workRecovery = null
      return
    }
    if (workRecovery?.isActive == true) return
    val peer = selected ?: return
    workRecovery = scope.launch(start = CoroutineStart.LAZY) {
      val retry = NearbyRetry()
      while (isActive && workLease && !recoveryPaused && companionOwner == null && selected == peer) {
        if (missingPermissions().isNotEmpty()) return@launch
        if (state != ConnectionState.SECURED && state != ConnectionState.CONNECTING) connect(peer, automatic = true)
        var authenticated = false
        val result = progress.first {
          if (it.state == ConnectionState.SECURED && !authenticated) { retry.reset(); authenticated = true }
          it.renewal != null || it.state == ConnectionState.FAILED || it.state == ConnectionState.DISCONNECTED
        }
        if (result.renewal != null) { retireForRenewal(); continue }
        delay(retry.next(kotlin.random.Random.nextDouble(-0.1, 0.1)))
      }
    }
    workRecovery?.start()
  }

  fun onWorkServiceStopped() {
    if (!workLease) return
    workLease = false
    reconcileWorkRecovery()
    if (!foreground && companionOwner == null && !pickerLease) cancel("Background transfer ownership ended.")
  }

  fun foreground(presentation: Any = this) {
    val previous = foreground
    presentations.add(presentation)
    if (!previous) foregroundChanged()
  }

  fun background(presentation: Any = this, changingConfigurations: Boolean = false) {
    val previous = foreground
    presentations.remove(presentation)
    if (previous && !foreground) foregroundChanged()
    // The system permission dialog temporarily backgrounds the app during explicit setup.
    if (!foreground && !changingConfigurations && !awaitingPermissions && companionOwner == null && !workLease && !pickerLease) cancel()
  }

  fun acquireCompanion(owner: Any) {
    check(companionOwner == null || companionOwner === owner)
    companionOwner = owner
    reconcileWorkRecovery()
    companionOwnershipChanged(true)
  }

  fun releaseCompanion(owner: Any, preserveForegroundSession: Boolean = false) {
    if (companionOwner !== owner) return
    companionOwner = null
    companionOwnershipChanged(false)
    if (retainForegroundSession(preserveForegroundSession || workLease || pickerLease, foreground || workLease || pickerLease, state, renewalReason != null)) {
      automaticAttempt = false
      connection?.disableRenewal()
    } else cancel()
    reconcileWorkRecovery()
  }

  internal fun releaseForegroundAutomatic(preserve: Boolean) {
    if (!automaticAttempt || companionOwner != null) return
    if (retainForegroundSession(preserve || workLease || pickerLease, foreground || workLease || pickerLease, state, renewalReason != null)) {
      automaticAttempt = false
      connection?.disableRenewal()
    } else cancel()
  }

  fun presentationCleared() {
    beforeConnect = {}
    if (!foreground && companionOwner == null && !workLease && !pickerLease) cancel()
  }

  var companionOwnershipChanged: (Boolean)->Unit = {}
  val hasCompanionOwner get() = companionOwner != null


    private val channelToken get() = "${operation}-${System.identityHashCode(connection)}"
    private fun publishChannel() {
        val token=channelToken
        val peer=selected ?: return
        app.features.available(ChannelDescriptor(token,"ble",peer)) { bytes ->
            val engine=connection ?: throw SessionException(SessionFailure.CANCELLED)
            if(token!=channelToken || state!=ConnectionState.SECURED) throw SessionException(SessionFailure.CANCELLED)
            if(!engine.applicationAvailable || transport.hasCapacity(bytes.size+31) != true) throw SessionBackpressure()
            try { withContext(Dispatchers.IO) { engine.sendData(bytes) } }
            catch (error: SessionBackpressure) { throw error }
            catch (error: Exception) {
                android.util.Log.i("aniCe-ble", "DATA submission failed type=${error.javaClass.simpleName}", error)
                if (token == channelToken && connection === engine) finish(error, engine)
                throw error
            }
        }
    }
  companion object {
    val CHECK = "aniCe connection check".toByteArray(Charsets.UTF_8)
  }
}
