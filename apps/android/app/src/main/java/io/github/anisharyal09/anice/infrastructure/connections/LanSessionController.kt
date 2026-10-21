// SPDX-License-Identifier: GPL-3.0-or-later
// Owns manual and BLE-coordinated LAN sessions within native presentation and work leases.
package io.github.anisharyal09.anice.infrastructure.connections

import io.github.anisharyal09.anice.infrastructure.lan.*
import android.content.*
import android.net.*
import android.os.SystemClock
import androidx.compose.runtime.*
import androidx.core.content.ContextCompat
import io.github.anisharyal09.anice.AniCeApplication
import io.github.anisharyal09.anice.infrastructure.connections.sessionNotice
import io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity
import io.github.anisharyal09.anice.infrastructure.session.*
import kotlinx.coroutines.*

class LanSessionController(private val app: AniCeApplication,
    private val backgroundTimeoutMillis: () -> Long = {
        app.getSharedPreferences("lan_preferences", Context.MODE_PRIVATE)
            .getInt("lan_background_timeout_minutes", 0).toLong() * 60_000L
    }
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val discovery = AndroidLanDiscovery(app)
    private val networks = app.getSystemService(ConnectivityManager::class.java)
    private val presentations = mutableSetOf<Any>()
    internal val foreground get() = presentations.isNotEmpty()
    @Volatile private var generation = 0L
    private var worker: Job? = null
    private var receiver: Job? = null
    private var maintenance: Job? = null
    private var transport: AndroidLanTransport? = null
    @Volatile private var connection: SessionConnection? = null
    private var watching: ConnectivityManager.NetworkCallback? = null
    private var ready: CompletableDeferred<Unit>? = null
    private var connectionState by mutableStateOf(ConnectionState.DISCONNECTED)
    var state: ConnectionState
        get() = connectionState
        private set(value) { connectionState = value; scheduleAutomatic() }

    private val preferences = app.getSharedPreferences("lan_preferences", Context.MODE_PRIVATE)
    // Absent means the user never chose; an explicit stored false still disables automation.
    var automatic by mutableStateOf(
        if (preferences.contains("automatic_lan")) preferences.getBoolean("automatic_lan", true) else true
    )
        private set
    private var automaticPaused = false
    private var automaticAttempt = false
    private var automaticJob: Job? = null
    private val automaticGate = LanAttemptGate()
    internal val rendezvous = LanRendezvous(scope, ::scheduleAutomatic)
    private val power = app.getSystemService(android.os.PowerManager::class.java)
    private val automaticNetworks = mutableSetOf<Network>()
    private val automaticNetworkCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            scope.launch {
                automaticNetworks.add(network)
                scheduleAutomatic()
            }
        }
        override fun onLost(network: Network) {
            scope.launch { automaticNetworks.remove(network); scheduleAutomatic() }
        }
    }
    private val automaticEligible get() = automatic && !automaticPaused && automaticNetworks.isNotEmpty() &&
        ((foreground && power.isInteractive) || workLease || pickerLease || mediaLease)

    fun setAutomaticEnabled(enabled: Boolean) {
        automatic = enabled
        preferences.edit().putBoolean("automatic_lan", enabled).apply()
        automaticPaused = false
        automaticGate.trigger()
        if (!enabled && automaticAttempt && state != ConnectionState.SECURED) end()
        scheduleAutomatic()
    }

    private fun scheduleAutomatic() {
        automaticJob?.cancel()
        automaticJob = scope.launch {
            yield()
            val eligible = automaticEligible
            automaticGate.update(rendezvous.channel?.descriptor?.instance, eligible,
                rendezvous.remote != null && rendezvous.remote != 0, rendezvous.remote == 2, rendezvous.requests)
            rendezvous.update(if (!eligible) 0 else if (state == ConnectionState.SECURED) 3 else 1)
            if (!eligible || rendezvous.remote == 0 || rendezvous.channel == null) {
                if (automaticAttempt && state != ConnectionState.SECURED) end()
                return@launch
            }
            if (state == ConnectionState.SECURED || state == ConnectionState.CONNECTING) {
                automaticGate.claim()
                return@launch
            }
            if (rendezvous.remote != 2) return@launch
            val target = rendezvous.channel?.descriptor?.peer ?: return@launch
            if (automaticEligible &&
                rendezvous.remote == 2 && rendezvous.channel?.descriptor?.peer == target && automaticGate.claim()) {
                connect(target, automatically = true)
            }
        }
    }

    var status by mutableStateOf("Allow local-network connections on your Mac, then connect here.")
        private set

    var selected by mutableStateOf<DeviceIdentity?>(null)
        private set

    var receivedChecks by mutableIntStateOf(0)
        private set

    private var backgroundTimeoutJob: Job? = null
    private var workLease = false
    private var pickerLease = false
    private var mediaLease = false
    var onUnleasedBackgroundWork: () -> Boolean = { false }
    var onDemandFailure: ((String) -> Unit)? = null

    fun updateWorkLease(approved: Boolean, picking: Boolean) {
        val withdrawingPicker = pickerLease && !picking
        val withdrawingWork = workLease && !approved
        workLease = approved
        pickerLease = picking
        scheduleAutomatic()
        if (workLease || pickerLease || mediaLease) {
            backgroundTimeoutJob?.cancel(); backgroundTimeoutJob = null
        } else if (withdrawingPicker && presentations.isEmpty()) {
            onUnleasedBackgroundWork()
            end("File selection ended while aniCe was background. Reconnect to continue.")
        } else if (withdrawingWork && presentations.isEmpty()) {
            startBackgroundDisconnectTimer()
        }
    }

    /**
     * Bounds background LAN to active remote playback. MediaController owns the intent so
     * teardown of a failed connection must not clear it.
     */
    fun updateMediaLease(active: Boolean) {
        if (mediaLease == active) return
        mediaLease = active
        if (active) {
            requestAutomaticConnection()
            scheduleAutomatic()
        } else {
            scheduleAutomatic()
            if (presentations.isEmpty() && !workLease && !pickerLease) startBackgroundDisconnectTimer()
        }
    }

    private val screenReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            scheduleAutomatic()
            if (intent?.action == Intent.ACTION_SCREEN_OFF && !workLease && !pickerLease && !mediaLease) {
                startBackgroundDisconnectTimer("Local-network connection ended after screen lock.")
            }
        }
    }

    init {
        networks.registerNetworkCallback(NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN).build(), automaticNetworkCallback)
        ContextCompat.registerReceiver(app, screenReceiver, IntentFilter().apply { addAction(Intent.ACTION_SCREEN_OFF); addAction(Intent.ACTION_SCREEN_ON) },
            ContextCompat.RECEIVER_EXPORTED)
    }

    internal fun dispose() {
        end()
        app.unregisterReceiver(screenReceiver)
        networks.unregisterNetworkCallback(automaticNetworkCallback)
        scope.cancel()
    }

    private fun startBackgroundDisconnectTimer(reason: String = "Local-network disconnected after being inactive in the background.") {
        backgroundTimeoutJob?.cancel()
        val timeoutMillis = backgroundTimeoutMillis()
        if (timeoutMillis <= 0) return
        val op = generation
        backgroundTimeoutJob = scope.launch {
            delay(timeoutMillis)
            if (op == generation && presentations.isEmpty() && !workLease && !pickerLease && !mediaLease) {
                this@LanSessionController.end(reason)
            }
        }
    }

    fun onWorkServiceStopped() {
        if (!workLease) return
        workLease = false
        if (presentations.isEmpty() && !pickerLease && !mediaLease) {
            onUnleasedBackgroundWork()
            end("Background transfer ownership ended. Reconnect to transfer again.")
        }
    }

    fun onWorkIdle() {
        if (presentations.isEmpty() && !workLease && !pickerLease && !mediaLease) {
            startBackgroundDisconnectTimer()
        }
    }

    internal fun onApplicationActivity(descriptor: ChannelDescriptor, bytes: ByteArray) {
        if (descriptor.transport != "ble" || state == ConnectionState.SECURED || state == ConnectionState.CONNECTING ||
            rendezvous.channel?.descriptor != descriptor || !automaticEligible) return
        val coordination = try { LanRendezvousWire.decode(bytes) != null }
            catch (_: IllegalArgumentException) { false }
            catch (_: io.github.anisharyal09.anice.infrastructure.session.SessionException) { false }
        if (!coordination && automaticGate.claimActivity()) requestAutomaticConnection()
    }

    fun requestAutomaticConnection(): Boolean {
        if (state == ConnectionState.SECURED || state == ConnectionState.CONNECTING) return true
        if (!automatic || automaticPaused || rendezvous.channel == null || rendezvous.remote == 0) return false
        automaticGate.trigger()
        rendezvous.request()
        scheduleAutomatic()
        return true
    }

    fun connectPreferred(): Boolean {
        if (state == ConnectionState.SECURED || state == ConnectionState.CONNECTING) return true
        // Explicit Disconnect stays authoritative until manual Connect or a preference change.
        if (automaticPaused) return false
        if (requestAutomaticConnection()) return true
        val target = selected ?: app.sessionController.selected
        if (target != null) {
            connect(target)
            return true
        }
        connect(null)
        return true
    }

    fun connect(peer: DeviceIdentity? = null, automatically: Boolean = false) {
        if (!automatically) { automaticPaused = false; automaticGate.trigger() }

        if (peer != null && !app.sessionPeers.permits(peer)) {
            status = "Disconnect the other device before connecting to this Mac."
            return
        }
        // Starting a replacement attempt must not drop a picker or transfer lease held while
        // discovery runs, otherwise a backgrounded selection can retire the companion transport.
        end(preserveLeases = true)
        automaticAttempt = automatically
        selected = peer
        state = ConnectionState.CONNECTING
        status = "Finding your Mac (includes a 15-second browse)…"
        receivedChecks = 0
        val op = generation
        worker =
            scope.launch {
                try {
                    val (local, target) =
                        withContext(Dispatchers.IO) {
                            val localId = app.identityService.getOrCreateIdentity().identity
                            val candidate = peer ?: run {
                                val macs = app.trustStore.list(localId.fingerprint).map { it.peer }.filter { it.platform == "macos" }
                                if (macs.size == 1) macs.first() else null
                            }
                            localId to candidate
                        }
                    ensureActive()
                    if (target == null) {
                        state = ConnectionState.DISCONNECTED
                        status = "Connect from Devices or pair your Mac first."
                        return@launch
                    }
                    if (!app.sessionPeers.permits(target)) {
                        state = ConnectionState.DISCONNECTED
                        status = "Disconnect the other device before connecting to this Mac."
                        return@launch
                    }
                    selected = target
                    if (
                        !app.sessionPeers.acquire(
                            this@LanSessionController,
                            target,
                            local.fingerprint,
                        )
                    )
                        error("Another transport is connecting to a different device.")
                    val network =
                        networks.allNetworks.firstOrNull {
                            networks.getNetworkCapabilities(it)?.let { caps ->
                                caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) &&
                                    caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
                            } == true
                        } ?: error("Connect this phone and your Mac to the same local network.")
                    val callback =
                        // The socket belongs to this concrete interface and address set.
                        object : ConnectivityManager.NetworkCallback() {
                            private val initial = networks.getLinkProperties(network)

                            override fun onLost(lost: Network) {
                                if (lost == network)
                                    scope.launch {
                                        if (op == generation)
                                            this@LanSessionController.end(
                                                "Wi-Fi changed. On your Mac, allow local-network connections again, then reconnect here."
                                            )
                                    }
                            }

                            override fun onLinkPropertiesChanged(
                                changed: Network,
                                properties: LinkProperties,
                            ) {
                                val interfaceLost =
                                    properties.interfaceName == null ||
                                        properties.interfaceName != initial?.interfaceName
                                val initialAddrs =
                                    initial?.linkAddresses?.map { it.address }?.toSet().orEmpty()
                                val currentAddrs = properties.linkAddresses.map { it.address }.toSet()
                                val allAddrsLost =
                                    initialAddrs.isNotEmpty() && currentAddrs.intersect(initialAddrs).isEmpty()
                                if (changed == network && (interfaceLost || allAddrsLost))
                                    scope.launch {
                                        if (op == generation)
                                            this@LanSessionController.end(
                                                "Wi-Fi address changed. On your Mac, allow local-network connections again, then reconnect here."
                                            )
                                    }
                            }
                        }
                    networks.registerNetworkCallback(
                        NetworkRequest.Builder()
                            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
                            .build(),
                        callback,
                    )
                    watching = callback
                    val deadline = SystemClock.elapsedRealtime() + 90000
                    val endpoints =
                        withTimeout(90000) {
                            discovery.discover(network) { networks.getLinkProperties(network) }
                        }
                    if (endpoints.isEmpty())
                        error(
                            "No local-network connection was found. Check Allow connections, network permissions and the shared Wi-Fi network."
                        )
                    var lastError: Exception? = null
                    for (endpoint in endpoints) {
                        ensureActive()
                        if (op != generation) return@launch
                        val remaining = deadline - SystemClock.elapsedRealtime()
                        if (remaining <= 0) break
                        val maintenanceEvents = SessionMaintenance()
                        val tcp = AndroidLanTransport(scope, endpoint.profile) { maintenanceEvents.request(); scope.launch { app.features.capacityAvailable("lan") } }
                        transport = tcp
                        try {
                            withTimeout(remaining) { tcp.connect(endpoint) }
                        } catch (error: TimeoutCancellationException) {
                            tcp.close()
                            lastError = error
                            continue
                        } catch (error: CancellationException) {
                            throw error
                        } catch (error: java.io.IOException) {
                            tcp.close()
                            lastError = error
                            continue
                        }
                        // Identity/storage/signing failures terminate discovery instead of probing
                        // more peers.
                        val handshake =
                            withContext(Dispatchers.IO) {
                                SessionHandshakeEngine.initiator(
                                    app.identityService,
                                    app.trustStore,
                                    target,
                                    SystemClock::elapsedRealtime,
                                )
                            }
                        if (op != generation) {
                            handshake.close()
                            return@launch
                        }
                        val signal = CompletableDeferred<Unit>()
                        val terminal = CompletableDeferred<Exception>()
                        ready = signal
                        val engine =
                            SessionConnection(
                                handshake,
                                false,
                                { bytes -> op == generation && tcp.hasCapacity(bytes) },
                                { bytes ->
                                    if (op != generation)
                                        throw SessionException(SessionFailure.CANCELLED)
                                    tcp.submit(bytes)
                                },
                                { bytes ->
                                    val handled =
                                        if (op == generation)
                                            withContext(Dispatchers.Main.immediate) {
                                                if (op == generation) app.features.handle("lan", channelToken, bytes)
                                                else DataHandling.DISCARDED
                                            }
                                        else DataHandling.UNRECOGNIZED
                                    if (
                                        op == generation &&
                                            handled == DataHandling.UNRECOGNIZED &&
                                            bytes.contentEquals(SessionController.CHECK)
                                    ) {
                                        withContext(Dispatchers.Main.immediate) {
                                            if (op == generation) {
                                                receivedChecks++
                                                status = "Local-network connection check received."
                                            }
                                        }
                                    }
                                },
                                {
                                    withContext(Dispatchers.Main.immediate) {
                                        if(op==generation) { state=ConnectionState.SECURED; publishChannel() }
                                    }
                                    signal.complete(Unit)
                                },
                                controls = true,
                                now = { SystemClock.elapsedRealtime() },
                                changed = { maintenanceEvents.request(); scope.launch { app.features.capacityAvailable("lan") } },
                                profile = endpoint.profile,
                            )
                        connection = engine
                        receiver =
                            scope.launch(Dispatchers.IO) {
                                try {
                                    tcp.receive { bytes ->
                                        engine.receive(bytes)
                                        if (terminal.isCompleted) throw terminal.await()
                                        if (engine.isClosed)
                                            throw java.io.EOFException(
                                                "Your Mac ended the local-network connection."
                                            )
                                    }
                                } catch (error: CancellationException) {
                                    throw error
                                } catch (error: Exception) {
                                    terminal.complete(error)
                                    signal.completeExceptionally(error)
                                    withContext(Dispatchers.Main.immediate) {
                                        if (
                                            op == generation &&
                                                connection === engine &&
                                                state == ConnectionState.SECURED
                                        )
                                            finish(error, engine)
                                    }
                                }
                            }
                        maintenance =
                            scope.launch(Dispatchers.IO) {
                                var controlWork: Job? = null
                                suspend fun failed(error: Exception) {
                                    terminal.complete(error)
                                    signal.completeExceptionally(error)
                                    withContext(Dispatchers.Main.immediate) {
                                        if (op == generation && connection === engine && state == ConnectionState.SECURED)
                                            finish(error, engine)
                                    }
                                }
                                try {
                                    while (isActive && op == generation) {
                                        val requested = maintenanceEvents.await(
                                            engine.nextDeadline(controlWork?.isActive != true), SystemClock::elapsedRealtime)
                                        if (op != generation) break
                                        engine.checkDeadlines()
                                        if (requested) {
                                            if (controlWork?.isActive == true) maintenanceEvents.deferWork()
                                            else controlWork = launch {
                                                try { engine.tick() }
                                                catch (error: CancellationException) { throw error }
                                                catch (error: Exception) { failed(error) }
                                            }.also { work -> work.invokeOnCompletion { maintenanceEvents.resnapshot() } }
                                        }
                                    }
                                } catch (error: CancellationException) {
                                    throw error
                                } catch (error: Exception) {
                                    failed(error)
                                }
                            }
                        try {
                            withTimeout(
                                minOf(
                                    40000,
                                    (deadline - SystemClock.elapsedRealtime()).coerceAtLeast(1),
                                )
                            ) {
                                withContext(Dispatchers.IO) { engine.start() }
                                signal.await()
                            }
                            if (op != generation) return@launch
                            if (terminal.isCompleted) throw terminal.await()
                            if (engine.isClosed)
                                throw java.io.EOFException(
                                    "Local-network connection ended during confirmation."
                                )
                            state = ConnectionState.SECURED
                            publishChannel()
                            status = ""
                            awaitCancellation()
                        } catch (error: TimeoutCancellationException) {
                            lastError = error
                        } catch (error: CancellationException) {
                            throw error
                        } catch (error: SessionException) {
                            lastError = error
                        } catch (error: java.io.IOException) {
                            lastError = error
                        }
                        receiver?.cancel()
                        maintenance?.cancel()
                        tcp.close()
                        engine.retire()
                        withContext(NonCancellable + Dispatchers.IO) { engine.close() }
                        app.features.retired("lan")
                        connection = null
                    }
                    throw lastError
                        ?: IllegalStateException(
                            "No endpoint authenticated as your selected Mac. Retry."
                        )
                } catch (error: TimeoutCancellationException) {
                    if (op == generation)
                        failed("Local-network discovery or authentication timed out. Retry.")
                } catch (error: CancellationException) {
                    throw error
                } catch (error: Exception) {
                    if (op == generation)
                        failed(error.message ?: "Local-network connection failed. Retry.")
                }
            }
    }

    private fun finish(error: Exception, engine: SessionConnection) {
        val notice =
            sessionNotice(
                (error as? SessionException)?.reason,
                engine.expiration,
                engine.closedByPeer,
                true,
            )
        end(
            if (error is SessionException) notice.text
            else error.message ?: "Local-network connection ended. Connect again."
        )
        if (error is SessionException) state = notice.state
    }

    private fun failed(message: String) {
        end(message)
        state = ConnectionState.FAILED
        onDemandFailure?.invoke(message)
    }

    internal fun securityInvalidated() {
        // Retire keys synchronously even when the mutation originates outside a presentation.
        val op = generation
        connection?.retire()
        scope.launch { automaticPaused = true; scheduleAutomatic() }
        scope.launch { if (op == generation) this@LanSessionController.end("Trust or identity changed. Connect again.") }
    }

    fun checkConnection() {
        val engine = connection ?: return
        if (state != ConnectionState.SECURED) return
        val op = generation
        scope.launch {
            try {
                withContext(Dispatchers.IO) { engine.sendData(SessionController.CHECK) }
                if (op == generation) status = "Local-network connection check sent."
            } catch (_: SessionBackpressure) {
                if (op == generation) status = "Local-network connection is busy. Try again."
            } catch (error: Exception) {
                if (op == generation) finish(error, engine)
            }
        }
    }

    fun disconnect() {
        automaticPaused = true
        scheduleAutomatic()
        val engine = connection
        val op = generation
        state = ConnectionState.DISCONNECTED
        status = "Disconnecting local network…"
        scope.launch {
            try {
                withTimeoutOrNull(2000) { withContext(Dispatchers.IO) { engine?.disconnect() } }
            } finally {
                if (op == generation) this@LanSessionController.end()
            }
        }
        scope.launch {
            delay(2000)
            if (op == generation) this@LanSessionController.end()
        }
    }

    fun cancel(message: String = "Allow local-network connections on your Mac to reconnect.") {
        automaticPaused = true
        end(message)
    }

    private fun end(
        message: String = "Allow local-network connections on your Mac to reconnect.",
        preserveLeases: Boolean = false,
    ) {
        automaticAttempt = false
        backgroundTimeoutJob?.cancel(); backgroundTimeoutJob = null
        if (!preserveLeases) {
            workLease = false
            pickerLease = false
        }
        app.features.retired("lan")
        generation++
        val old = connection
        connection = null
        old?.retire()
        transport?.close()
        transport = null
        worker?.cancel()
        worker = null
        receiver?.cancel()
        receiver = null
        maintenance?.cancel()
        maintenance = null
        ready?.cancel()
        ready = null
        watching?.let {
            try {
                networks.unregisterNetworkCallback(it)
            } catch (_: IllegalArgumentException) {}
        }
        watching = null
        app.sessionPeers.release(this)
        scope.launch(Dispatchers.IO) { old?.close() }
        state = ConnectionState.DISCONNECTED
        status = message
    }

    fun foreground(presentation: Any) {
        presentations.add(presentation)
        scheduleAutomatic()
        backgroundTimeoutJob?.cancel()
        backgroundTimeoutJob = null
    }

    fun background(presentation: Any, changingConfigurations: Boolean) {
        presentations.remove(presentation)
        scheduleAutomatic()
        if (presentations.isEmpty() && !changingConfigurations) {
            if (pickerLease || workLease || mediaLease) {
                return
            }
            if (onUnleasedBackgroundWork()) {
                end("Background transfer service is unavailable; keep aniCe open during transfer.")
            } else startBackgroundDisconnectTimer()
        }
    }
    private val channelToken get() = "${generation}-${System.identityHashCode(connection)}"
    private fun publishChannel() {
        val token=channelToken
        val peer=selected ?: return
        app.features.available(ChannelDescriptor(token,"lan",peer,transport?.profile?.maximumPlaintext ?: 4000)) { bytes ->
            val engine=connection ?: throw SessionException(SessionFailure.CANCELLED)
            if(token!=channelToken || state!=ConnectionState.SECURED) throw SessionException(SessionFailure.CANCELLED)
            if(!engine.applicationAvailable || transport?.hasCapacity(bytes.size+31) != true) throw SessionBackpressure()
            withContext(Dispatchers.IO) { engine.sendData(bytes) }
        }
    }

}
