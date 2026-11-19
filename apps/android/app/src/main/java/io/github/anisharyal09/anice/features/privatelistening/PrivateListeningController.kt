// SPDX-License-Identifier: GPL-3.0-or-later
// Serially owns authenticated listening admission, native service tickets and maintenance-aware health without socket ownership.
package io.github.anisharyal09.anice.features.privatelistening

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import io.github.anisharyal09.anice.infrastructure.connections.ChannelDescriptor
import io.github.anisharyal09.anice.infrastructure.connections.DataHandling
import io.github.anisharyal09.anice.infrastructure.connections.FeatureHandler
import io.github.anisharyal09.anice.infrastructure.connections.SecuredChannel
import io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity
import io.github.anisharyal09.anice.infrastructure.session.Cbor
import io.github.anisharyal09.anice.infrastructure.session.SessionBackpressure
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

internal interface PrivateListeningOutput {
    fun offer(message: PrivateListeningMessage): Boolean
    fun pause()
    fun beginResume() {}
    suspend fun resume()
    fun close()
}

internal class PrivateListeningRequest(
    val id: String,
    val descriptor: ChannelDescriptor,
    val startedAt: Long,
    val maintenanceAtStart: Long,
) {
    var output: PrivateListeningOutput? = null
    var foregroundOwner: Any? = null
    var ready = false
    var focusPaused = false
    var pauseAt: Long? = null
    var priming = false
    var preparationRevision = 0
    var maintenanceActive = false
    var maintenanceTotal = maintenanceAtStart
    var peerAt = startedAt
    var peerMaintenance = maintenanceAtStart
    var firstAudioAt: Long? = null
    var readyAt: Long? = null
    var readyMaintenance = maintenanceAtStart
    var lastSequence = 0L
    var positionFrames = 0L
    var queuedFrames = 0
    var underruns = 0L
}

