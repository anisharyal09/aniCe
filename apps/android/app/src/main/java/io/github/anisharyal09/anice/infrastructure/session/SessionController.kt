// SPDX-License-Identifier: GPL-3.0-or-later
// Owns serialized BLE sessions, native background leases and observable connection state.
package io.github.anisharyal09.anice.infrastructure.session

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
import io.github.anisharyal09.anice.features.session.sessionNotice
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.MutableStateFlow

enum class ConnectionState {
  DISCONNECTED,
  CONNECTING,
  SECURED,
  FAILED,
}

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
  private var automaticAttempt = false

  private var operation = 0L
  private var connection: SessionConnection? = null
  private var input: Channel<ByteArray>? = null
  private var inputBytes = 0
  private var inputCount = 0
  // Both app activities may overlap during navigation; stopping one must not background the other.
  private val presentations = mutableSetOf<Any>()
  internal val foreground get() = presentations.isNotEmpty()
  private var awaitingPermissions = false
  private var worker: Job? = null
  var beforeConnect: () -> Unit = {}
  private var readySignal: CompletableDeferred<Unit>? = null
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
          status = "Bluetooth connection ended. Reopen Allow connections on your Mac."
        } else if (state == ConnectionState.CONNECTING) {
          fail(reason?.message ?: "Connection ended. Retry.")
        }
      },
      { _, _ -> },
      trustedSession = true,
    )
  private val radio =
    object : BroadcastReceiver() {
      override fun onReceive(context: Context?, intent: Intent?) {
        if (
          (intent?.action == Intent.ACTION_SCREEN_OFF && companionOwner == null) ||
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
    selected = peer
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
    if (!foreground && companionOwner == null) return
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
          val trust = withContext(Dispatchers.IO) { app.trustStore }
          if (candidate == null) transport.startScan(qr = true) else transport.startCandidate(candidate)
          withTimeout(30000) { readySignal?.await() }
          if (op != operation) return@launch
          val handshake = SessionHandshakeEngine.initiator(app.identityService, trust, peer)
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
                  if (op == operation && bytes.contentEquals(CHECK)) {
                    receivedChecks++
                    status = "Connection check received."
                    publishProgress()
                  }
                }
              },
              {
                withContext(Dispatchers.Main.immediate) {
                  if (op == operation) {
                    state = ConnectionState.SECURED
                    status = ""
                    publishProgress()
                  }
                }
              },
              controls = true,
              // Include deep sleep: OS suspension must not extend record lifetime or PONG deadlines.
              now = { SystemClock.elapsedRealtime() },
              renew = automatic,
            )
          connection = engine
          var checking = false
          launch {
            while (isActive && op == operation) {
              // Readiness keeps fast maintenance; secured records enforce deadlines on every operation.
              delay(if (state == ConnectionState.SECURED) 1000L else 200L)
              transport.tick()
              if (engine.timedOut()) {
                fail("Secure connection timed out. Retry.")
                break
              }
              if (!checking) {
                checking = true
                launch {
                  try {
                    // Health checks may seal keepalive records; keep native crypto off the UI thread.
                    withContext(Dispatchers.IO) { engine.tick() }
                    if (op == operation) controlSupport = engine.controlSupport
                    if (op == operation) renewalReason = engine.renewalReason
                    if (op == operation) publishProgress()
                    if (op == operation && renewalReason != null && !automaticAttempt) {
                      this@SessionController.cancel("This session needs a fresh connection. Connect again.")
                    }
                  } catch (e: CancellationException) {
                    throw e
                  } catch (e: Exception) {
                    if (op == operation) finish(e, engine)
                  } finally {
                    checking = false
                  }
                }
              }
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
        } catch (e: CancellationException) {
          throw e
        } catch (e: Exception) {
          if (op == operation) finish(e, connection)
        }
      }
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
    scope.launch(Dispatchers.IO) { old?.close() }
    state = ConnectionState.DISCONNECTED
    // Publish terminal feedback with state; a resumed retry may immediately replace both.
    status = message
    publishProgress()
  }

  private fun finish(error: Exception, engine: SessionConnection?) {
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
    status = notice.text
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
    if (state != ConnectionState.SECURED || !hasCompanionOwner || selected?.deviceId != peer.deviceId ||
      selected?.fingerprint != peer.fingerprint || selected?.publicKey != peer.publicKey) return false
    automaticAttempt = true
    connection?.enableRenewal()
    return true
  }

  fun foreground(presentation: Any = this) {
    presentations.add(presentation)
  }

  fun background(presentation: Any = this, changingConfigurations: Boolean = false) {
    presentations.remove(presentation)
    // The system permission dialog temporarily backgrounds the app during explicit setup.
    if (!foreground && !changingConfigurations && !awaitingPermissions && companionOwner == null) cancel()
  }

  fun acquireCompanion(owner: Any) {
    check(companionOwner == null || companionOwner === owner)
    companionOwner = owner
  }

  fun releaseCompanion(owner: Any) {
    if (companionOwner !== owner) return
    companionOwner = null
    cancel()
  }

  fun presentationCleared() {
    beforeConnect = {}
    if (!foreground && companionOwner == null) cancel()
  }

  val hasCompanionOwner get() = companionOwner != null

  companion object {
    val CHECK = "aniCe connection check".toByteArray(Charsets.UTF_8)
  }
}
