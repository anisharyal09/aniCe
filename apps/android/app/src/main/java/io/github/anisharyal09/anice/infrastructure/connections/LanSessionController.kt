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
    },
    private val recoveryDelays: List<Long> = listOf(2_000L, 5_000L),
    private val elapsedRealtime: () -> Long = SystemClock::elapsedRealtime,
    private val interactive: () -> Boolean = {
        app.getSystemService(android.os.PowerManager::class.java).isInteractive &&
            !app.getSystemService(android.app.KeyguardManager::class.java).isKeyguardLocked
    },
    private val preferences: android.content.SharedPreferences = app.getSharedPreferences("lan_preferences", Context.MODE_PRIVATE),
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
    private var featureEventsJob: Job? = null
    private var transport: AndroidLanTransport? = null
    @Volatile private var connection: SessionConnection? = null
    @Volatile private var workerActivityGeneration = -1L
    @Volatile private var workerActivityAt = 0L
    private var watching: ConnectivityManager.NetworkCallback? = null
    private var ready: CompletableDeferred<Unit>? = null
    private var connectionState by mutableStateOf(ConnectionState.DISCONNECTED)
    var state: ConnectionState
        get() = connectionState
        private set(value) { connectionState = value; scheduleAutomatic() }

    // Absent means the user never chose; an explicit stored false still disables automation.
    var automatic by mutableStateOf(
        if (preferences.contains("automatic_lan")) preferences.getBoolean("automatic_lan", true) else true
    )
        private set
    private var automaticPaused = false
    private var connectionPause = false
    private var automaticAttempt = false
    private var automaticJob: Job? = null
    private var recoveryJob: Job? = null
    private var recoveryStep = 0
    private var recoveryGeneration = 0
    private var recoveryChannel: String? = null
    private var pendingTransferDemand: Pair<ChannelDescriptor, Long>? = null
    private val automaticGate = LanAttemptGate()
    internal val rendezvous = LanRendezvous(scope, elapsedRealtime, ::scheduleAutomatic)
    private var screenOff = !interactive()
    private val automaticNetworks = mutableMapOf<Network, Set<java.net.InetAddress>>()
    private val automaticNetworkCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onLinkPropertiesChanged(network: Network, properties: LinkProperties) {
            scope.launch {
                wifiAddressesChanged(network, if (properties.interfaceName == null) emptySet() else
                    properties.linkAddresses.map { it.address }.toSet())
            }
        }
        override fun onLost(network: Network) {
            scope.launch { automaticNetworks.remove(network); scheduleAutomatic() }
        }
    }
    private val automaticEligible get() = automatic && !automaticPaused && !connectionPause &&
        !CompanionProbe.connectionPauseActive && automaticNetworks.isNotEmpty() &&
        ((foreground && !screenOff && interactive()) || workLease || pickerLease || mediaLease)

    internal fun wifiAddressesChanged(network: Network, assigned: Set<java.net.InetAddress>) {
        val addresses = assigned.filterNot { it.isAnyLocalAddress || it.isLoopbackAddress || it.isMulticastAddress }.toSet()
        val previous = automaticNetworks[network].orEmpty()
        if (addresses == previous) return
        if (addresses.isEmpty()) automaticNetworks.remove(network) else automaticNetworks[network] = addresses
        val restored = addresses.any { it !in previous }
        // A network return is a lifecycle event: an elapsed timed pause must end even before eligibility.
        if (restored) CompanionProbe.reconcileIfPresent()
        scheduleAutomatic()
        // IP reprovisioning can restore a usable address without a new Network/onAvailable.
        if (automaticEligible && restored) {
            rearmRecovery()
            requestAutomaticConnection()
        }
        consumeTransferDemand()
    }

    fun setAutomaticEnabled(enabled: Boolean) {
        if (!enabled) { rendezvous.cancelTransferRequest(); pendingTransferDemand = null }
        automatic = enabled
        preferences.edit().putBoolean("automatic_lan", enabled).apply()
        automaticPaused = false
        connectionPause = false
        if (enabled) rearmRecovery() else cancelRecovery()
        automaticGate.trigger()
        if (!enabled && automaticAttempt && state != ConnectionState.SECURED) end()
        scheduleAutomatic()
    }

    private fun cancelRecovery() {
        recoveryGeneration++
        recoveryJob?.cancel(); recoveryJob = null
        recoveryStep = 0
    }

    private fun rearmRecovery() {
        cancelRecovery()
        automaticGate.rearm()
    }

    private fun noteRecoveryChannel() {
        val channel = rendezvous.channel?.descriptor?.instance
        if (channel == recoveryChannel) return
        recoveryChannel = channel
        if (pendingTransferDemand?.first?.instance != channel) pendingTransferDemand = null
        if (channel == null) cancelRecovery() else rearmRecovery()
    }

    /**
     * A failed automatic attempt may retry twice at two and five seconds. The budget is per
     * app-open/connection event, so repeated state callbacks cannot create an endless loop.
     */
    private fun scheduleRecovery() {
        if (recoveryJob?.isActive == true) return
        if (!automatic || automaticPaused || state == ConnectionState.SECURED || state == ConnectionState.CONNECTING) return
        if (rendezvous.channel == null || rendezvous.remote != 2) return
        val delayMillis = recoveryDelays.getOrNull(recoveryStep) ?: return
        recoveryStep++
        val generation = recoveryGeneration
        recoveryJob = scope.launch {
            delay(delayMillis)
            if (generation != recoveryGeneration) return@launch
            recoveryJob = null
            if (!automatic || automaticPaused || state == ConnectionState.SECURED || state == ConnectionState.CONNECTING) return@launch
            if (!automaticEligible || rendezvous.remote != 2) return@launch
            val target = rendezvous.channel?.descriptor?.peer ?: return@launch
            automaticGate.release()
            if (!automaticGate.claimRecovery()) return@launch
            connect(target, automatically = true)
        }
    }

    private fun scheduleAutomatic() {
        noteRecoveryChannel()
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
            if (state == ConnectionState.SECURED) {
                automaticGate.claim(connected = true)
                return@launch
            }
            if (state == ConnectionState.CONNECTING) {
                automaticGate.hold()
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

    private var checkPending = false
    private var checkingPeerLoss by mutableStateOf(false)
    val verifyingConnection get() = checkingPeerLoss
    private var checkDeadline: Long? = null
    private var checkJob: Job? = null
    private var checkTimeoutJob: Job? = null

    private var backgroundTimeoutJob: Job? = null
    private var backgroundTimeoutDeadline: Long? = null
    private val backgroundIdle = LanBackgroundIdle()
    private val workLeases = ConnectionWorkLeases { scope.launch { reconcileLeases() } }
    private val transferWorkOwner = Any()
    private var transferWorkLease: ConnectionWorkLeases.Lease? = null
    private var transferWorkAvailable = false
    private val workLease get() = workLeases.held
    private var pickerLease = false
    private var mediaLease = false
    var onUnleasedBackgroundWork: () -> Boolean = { false }
    var onDemandFailure: ((String) -> Unit)? = null
    var backgroundRetentionReason by mutableStateOf<String?>(null)
        private set
    private val backgroundedOrLocked get() = presentations.isEmpty() || screenOff || !interactive()
    private val backgroundLeased get() = workLease || pickerLease || mediaLease
    private val hasLanWork get() = connection != null || worker != null || state == ConnectionState.CONNECTING ||
        state == ConnectionState.SECURED
    private val timeoutPreferenceChanged = android.content.SharedPreferences.OnSharedPreferenceChangeListener { _, key ->
        if (key == "lan_background_timeout_minutes") scope.launch { reconcileLeases() }
    }

    // App/native lifecycle callbacks provide eligibility; a job tag cannot manufacture OS ownership.
    internal fun updateWorkOwner(owner: Any, eligible: Boolean) = workLeases.updateOwner(owner, eligible)
    internal fun acquireWorkLease(tag: String, owner: Any = transferWorkOwner) = workLeases.acquire(owner, tag)

    fun updateWorkLease(approved: Boolean, picking: Boolean) {
        val withdrawingPicker = pickerLease && !picking
        pickerLease = picking
        transferWorkAvailable = approved
        updateWorkOwner(transferWorkOwner, approved)
        if (approved && transferWorkLease == null) transferWorkLease = acquireWorkLease("approved-transfer")
        if (!approved) { transferWorkLease?.close(); transferWorkLease = null }
        if (withdrawingPicker && backgroundedOrLocked && !workLease && !mediaLease && onUnleasedBackgroundWork()) {
            end("File selection ended without background work ownership. Reconnect to continue.")
        } else reconcileLeases()
    }

    private fun reconcileLeases(reason: String = "Local-network disconnected after being inactive in the background.") {
        consumeTransferDemand()
        scheduleAutomatic()
        backgroundRetentionReason = when {
            workLease -> "Kept open for a transfer or pending resume."
            pickerLease -> "Kept open while choosing files."
            mediaLease -> "Kept open for playback."
            else -> null
        }
        val deadline = backgroundIdle.update(elapsedRealtime(), backgroundedOrLocked, backgroundLeased,
            backgroundTimeoutMillis())
        if (deadline == null || !hasLanWork) {
            backgroundTimeoutJob?.cancel(); backgroundTimeoutJob = null; backgroundTimeoutDeadline = null
            return
        }
        if (backgroundIdle.expired(elapsedRealtime())) {
            android.util.Log.i("aniCe-lan", "idle_timeout expired generation=$generation")
            end(reason)
            return
        }
        if (backgroundTimeoutJob?.isActive == true && backgroundTimeoutDeadline == deadline) return
        backgroundTimeoutJob?.cancel()
        backgroundTimeoutDeadline = deadline
        val op = generation
        val job = scope.launch(start = CoroutineStart.LAZY) {
            try {
                // Coroutine delays may run late after deep sleep; the elapsed-realtime deadline stays fixed.
                while (isActive && op == generation) {
                    delay((deadline - elapsedRealtime()).coerceAtLeast(0))
                    if (backgroundIdle.expired(elapsedRealtime())) break
                }
                if (op == generation && backgroundedOrLocked && !backgroundLeased &&
                    backgroundIdle.deadline == deadline) end(reason)
            } finally {
                if (backgroundTimeoutJob === currentCoroutineContext().job) {
                    backgroundTimeoutJob = null
                    backgroundTimeoutDeadline = null
                }
            }
        }
        backgroundTimeoutJob = job
        android.util.Log.d("aniCe-lan", "idle_timeout scheduled remaining_ms=${deadline - elapsedRealtime()} generation=$op")
        job.start()
    }

    /**
     * Bounds background LAN to active remote playback. MediaController owns the intent so
     * teardown of a failed connection must not clear it.
     */
    fun updateMediaLease(active: Boolean) {
        if (mediaLease == active) return
        mediaLease = active
        if (active) requestAutomaticConnection()
        reconcileLeases()
    }

    private val screenReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            // Unlock can otherwise clear the idle interval before a delayed background callback runs.
            if (!backgroundLeased && backgroundIdle.expired(elapsedRealtime()) && hasLanWork) {
                end("Local-network disconnected after being inactive in the background.")
            }
            when (intent?.action) {
                Intent.ACTION_SCREEN_OFF -> screenOff = true
                Intent.ACTION_SCREEN_ON, Intent.ACTION_USER_PRESENT -> screenOff = false
                else -> return
            }
            reconcileLeases()
        }
    }

    init {
        rendezvous.transferRequested = { descriptor ->
            if (automatic && !connectionPause && !CompanionProbe.connectionPauseActive &&
                rendezvous.channel?.descriptor == descriptor &&
                (!hasLanWork || selected == null || samePeer(requireNotNull(selected), descriptor.peer)) &&
                app.sessionPeers.permits(descriptor.peer)) {
                // A remote send cannot invent background execution. Its short-lived demand can
                // wait for this offer's real approved-transfer owner to become eligible.
                if (pendingTransferDemand?.first != descriptor || pendingTransferDemand?.second?.let { elapsedRealtime() >= it } == true)
                    pendingTransferDemand = descriptor to (elapsedRealtime() + 10_000)
                consumeTransferDemand()
            }
        }
        rendezvous.remoteStateChanged = { descriptor, previous, current ->
            // BLE and TCP are independent ordered lanes: an old advertisement can arrive after TCP replacement.
            // Verify the current socket instead of treating eligibility metadata as its retirement token.
            if (previous == 3 && current != 3 && state == ConnectionState.SECURED &&
                selected?.let { samePeer(it, descriptor.peer) } == true) checkConnection(peerLoss = true)
        }
        preferences.registerOnSharedPreferenceChangeListener(timeoutPreferenceChanged)
        networks.registerNetworkCallback(NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN).build(), automaticNetworkCallback)
        ContextCompat.registerReceiver(app, screenReceiver, IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_OFF); addAction(Intent.ACTION_SCREEN_ON); addAction(Intent.ACTION_USER_PRESENT)
        },
            ContextCompat.RECEIVER_EXPORTED)
    }

    private fun consumeTransferDemand() {
        val pending = pendingTransferDemand ?: return
        if (elapsedRealtime() >= pending.second || rendezvous.channel?.descriptor != pending.first ||
            !automatic || connectionPause || CompanionProbe.connectionPauseActive) {
            pendingTransferDemand = null
            return
        }
        if (automaticNetworks.isEmpty() || !((foreground && !screenOff && interactive()) || backgroundLeased)) return
        if (!app.sessionPeers.permits(pending.first.peer)) { pendingTransferDemand = null; return }
        pendingTransferDemand = null
        automaticPaused = false
        automaticGate.trigger()
        scheduleAutomatic()
    }

    internal fun dispose() {
        cancelRecovery()
        workLeases.clear()
        end()
        app.unregisterReceiver(screenReceiver)
        networks.unregisterNetworkCallback(automaticNetworkCallback)
        preferences.unregisterOnSharedPreferenceChangeListener(timeoutPreferenceChanged)
        scope.cancel()
    }

    fun setBackgroundTimeoutMinutes(minutes: Int) {
        require(minutes in listOf(0, 1, 3, 5, 10))
        preferences.edit().putInt("lan_background_timeout_minutes", minutes).apply()
        reconcileLeases()
    }

    fun onWorkServiceStopped() {
        if (!transferWorkAvailable) return
        transferWorkAvailable = false
        updateWorkOwner(transferWorkOwner, false)
        transferWorkLease?.close(); transferWorkLease = null
        if (backgroundedOrLocked) {
            onUnleasedBackgroundWork()
            if (!workLease && !pickerLease && !mediaLease) end("Background transfer ownership ended. Reconnect to transfer again.")
        }
    }

    fun onWorkIdle() {
        reconcileLeases()
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
        if (!automatic || automaticPaused || connectionPause || CompanionProbe.connectionPauseActive ||
            rendezvous.channel == null || rendezvous.remote == 0) return false
        automaticGate.trigger()
        rendezvous.request()
        scheduleAutomatic()
        return true
    }

    fun connectPreferred(): Boolean {
        if (connectionPause || CompanionProbe.connectionPauseActive) return false
        val existing = state == ConnectionState.SECURED || state == ConnectionState.CONNECTING
        // A new user file action may resume transport Disconnect, never a connection Pause or disabled choice.
        if (!automatic) return existing
        if (automaticPaused) {
            automaticPaused = false
            cancelRecovery()
            automaticGate.trigger()
            scheduleAutomatic()
        }
        if (rendezvous.channel != null) {
            automaticGate.trigger()
            rendezvous.requestTransfer()
            scheduleAutomatic()
            return true
        }
        if (existing) return true
        if (backgroundedOrLocked && !backgroundLeased) return false
        val target = selected ?: app.sessionController.selected
        if (target != null) {
            connect(target)
            return true
        }
        connect(null)
        return true
    }

    /** Device-level Connect starts LAN alongside BLE without disturbing a live transport for the same peer. */
    fun connectAlongside(peer: DeviceIdentity) {
        if (selected?.deviceId == peer.deviceId && selected?.fingerprint == peer.fingerprint &&
            selected?.publicKey == peer.publicKey &&
            state in listOf(ConnectionState.CONNECTING, ConnectionState.SECURED)) {
            automaticPaused = false
            connectionPause = false
            cancelRecovery()
            automaticGate.trigger()
            scheduleAutomatic()
            return
        }
        connect(peer)
    }

    /** Cancels the current attempt while leaving the automatic preference armed for the next event. */
    fun cancelAttempt(message: String = "Connection canceled.") {
        if (state == ConnectionState.SECURED) return
        cancelRecovery()
        rendezvous.cancelTransferRequest()
        pendingTransferDemand = null
        automaticAttempt = false
        automaticGate.cancel()
        end(message)
    }

    /** Gates recovery now while keeping the current channel available for a bounded pause notice. */
    internal fun preparePause(): () -> Unit {
        cancelRecovery()
        rendezvous.cancelTransferRequest()
        pendingTransferDemand = null
        automaticPaused = true
        connectionPause = true
        automaticAttempt = false
        if (state != ConnectionState.SECURED) { end("Local-network connection paused."); return {} }
        scheduleAutomatic()
        val op = generation
        return { if (op == generation && automaticPaused) disconnect() }
    }

    fun connect(peer: DeviceIdentity? = null, automatically: Boolean = false) {
        if (peer != null && !app.sessionPeers.permits(peer)) {
            status = "Disconnect the other device before connecting to this Mac."
            return
        }
        if (!automatically) {
            cancelRecovery(); automaticPaused = false; connectionPause = false; automaticGate.trigger()
            app.connectionPause.clear()
        }

        // Starting a replacement attempt must not drop a picker or transfer lease held while
        // discovery runs, otherwise a backgrounded selection can retire the companion transport.
        end(preserveLeases = true)
        automaticAttempt = automatically
        selected = peer
        state = ConnectionState.CONNECTING
        status = "Finding your Mac…"
        receivedChecks = 0
        val op = generation
        worker =
            scope.launch(start = CoroutineStart.LAZY) {
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
                                    caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN) &&
                                    (!automatically || automaticNetworks.containsKey(it))
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
                                if (changed == network)
                                    scope.launch {
                                        if (op != generation) return@launch
                                        val bound = transport?.localAddress
                                        if (interfaceLost || !LanAddress.retainsLocalAddress(bound, initialAddrs, currentAddrs))
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
                    var lastError: Exception? = null
                    var foundEndpoint = false
                    val direct = rendezvous.remoteEndpoint?.takeIf {
                        rendezvous.remote == 2 && rendezvous.channel?.descriptor?.peer?.let { pinned ->
                            pinned.deviceId == target.deviceId && pinned.fingerprint == target.fingerprint &&
                                pinned.publicKey == target.publicKey
                        } == true
                    }?.let { locator ->
                        val address = java.net.InetAddress.getByAddress(requireNotNull(LanDirectEndpoint.ipv4(locator.ip)))
                        networks.getLinkProperties(network)?.takeIf { LanAddress.local(address, it) }?.let {
                            LanEndpoint(network, address, locator.port, locator.profile)
                        }
                    }
                    suspend fun attempt(endpoint: LanEndpoint, directLocator: Boolean): Boolean {
                            foundEndpoint = true
                            ensureActive()
                            if (op != generation) throw SessionException(SessionFailure.CANCELLED)
                            val remaining = deadline - SystemClock.elapsedRealtime()
                            if (remaining <= 0) return false
                            // Assemble/register feature owners on their presentation dispatcher before worker callbacks.
                            val featureDispatch = app.features
                            val maintenanceEvents = SessionMaintenance()
                            val featureEvents = SessionMaintenance()
                            val featureRevision = java.util.concurrent.atomic.AtomicLong(-1)
                            val workerReceiptAt = java.util.concurrent.atomic.AtomicLong(0)
                            featureEventsJob?.cancel()
                            featureEventsJob = scope.launch {
                                while (isActive && op == generation) {
                                    featureEvents.await(null, SystemClock::elapsedRealtime)
                                    if (op == generation) {
                                        if (workerActivityGeneration == op && elapsedRealtime() - workerActivityAt < 1000)
                                            authenticatedLanActivity(op)
                                        if (connection?.isRenewing == true) clearConnectionCheck()
                                        connection?.let { app.features.maintenance("lan", channelToken, it.maintenanceSnapshot) }
                                        app.features.capacityAvailable("lan")
                                    }
                                }
                            }
                            val tcp = AndroidLanTransport(scope, endpoint.profile) {
                                maintenanceEvents.request(); featureEvents.request()
                            }
                            transport = tcp
                            try {
                                withTimeout(remaining) { tcp.connect(endpoint) }
                                if (networks.getLinkProperties(network)?.linkAddresses?.none {
                                        it.address == tcp.localAddress
                                    } != false) throw java.io.IOException("Wi-Fi address changed during connection. Retry.")
                             } catch (error: TimeoutCancellationException) {
                                 featureEventsJob?.cancel(); featureEventsJob = null
                                tcp.close()
                                lastError = error
                                return false
                            } catch (error: CancellationException) {
                                throw error
                             } catch (error: java.io.IOException) {
                                 featureEventsJob?.cancel(); featureEventsJob = null
                                tcp.close()
                                lastError = error
                                return false
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
                                throw SessionException(SessionFailure.CANCELLED)
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
                                     deliver@{ bytes ->
                                         if (op != generation) return@deliver
                                          val workerResult = featureDispatch.handleOnWorker("lan", channelToken, bytes)
                                         if (workerResult != DataHandling.UNRECOGNIZED) {
                                             // Receipt/liveness already passed record authentication. Do not wait for UI work.
                                             // Any authenticated record confirms transport health even if its feature stream retired.
                                             workerActivityAt = elapsedRealtime()
                                             workerActivityGeneration = op
                                             val time = elapsedRealtime()
                                             if (time - workerReceiptAt.get() >= 1000) {
                                                 workerReceiptAt.set(time)
                                                 featureEvents.request()
                                             }
                                             return@deliver
                                         }
                                         withContext(Dispatchers.Main.immediate) { authenticatedLanActivity(op) }
                                         val isCheck = bytes.contentEquals(SessionController.CHECK) ||
                                            bytes.contentEquals(SessionController.CHECK_REPLY)
                                        val handled = if (isCheck) DataHandling.UNRECOGNIZED else
                                            if (op == generation)
                                                withContext(Dispatchers.Main.immediate) {
                                                    if (op == generation) app.features.handle("lan", channelToken, bytes)
                                                    else DataHandling.DISCARDED
                                                }
                                            else DataHandling.UNRECOGNIZED
                                        if (
                                            op == generation &&
                                                handled == DataHandling.UNRECOGNIZED &&
                                                (bytes.contentEquals(SessionController.CHECK) ||
                                                    bytes.contentEquals(SessionController.CHECK_REPLY))
                                        ) {
                                            withContext(Dispatchers.Main.immediate) {
                                                if (op == generation &&
                                                    (bytes.contentEquals(SessionController.CHECK) || checkPending)) {
                                                    if (bytes.contentEquals(SessionController.CHECK)) {
                                                        receivedChecks++
                                                        status = "Local-network check received."
                                                        scope.launch {
                                                            val active = connection ?: return@launch
                                                            if (op != generation || state != ConnectionState.SECURED) return@launch
                                                            try { withContext(Dispatchers.IO) { active.sendData(SessionController.CHECK_REPLY) } }
                                                            catch (_: SessionBackpressure) {
                                                                if (op == generation && status == "Local-network check received.") {
                                                                    status = "Local-network check received, but its reply could not be sent."
                                                                }
                                                            } catch (error: CancellationException) {
                                                                throw error
                                                            } catch (error: Exception) {
                                                                if (op == generation) finish(error, active)
                                                            }
                                                        }
                                                     } else {
                                                         clearConnectionCheck()
                                                         status = "Local-network check confirmed."
                                                    }
                                                }
                                            }
                                        }
                                    },
                                    {
                                        withContext(Dispatchers.Main.immediate) {
                                            if(op==generation) {
                                                tcp.markSecured(); state=ConnectionState.SECURED; checkPending = false
                                                reconcileLeases()
                                                if (op == generation) publishChannel()
                                            }
                                        }
                                        signal.complete(Unit)
                                    },
                                    controls = true,
                                    now = { SystemClock.elapsedRealtime() },
                                    renew = true,
                                     changed = {
                                         if (op == generation) connection?.let {
                                             val snapshot = it.maintenanceSnapshot
                                             if (featureRevision.getAndSet(snapshot.revision) != snapshot.revision) {
                                                 featureDispatch.maintenanceOnWorker("lan", channelToken, snapshot)
                                                 featureEvents.request()
                                             }
                                         }
                                         maintenanceEvents.request()
                                     },
                                    profile = endpoint.profile,
                                    drain = { withContext(Dispatchers.Main.immediate) {
                                        if (op == generation) app.features.drain("lan", channelToken)
                                    } },
                                     renewalHandshake = {
                                        withContext(Dispatchers.IO) {
                                            SessionHandshakeEngine.initiator(app.identityService, app.trustStore,
                                                target, SystemClock::elapsedRealtime)
                                        }
                                     },
                                     pingAfterMillis = 10_000,
                                     pongWithinMillis = 10_000,
                                 )
                            connection = engine
                            receiver =
                                scope.launch(Dispatchers.IO) {
                                    try {
                                        tcp.receive(drained = { withContext(Dispatchers.Main.immediate) {
                                            if (op == generation && connection === engine) app.features.drain("lan", channelToken)
                                        } }) { bytes ->
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
                                if (op != generation) throw SessionException(SessionFailure.CANCELLED)
                                if (terminal.isCompleted) throw terminal.await()
                                if (engine.isClosed)
                                    throw java.io.EOFException(
                                        "Local-network connection ended during confirmation."
                                    )
                                state = ConnectionState.SECURED
                                reconcileLeases()
                                if (op != generation) throw SessionException(SessionFailure.CANCELLED)
                                publishChannel()
                                status = ""
                                return true
                            } catch (error: TimeoutCancellationException) {
                                lastError = error
                            } catch (error: CancellationException) {
                                throw error
                            } catch (error: SessionException) {
                                if (directLocator && error.reason in setOf(
                                        SessionFailure.CANCELLED, SessionFailure.UNTRUSTED_PEER, SessionFailure.AUTHENTICATION)) throw error
                                lastError = error
                            } catch (error: java.io.IOException) {
                                lastError = error
                            }
                            receiver?.cancel()
                            maintenance?.cancel()
                            featureEventsJob?.cancel(); featureEventsJob = null
                            tcp.close()
                            engine.retire()
                            withContext(NonCancellable + Dispatchers.IO) { engine.close() }
                            app.features.retired("lan")
                            connection = null
                            return false
                    }
                    val connected = consumeLanCandidates(direct,
                        discover = { discovery.endpoints(network) { networks.getLinkProperties(network) } },
                        key = { "${it.address.hostAddress}:${it.port}" }, attempt = ::attempt)
                    if (connected) awaitCancellation()
                    throw lastError
                            ?: IllegalStateException(
                                if (foundEndpoint) "No endpoint authenticated as your selected Mac. Retry."
                                else "No local-network connection was found. Check Allow connections, network permissions and the shared Wi-Fi network."
                            )
                } catch (error: TimeoutCancellationException) {
                    if (op == generation)
                        failed("Local-network discovery or authentication timed out. Retry.")
                } catch (error: CancellationException) {
                    throw error
                } catch (error: Exception) {
                    if (op == generation) {
                        val failure = (error as? SessionException)?.reason
                        val retry = failure == null || failure !in setOf(
                            SessionFailure.CANCELLED, SessionFailure.UNTRUSTED_PEER, SessionFailure.AUTHENTICATION)
                        failed(error.message ?: "Local-network connection failed. Retry.", retry)
                    }
                }
            }
        reconcileLeases()
        worker?.start()
    }

    private fun finish(error: Exception, engine: SessionConnection) {
        android.util.Log.i("aniCe-lan", "session ended type=${error.javaClass.simpleName} reason=${(error as? SessionException)?.reason} expiry=${engine.expiration} peerClosed=${engine.closedByPeer}")
        val wasAutomatic = automaticAttempt
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
        val failure = (error as? SessionException)?.reason
        val retryable = failure == null || failure !in setOf(
            SessionFailure.CANCELLED, SessionFailure.UNTRUSTED_PEER, SessionFailure.AUTHENTICATION)
        if (wasAutomatic && retryable && !engine.closedByPeer && engine.expiration == null) scheduleRecovery()
    }

    private fun failed(message: String, retry: Boolean = true) {
        val wasAutomatic = automaticAttempt
        end(message)
        state = ConnectionState.FAILED
        onDemandFailure?.invoke(message)
        if (wasAutomatic && retry) scheduleRecovery()
    }

    internal fun securityInvalidated() {
        // Retire keys synchronously even when the mutation originates outside a presentation.
        val op = generation
        cancelRecovery()
        rendezvous.cancelTransferRequest()
        pendingTransferDemand = null
        connection?.retire()
        scope.launch { automaticPaused = true; scheduleAutomatic() }
        connectionPause = true
        scope.launch { if (op == generation) this@LanSessionController.end("Trust or identity changed. Connect again.") }
    }

    fun checkConnection() = checkConnection(peerLoss = false)

    private fun checkConnection(peerLoss: Boolean) {
        val engine = connection ?: return
        if (state != ConnectionState.SECURED) return
        if (checkPending) {
            if (peerLoss && !checkingPeerLoss) {
                checkingPeerLoss = true
                checkDeadline = maxOf(checkDeadline ?: 0, elapsedRealtime() + 10_000)
            }
            return
        }
        if (engine.isRenewing) return
        val op = generation
        checkPending = true
        checkingPeerLoss = peerLoss
        // Eligibility metadata can be delayed or withdraw background work only; keep the legal LAN write budget.
        val deadline = elapsedRealtime() + if (peerLoss) 10_000 else 5_000
        checkDeadline = deadline
        status = "Checking the local-network connection…"
        checkTimeoutJob = scope.launch {
            while (isActive && op == generation && checkPending) {
                val due = checkDeadline ?: break
                delay((due - elapsedRealtime()).coerceAtLeast(0))
                checkExpired(op, engine)
            }
        }
        checkJob = scope.launch {
            try {
                withContext(Dispatchers.IO) { engine.sendData(SessionController.CHECK) }
                if (op == generation && checkPending) status = "Local-network check sent. Waiting for a reply."
            } catch (_: SessionBackpressure) {
                // The independent deadline also bounds capacity refusal and a nonce-owned send.
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                if (op == generation) { checkPending = false; finish(error, engine) }
            }
        }
    }

    private fun checkExpired(op: Long, engine: SessionConnection) {
        if (op != generation || connection !== engine || !checkPending || checkDeadline?.let { elapsedRealtime() >= it } != true) return
        val lost = checkingPeerLoss
        clearConnectionCheck()
        if (lost) finish(java.net.SocketTimeoutException("The peer's local-network connection was lost. Reconnecting when eligible."), engine)
        else status = "No reply to the local-network check. Check your Mac connection."
    }

    private fun samePeer(left: DeviceIdentity, right: DeviceIdentity) =
        left.deviceId == right.deviceId && left.fingerprint == right.fingerprint && left.publicKey == right.publicKey

    internal fun authenticatedLanActivity(op: Long) {
        if (op != generation || !checkingPeerLoss) return
        clearConnectionCheck()
        status = "Local-network connection confirmed."
    }

    private fun clearConnectionCheck() {
        checkPending = false; checkingPeerLoss = false; checkDeadline = null
        checkJob?.cancel(); checkJob = null
        checkTimeoutJob?.cancel(); checkTimeoutJob = null
    }

    fun disconnect() {
        cancelRecovery()
        rendezvous.cancelTransferRequest()
        pendingTransferDemand = null
        automaticPaused = true
        automaticAttempt = false
        automaticJob?.cancel(); automaticJob = null
        scheduleAutomatic()
        val engine = connection
        val op = generation
        state = ConnectionState.DISCONNECTED
        status = "Disconnecting local network…"
        scope.launch {
            try {
                withTimeoutOrNull(2000) { withContext(Dispatchers.IO) { engine?.disconnect() } }
            } catch (error: CancellationException) {
                throw error
            } catch (_: Exception) {
                // Automatic teardown may retire this session before its best-effort close is sent.
            } finally {
                if (op == generation) this@LanSessionController.end("Local-network connection disconnected.")
            }
        }
        scope.launch {
            delay(2000)
            if (op == generation) this@LanSessionController.end()
        }
    }

    fun resumeAfterTimedPause() {
        if (!automatic) return
        automaticPaused = false
        connectionPause = false
        rearmRecovery()
        automaticGate.trigger()
        scheduleAutomatic()
    }

    fun cancel(message: String = "Allow local-network connections on your Mac to reconnect.") {
        cancelRecovery()
        rendezvous.cancelTransferRequest()
        pendingTransferDemand = null
        automaticPaused = true
        connectionPause = true
        end(message)
    }

    private fun end(
        message: String = "Allow local-network connections on your Mac to reconnect.",
        preserveLeases: Boolean = false,
    ) {
        automaticAttempt = false
        backgroundTimeoutJob?.cancel(); backgroundTimeoutJob = null
        backgroundTimeoutDeadline = null
        if (!preserveLeases) {
            pickerLease = false
        }
        generation++
        val old = connection
        connection = null
        clearConnectionCheck()
        old?.retire()
        transport?.close()
        transport = null
        worker?.cancel()
        worker = null
        receiver?.cancel()
        receiver = null
        maintenance?.cancel()
        maintenance = null
        featureEventsJob?.cancel(); featureEventsJob = null
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
        // A paused feature may request LAN from retired(); it must observe the terminal transport state.
        app.features.retired("lan")
    }

    fun foreground(presentation: Any) {
        connection?.let { checkExpired(generation, it) }
        // Enforce an overdue idle timeout before app return can cancel the delayed callback.
        if (!backgroundLeased && backgroundIdle.expired(elapsedRealtime()) && hasLanWork) {
            end("Local-network disconnected after being inactive in the background.")
        }
        val wasEmpty = presentations.isEmpty()
        presentations.add(presentation)
        if (interactive()) screenOff = false
        if (wasEmpty) rearmRecovery()
        reconcileLeases()
    }

    fun background(presentation: Any, changingConfigurations: Boolean) {
        presentations.remove(presentation)
        scheduleAutomatic()
        if (presentations.isEmpty() && !changingConfigurations) {
            if (backgroundLeased) { reconcileLeases(); return }
            cancelRecovery()
            if (onUnleasedBackgroundWork()) {
                end("Background transfer service is unavailable; keep aniCe open during transfer.")
            } else reconcileLeases()
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
            try { withContext(Dispatchers.IO) { engine.sendData(bytes) } }
            catch (error: SessionBackpressure) { throw error }
            catch (error: Exception) {
                if (error is kotlinx.coroutines.CancellationException && !engine.isClosed) throw error
                // A closed engine has no future maintenance deadline; its owner must retire it now.
                if (token == channelToken && connection === engine) finish(error, engine)
                throw error
            }
        }
    }

}