class PrivateListeningController internal constructor(
    val preferences: PrivateListeningPreferences = PrivateListeningPreferences(),
    private val now: () -> Long = { android.os.SystemClock.elapsedRealtime() },
    dispatcher: CoroutineDispatcher = Dispatchers.Main.immediate,
    private val automaticTicks: Boolean = true,
) : FeatureHandler {
    private val scope = CoroutineScope(SupervisorJob() + dispatcher)
    private var channel: SecuredChannel? = null
    private var localFingerprint: String? = null
    private var localLookup: Job? = null
    private var current: PrivateListeningRequest? = null
    private var stoppingService: PrivateListeningRequest? = null
    private var tickJob: Job? = null
    private var sending: Job? = null
    private val outgoing = ArrayDeque<PrivateListeningMessage>()
    private var terminal: PrivateListeningMessage? = null
    private val retiredIDs = mutableSetOf<String>()
    private var exhaustedIDs = false
    private var generation = 0
    private var statusAt = 0L
    var state by mutableStateOf(0L)
        private set
    var status by mutableStateOf("Connect LAN and enable receiving for your Mac.")
        private set
    var consentEnabled by mutableStateOf(false)
        private set
    var peer by mutableStateOf<DeviceIdentity?>(null)
        private set
    var openWorkspaceRequest by mutableStateOf(false)
        private set
    val active get() = current != null
    val streamId get() = current?.id
    internal var loadLocalFingerprint: suspend () -> String = { "" }
    internal var startupAllowed: (DeviceIdentity) -> Boolean = { false }
    internal var startService: (PrivateListeningRequest) -> Unit = { failed(it, 4, "Open aniCe on the phone.") }
    internal var stopService: (PrivateListeningRequest) -> Unit = {}
    internal var serviceOwnershipChanged: (PrivateListeningRequest, Any, Boolean) -> Unit = { _, _, _ -> }
    internal var ownershipChanged: (Boolean) -> Unit = {}
    internal var transferReady: () -> Boolean = { true }

    fun openWorkspace() { openWorkspaceRequest = true }
    fun workspaceOpened() { openWorkspaceRequest = false }

    fun setConsent(enabled: Boolean) {
        val channel = channel ?: return
        val local = localFingerprint ?: return
        try { preferences.set(local, channel.descriptor.peer, enabled) }
        catch (error: IllegalStateException) { status = error.message.orEmpty(); return }
        consentEnabled = enabled
        if (!enabled) stop(message = "Receiving disabled.")
        enqueue(PrivateListeningMessage.capability(enabled))
    }

    override fun available(channel: SecuredChannel) {
        val descriptor = channel.descriptor
        if (descriptor.transport != "lan" || descriptor.peer.platform != "macos" ||
            this.channel?.descriptor == descriptor) return
        this.channel?.let { retired(it.descriptor) }
        this.channel = channel
        peer = descriptor.peer
        localFingerprint = null
        consentEnabled = false
        retiredIDs.clear()
        exhaustedIDs = false
        val token = generation
        localLookup = scope.launch {
            try {
                val local = loadLocalFingerprint()
                if (local.isEmpty() || token != generation || this@PrivateListeningController.channel !== channel) return@launch
                localFingerprint = local
                consentEnabled = preferences.enabled(local, descriptor.peer)
                enqueue(PrivateListeningMessage.capability(consentEnabled))
            } catch (error: CancellationException) { throw error }
            catch (_: Exception) {
                if (token == generation) status = "Local identity could not be verified."
            }
        }
    }

    override fun retired(descriptor: ChannelDescriptor) {
        if (channel?.descriptor != descriptor) return
        stop(reason = 3, message = "LAN ended. Start listening again after reconnecting.", notify = false)
        localLookup?.cancel(); localLookup = null
        channel = null
        peer = null
        localFingerprint = null
        consentEnabled = false
        outgoing.clear()
        terminal = null
    }

    override fun capacityAvailable(descriptor: ChannelDescriptor) {
        if (channel?.descriptor != descriptor) return
        reflectMaintenance()
        pump()
    }

    override suspend fun handle(descriptor: ChannelDescriptor, bytes: ByteArray): DataHandling {
        if (channel?.descriptor != descriptor) return DataHandling.UNRECOGNIZED
        val message = try {
            PrivateListeningMessage.decode(bytes) ?: return DataHandling.UNRECOGNIZED
        } catch (_: PrivateListeningWireException) {
            stop(reason = 5, message = "Invalid listening message.")
            return DataHandling.DISCARDED
        } catch (_: io.github.anisharyal09.anice.infrastructure.session.SessionException) {
            stop(reason = 5, message = "Invalid listening message.")
            return DataHandling.DISCARDED
        }
        if (message.kind == 1L) {
            receiveStart(message, descriptor)
            return DataHandling.HANDLED
        }
        val request = current ?: return DataHandling.DISCARDED
        if (request.descriptor != descriptor || message.kind == 0L ||
            message.text(0) != request.id) return DataHandling.DISCARDED
        when (message.kind) {
            3L -> {
                if (!request.ready || message.number(1) <= request.lastSequence) return DataHandling.DISCARDED
                request.lastSequence = message.number(1)
                request.firstAudioAt = request.firstAudioAt ?: now()
                request.peerAt = now()
                request.peerMaintenance = channel?.maintenance?.elapsedMillis ?: 0
                reflectMaintenance()
                if (!request.focusPaused && !request.maintenanceActive) request.output?.offer(message)
            }
            4L -> stop(message = "Listening ended on the Mac.", notify = false)
            5L -> {
                if (message.number(1) != 0L) return DataHandling.DISCARDED
                request.peerAt = now()
                request.peerMaintenance = channel?.maintenance?.elapsedMillis ?: 0
            }
            else -> return DataHandling.DISCARDED
        }
        return DataHandling.HANDLED
    }

    private fun receiveStart(message: PrivateListeningMessage, descriptor: ChannelDescriptor) {
        val id = message.text(0)
        if (stoppingService != null || terminal != null) { reply(id, 2); return }
        val previous = current
        if (previous != null) {
            if (previous.id != id) reply(id, 2)
            else if (previous.ready) reply(id, 0)
            return
        }
        if (id in retiredIDs || exhaustedIDs) { reply(id, 2); return }
        // Retain a bounded channel-local replay set; exhaustion refuses starts instead of forgetting old IDs.
        retiredIDs.add(id)
        if (retiredIDs.size >= 256) exhaustedIDs = true
        val local = localFingerprint
        if (!consentEnabled || local == null || !preferences.enabled(local, descriptor.peer)) {
            reply(id, 1); return
        }
        if (!startupAllowed(descriptor.peer)) { reply(id, 4); return }
        val request = PrivateListeningRequest(id, descriptor, now(), channel?.maintenance?.elapsedMillis ?: 0)
        current = request
        state = 1
        status = "Preparing headphones for ${descriptor.peer.deviceName}…"
        ownershipChanged(true)
        statusAt = 0
        if (automaticTicks) {
            tickJob = scope.launch {
                while (current === request) { tick(); delay(100) }
            }
        }
        try { startService(request) }
        catch (_: SecurityException) { failed(request, 4, "Background service startup was blocked.") }
        catch (_: IllegalStateException) { failed(request, 4, "Open aniCe on the phone, then retry.") }
    }

    internal fun request(id: String, instance: String): PrivateListeningRequest? =
        current?.takeIf { it.id == id && it.descriptor.instance == instance }

    internal fun serviceAttached(request: PrivateListeningRequest, owner: Any, output: PrivateListeningOutput): Boolean {
        val excluded = maxOf(0, (channel?.maintenance?.elapsedMillis ?: 0) - request.maintenanceAtStart)
        if (current !== request || now() - request.startedAt - excluded >= 5000) return false
        request.foregroundOwner = owner
        request.output = output
        serviceOwnershipChanged(request, owner, true)
        return true
    }

    internal fun ready(request: PrivateListeningRequest) {
        if (current !== request || request.output == null) return
        val excluded = maxOf(0, (channel?.maintenance?.elapsedMillis ?: 0) - request.maintenanceAtStart)
        if (now() - request.startedAt - excluded >= 5000) {
            failed(request, 9, "Headphone preparation timed out."); return
        }
        if (!transferReady()) {
            failed(request, 9, "The active transfer did not drain in time."); return
        }
        request.ready = true
        request.readyAt = now()
        request.readyMaintenance = channel?.maintenance?.elapsedMillis ?: 0
        request.peerAt = now()
        request.peerMaintenance = channel?.maintenance?.elapsedMillis ?: 0
        state = 5
        status = "Waiting for current Mac audio…"
        reply(request.id, 0)
    }

    internal fun failed(request: PrivateListeningRequest, result: Long, message: String) {
        if (current !== request) return
        val wasReady = request.ready
        stop(reason = if (result == 6L) 2 else 6, message = message, notify = wasReady)
        if (!wasReady) reply(request.id, result)
    }

    internal fun serviceDestroyed(request: PrivateListeningRequest, owner: Any) {
        serviceOwnershipChanged(request, owner, false)
        if (stoppingService === request && request.foregroundOwner === owner) stoppingService = null
        if (current === request && request.foregroundOwner === owner) {
            // Native destruction has already released this owner; do not wait for a second onDestroy.
            request.foregroundOwner = null
            stop(reason = 7, message = "Phone audio service ended.")
        }
    }

    internal fun playbackHealth(request: PrivateListeningRequest, health: ListeningPlaybackHealth) {
        if (current !== request) return
        request.positionFrames = health.positionFrames
        request.queuedFrames = health.queuedFrames
        request.underruns = health.underruns.coerceIn(0, 4294967295L)
        if (!request.focusPaused && !request.maintenanceActive && !request.priming) {
            state = if (health.rebuffering) 5 else 2
            status = if (health.rebuffering) "Buffering current Mac audio…" else "Listening to ${request.descriptor.peer.deviceName}."
        }
    }

    internal fun focusChanged(request: PrivateListeningRequest, granted: Boolean, permanent: Boolean = false) {
        if (current !== request) return
        if (permanent) { stop(reason = 1, message = "Another app took audio focus."); return }
        if (!request.ready && !granted) {
            failed(request, 5, "Phone audio focus changed during preparation.")
            return
        }
        request.focusPaused = !granted
        if (!granted) {
            request.pauseAt = request.pauseAt ?: now()
            request.preparationRevision += 1
            request.priming = false
            request.output?.pause()
            state = 3
            status = "Phone audio focus interrupted."
        } else {
            request.pauseAt = null
            if (request.firstAudioAt == null) {
                request.readyAt = now()
                request.readyMaintenance = channel?.maintenance?.elapsedMillis ?: 0
            }
            if (!request.maintenanceActive && request.ready) resumeOutput(request)
        }
        statusAt = 0
    }

    private fun resumeOutput(request: PrivateListeningRequest) {
        val output = request.output ?: return
        if (request.priming) return
        request.priming = true
        val revision = ++request.preparationRevision
        state = 5
        output.beginResume()
        scope.launch {
            try {
                output.resume()
                if (current === request && request.preparationRevision == revision) {
                    request.priming = false
                    status = "Buffering current Mac audio…"
                }
            } catch (_: CancellationException) {
                if (current === request && request.preparationRevision == revision) {
                    request.priming = false
                    failed(request, 8, "Headphone re-preparation was cancelled.")
                }
            } catch (_: Exception) {
                if (current === request && request.preparationRevision == revision) {
                    failed(request, 6, "Headphone route could not be verified.")
                }
            }
        }
    }

    internal fun reflectMaintenance() {
        val request = current ?: return
        val maintenance = channel?.maintenance
        val total = maintenance?.elapsedMillis ?: 0
        val active = maintenance?.active == true
        if (active == request.maintenanceActive && total == request.maintenanceTotal) return
        val wasActive = request.maintenanceActive
        val completed = !active && total > request.maintenanceTotal
        request.maintenanceTotal = total
        request.maintenanceActive = active
        if (active && !wasActive || completed) {
            request.preparationRevision += 1
            request.priming = false
            request.output?.pause()
        }
        if (active) {
            state = 4
            status = "Renewing secure LAN…"
            outgoing.removeAll { it.kind == 5L }
        } else if (request.ready && !request.focusPaused && (wasActive || completed)) {
            resumeOutput(request)
        }
    }

    internal fun tick() {
        val request = current ?: return
        reflectMaintenance()
        if (current !== request) return
        if (request.pauseAt?.let { now() - it >= 90000 } == true) {
            stop(reason = 7, message = "Phone audio interruption expired."); return
        }
        val maintenance = channel?.maintenance
        val excludedStart = maxOf(0, (maintenance?.elapsedMillis ?: 0) - request.maintenanceAtStart)
        if (maintenance?.active != true) {
            if (!request.ready && now() - request.startedAt - excludedStart >= 5000) {
                failed(request, 9, "Headphone preparation timed out."); return
            }
            val excludedPeer = maxOf(0, (maintenance?.elapsedMillis ?: 0) - request.peerMaintenance)
            val firstAudioExpired = request.readyAt?.let {
                val excluded = maxOf(0, (maintenance?.elapsedMillis ?: 0) - request.readyMaintenance)
                request.firstAudioAt == null && now() - it - excluded >= 5000
            } == true
            if (request.ready && ((firstAudioExpired && !request.focusPaused) ||
                    now() - request.peerAt - excludedPeer >= 10000)) {
                stop(reason = 3, message = "Mac audio stopped responding."); return
            }
            if (request.ready && now() - statusAt >= 1000) {
                statusAt = now()
                enqueue(PrivateListeningMessage(5, listOf(Cbor.Text(request.id), Cbor.Integer(1),
                    Cbor.Integer(state), Cbor.Integer(request.lastSequence), Cbor.Integer(request.positionFrames),
                    Cbor.Integer(request.queuedFrames.toLong()), Cbor.Integer(request.underruns))))
            }
        }
        pump()
    }

    fun stop(reason: Long = 0, message: String = "Listening stopped.", notify: Boolean = true) {
        val request = current
        generation += 1
        current = null
        tickJob?.cancel(); tickJob = null
        sending?.cancel(); sending = null
        outgoing.clear()
        terminal = null
        state = 0
        status = message
        if (request != null) {
            if (request.foregroundOwner != null) stoppingService = request
            request.preparationRevision += 1
            try { request.output?.close() }
            catch (error: Exception) { status = "Listening ended, but native cleanup failed: ${error.message}" }
            finally {
                try { request.foregroundOwner?.let { serviceOwnershipChanged(request, it, false) } }
                finally {
                    try { stopService(request) }
                    finally { ownershipChanged(false) }
                }
            }
            if (notify && channel?.descriptor == request.descriptor) {
                terminal = PrivateListeningMessage(4, listOf(Cbor.Text(request.id), Cbor.Integer(reason)))
                pump()
            }
        }
    }

    fun invalidate() {
        stop(reason = 7, message = "Device trust or local identity changed.", notify = false)
        localLookup?.cancel()
        localFingerprint = null
        consentEnabled = false
        outgoing.clear()
        terminal = null
    }

    override suspend fun drain(descriptor: ChannelDescriptor) {
        if (channel?.descriptor == descriptor) stop(reason = 3, message = "Mac closed LAN.", notify = false)
    }

    private fun reply(id: String, result: Long) = enqueue(
        PrivateListeningMessage(2, listOf(Cbor.Text(id), Cbor.Integer(result))))

    private fun enqueue(message: PrivateListeningMessage) {
        if (message.kind == 0L || message.kind == 5L) outgoing.removeAll { it.kind == message.kind }
        if (outgoing.size >= 8) return
        outgoing.addLast(message)
        pump()
    }

    private fun pump() {
        val channel = channel ?: return
        if (sending != null || channel.maintenance?.active == true || (outgoing.isEmpty() && terminal == null)) return
        val token = generation
        val work = scope.launch(start = CoroutineStart.LAZY) {
            try {
                while (token == generation && this@PrivateListeningController.channel === channel &&
                        (outgoing.isNotEmpty() || terminal != null)) {
                    val message = terminal?.also { terminal = null } ?: outgoing.removeFirst()
                    try { channel.sendData(message.encode()) }
                    catch (_: SessionBackpressure) {
                        if (token == generation) {
                            if (message.kind == 4L) terminal = message
                            else {
                                if (outgoing.size == 8) outgoing.removeLast()
                                outgoing.addFirst(message)
                            }
                        }
                        return@launch
                    }
                }
            } catch (_: CancellationException) {
            } catch (_: Exception) {
                if (token == generation) stop(reason = 3, message = "Listening DATA could not be sent.", notify = false)
            } finally { if (token == generation) sending = null }
        }
        sending = work
        work.start()
    }
}
