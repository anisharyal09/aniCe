// SPDX-License-Identifier: GPL-3.0-or-later
// Owns one user-authorized phone-to-Mac capture operation with a bounded current-audio window.
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

/** The activity's single-use projection grant. No owner retains it after the service handoff. */
internal class PhoneAudioGrant(val resultCode: Int, intent: Any) {
    private var projection: Any? = intent
    @Synchronized fun consume(): Any? = projection.also { projection = null }
    @Synchronized fun discard() { projection = null }
    val unused: Boolean @Synchronized get() = projection != null
}

private data class PhoneAudioConsentRequest(val id: String, val descriptor: ChannelDescriptor, val generation: Int)

/** Exposes a prepared native capture to the owner without granting it permission or projection ownership. */
internal interface PhoneAudioCaptureControl {
    fun start()
    fun close()
    val available: Boolean get() = true
}

internal data class PhoneAudioPacket(val sequence: Long, val pcm: ByteArray, val capturedAtNanos: Long? = null)

/** Keeps three unsent packets plus at most one in-flight send; overflow drops the oldest unsealed PCM. */
internal class PhoneAudioSendWindow(private val capacity: Int = UNSENT_CAPACITY) {
    private val packets = ArrayDeque<PhoneAudioPacket>()
    var dropped = 0L
        private set

    fun offer(packet: PhoneAudioPacket) {
        if (packets.size >= capacity) {
            packets.removeFirst()
            dropped += 1
        }
        packets.addLast(packet)
    }

    fun take(): PhoneAudioPacket? = packets.removeFirstOrNull()

    fun clear() = packets.clear()

    val size get() = packets.size

    internal companion object { const val UNSENT_CAPACITY = 3 }
}

internal class PhoneAudioRequest(
    val id: String,
    val descriptor: ChannelDescriptor,
    val startedAt: Long,
    val maintenanceAtStart: Long,
    val diagnostics: PhoneAudioDiagnostics? = null,
) {
    @Volatile var ready = false
    var captureStarted = false
    var capturePrepared = false
    var serviceOwner: Any? = null
    var control: PhoneAudioCaptureControl? = null
    var maintenanceActive = false
    var maintenanceTotal = maintenanceAtStart
    var lastCapturedSequence = 0L
    var sentPackets = 0L
    var droppedPackets = 0L
}

class PhoneAudioController internal constructor(
    private val now: () -> Long = { android.os.SystemClock.elapsedRealtime() },
    dispatcher: CoroutineDispatcher = Dispatchers.Main.immediate,
    private val automaticTicks: Boolean = true,
) : FeatureHandler {
    private val scope = CoroutineScope(SupervisorJob() + dispatcher)
    @Volatile private var channel: SecuredChannel? = null
    @Volatile private var current: PhoneAudioRequest? = null
    private var stoppingService: PhoneAudioRequest? = null
    private var consentRequest: PhoneAudioConsentRequest? = null
    private val window = PhoneAudioSendWindow()
    private val lock = Any()
    private val outgoing = ArrayDeque<PhoneAudioMessage>()
    private var terminal: PhoneAudioMessage? = null
    private var sending = false
    private var inFlightKind: Long? = null
    private var waitingForCapacity = false
    private var packetWakeScheduled = false
    private var sendJob: Job? = null
    private var tickJob: Job? = null
    private var generation = 0
    private var diagnosticRun = 0L
    internal var diagnosticsEnabled = false
    internal var diagnosticNanoTime: () -> Long = System::nanoTime
    internal var diagnosticSink: (PhoneAudioDiagnosticReport) -> Unit = {}
    internal var diagnosticActivity: () -> Triple<Boolean?, Boolean?, Boolean?> = { Triple(null, null, null) }

    var state by mutableStateOf(0L)
        private set
    var status by mutableStateOf("Connect your trusted Mac over LAN, then allow phone audio on the Mac.")
        private set
    var peer by mutableStateOf<DeviceIdentity?>(null)
        private set
    var macReceiving by mutableStateOf(false)
        private set
    var active by mutableStateOf(false)
        private set
    var droppedPackets by mutableStateOf(0L)
        private set
    var consentPending by mutableStateOf(false)
        private set
    var stopping by mutableStateOf(false)
        private set
    var controlPending by mutableStateOf(false)
        private set
    val busy get() = active || stopping
    val canStart get() = peer != null && macReceiving && !busy && !consentPending &&
        !controlPending && !forwardActive() && channel?.maintenance?.active != true

    internal var forwardActive: () -> Boolean = { false }
    internal var startService: (PhoneAudioRequest, PhoneAudioGrant) -> Unit = { _, _ ->
        throw IllegalStateException("Phone audio service is unavailable")
    }
    internal var stopService: (PhoneAudioRequest) -> Unit = {}
    internal var serviceOwnershipChanged: (PhoneAudioRequest, Any, Boolean) -> Unit = { _, _, _ -> }

    /** The native prompt is bound to the channel selected by this local action, not a later connection. */
    internal fun requestConsent(): String? {
        if (consentPending || !admitStart()) return null
        val descriptor = channel?.descriptor ?: return null
        val attempt = PhoneAudioConsentRequest(java.util.UUID.randomUUID().toString(), descriptor, generation)
        consentRequest = attempt
        consentPending = true
        return attempt.id
    }

    internal fun consentIsCurrent(id: String?): Boolean {
        val attempt = consentRequest ?: return false
        return attempt.id == id && attempt.generation == generation && channel?.descriptor == attempt.descriptor
    }

    internal fun completeConsent(id: String?, authorization: PhoneAudioGrant) {
        if (!consentIsCurrent(id)) {
            authorization.discard()
            return
        }
        consentRequest = null
        consentPending = false
        begin(authorization)
    }

    /** Internal local-action entry point; no DATA handler or persisted preference can supply a grant. */
    internal fun begin(authorization: PhoneAudioGrant) {
        try {
            if (!authorization.unused || !admitStart()) return
            val channel = channel ?: return
            val request = PhoneAudioRequest(java.util.UUID.randomUUID().toString(), channel.descriptor,
                now(), channel.maintenance?.elapsedMillis ?: 0,
                if (diagnosticsEnabled) PhoneAudioDiagnostics(++diagnosticRun, diagnosticNanoTime) else null)
            synchronized(lock) { current = request }
            active = true
            state = 1
            droppedPackets = 0
            status = "Preparing to send this phone's audio…"
            startTicks()
            try { startService(request, authorization) }
            catch (_: SecurityException) { failed(request, 4, "Phone audio background service was blocked."); return }
            catch (_: IllegalStateException) { failed(request, 4, "Open aniCe on the phone, then retry."); return }
            if (current === request) sendControl(PrivateListeningMessage.start(request.id))
        } finally { authorization.discard() }
    }

    private fun admitStart(): Boolean {
        if (current != null) return false
        if (stopping || controlPending) { status = "Finishing the previous phone audio operation…"; return false }
        if (channel == null) { status = "Connect your trusted Mac over LAN first."; return false }
        if (!macReceiving) { status = "Allow phone audio on your Mac first."; return false }
        if (forwardActive()) { status = "Stop listening to this Mac before sending phone audio."; return false }
        if (channel?.maintenance?.active == true) { status = "Wait for secure LAN renewal, then retry."; return false }
        return true
    }

    fun stop(reason: Long = 0, message: String = "Phone audio stopped.", notify: Boolean = true) {
        val request = current
        generation += 1
        synchronized(lock) { current = null }
        active = false
        consentRequest = null
        consentPending = false
        tickJob?.cancel(); tickJob = null
        // A cancelled pump must not leave the sender latched, or the next Start would never leave.
        sendJob?.cancel(); sendJob = null
        synchronized(lock) {
            sending = false
            inFlightKind = null
        }
        state = 0
        status = message
        synchronized(lock) {
            window.clear()
            outgoing.clear()
        }
        terminal = null
        if (request != null) {
            val owner = request.serviceOwner
            if (owner != null) { stoppingService = request; stopping = true }
            try { request.control?.close() }
            catch (_: Exception) { status = "Phone audio ended, but native cleanup failed." }
            finally {
                try { if (owner != null) serviceOwnershipChanged(request, owner, false) }
                finally { try { stopService(request) } catch (_: Exception) {} }
            }
        }
        if (notify && request != null && channel?.descriptor == request.descriptor) {
            terminal = reverse(PrivateListeningMessage(4, listOf(Cbor.Text(request.id), Cbor.Integer(reason))))
            pump()
        }
        if (request != null) reportDiagnostics(request, terminal = true)
        reflectControlPending()
    }

    internal fun capturePermissionDenied(id: String?) = cancelConsent(id, "Audio capture permission is required.")
    internal fun captureConsentDenied(id: String?) = cancelConsent(id, "Screen capture consent was cancelled.")
    private fun cancelConsent(id: String?, message: String) {
        if (consentRequest?.id != id || id == null) return
        consentRequest = null
        consentPending = false
        if (!active) status = message
    }

    override fun available(channel: SecuredChannel) {
        val descriptor = channel.descriptor
        if (descriptor.transport != "lan" || descriptor.peer.platform != "macos") return
        if (this.channel?.descriptor == descriptor) return
        this.channel?.let { retired(it.descriptor) }
        this.channel = channel
        peer = descriptor.peer
        macReceiving = false
        state = 0
        status = "Waiting for this Mac to allow phone audio."
        synchronized(lock) {
            window.clear()
            outgoing.clear()
        }
        terminal = null
        waitingForCapacity = false
        reflectControlPending()
    }

    override fun retired(descriptor: ChannelDescriptor) {
        if (channel?.descriptor != descriptor) return
        stop(reason = 3, message = "LAN ended. Start phone audio again after reconnecting.", notify = false)
        channel = null
        peer = null
        macReceiving = false
        synchronized(lock) {
            window.clear()
            outgoing.clear()
        }
        terminal = null
        waitingForCapacity = false
        reflectControlPending()
    }

    override fun capacityAvailable(descriptor: ChannelDescriptor) {
        if (channel?.descriptor != descriptor) return
        waitingForCapacity = false
        reflectMaintenance()
        pump()
    }

    override suspend fun handle(descriptor: ChannelDescriptor, bytes: ByteArray): DataHandling {
        if (channel?.descriptor != descriptor) return DataHandling.UNRECOGNIZED
        val message = try {
            PhoneAudioMessage.decode(bytes) ?: return DataHandling.UNRECOGNIZED
        } catch (_: PrivateListeningWireException) {
            stop(reason = 5, message = "Invalid phone audio message.")
            return DataHandling.DISCARDED
        } catch (_: io.github.anisharyal09.anice.infrastructure.session.SessionException) {
            stop(reason = 5, message = "Invalid phone audio message.")
            return DataHandling.DISCARDED
        }
        return when (message.kind) {
            0L -> {
                macReceiving = message.flag(4)
                if (!macReceiving) {
                    consentRequest = null
                    consentPending = false
                }
                if (!macReceiving && current != null) stop(message = "Phone audio was disabled on the Mac.", notify = false)
                else if (current == null) status = if (macReceiving) "Ready to send this phone's audio to the Mac."
                    else "Allow phone audio on your Mac first."
                DataHandling.HANDLED
            }
            2L -> {
                val request = current
                if (request != null && message.text(0) == request.id) receiveResult(request, message.number(1))
                DataHandling.HANDLED
            }
            4L -> {
                val request = current
                if (request != null && message.text(0) == request.id) {
                    stop(reason = message.number(1), message = "Phone audio ended on the Mac.", notify = false)
                    DataHandling.HANDLED
                } else DataHandling.DISCARDED
            }
            else -> DataHandling.DISCARDED
        }
    }

    internal fun request(id: String, instance: String): PhoneAudioRequest? =
        current?.takeIf { it.id == id && it.descriptor.instance == instance }

    internal fun serviceAttached(request: PhoneAudioRequest, owner: Any, control: PhoneAudioCaptureControl): Boolean {
        val excluded = maxOf(0, (channel?.maintenance?.elapsedMillis ?: 0) - request.maintenanceAtStart)
        if (current !== request || request.control != null ||
            now() - request.startedAt - excluded >= 5000) return false
        request.serviceOwner = owner
        request.control = control
        serviceOwnershipChanged(request, owner, true)
        startCaptureIfReady(request)
        return current === request
    }

    internal fun serviceDestroyed(request: PhoneAudioRequest, owner: Any) {
        serviceOwnershipChanged(request, owner, false)
        if (stoppingService === request && request.serviceOwner === owner) {
            stoppingService = null
            stopping = false
        }
        if (current === request && request.serviceOwner === owner) {
            request.serviceOwner = null
            stop(reason = 7, message = "Phone audio service ended.")
        }
    }

    /** Called from the capture worker; never blocks on LAN and never touches presentation state. */
    internal fun capturePacket(request: PhoneAudioRequest, sequence: Long, pcm: ByteArray) {
        var wakeScheduledAt: Long? = null
        synchronized(lock) {
            if (current !== request || !request.ready || pcm.size != PrivateListeningMessage.PCM_BYTES) return
            if (sequence <= request.lastCapturedSequence) return
            request.lastCapturedSequence = sequence
            val capturedAt = request.diagnostics?.captured()
            if (channel?.maintenance?.active == true) {
                request.droppedPackets += 1
                request.diagnostics?.maintenanceDiscarded(1)
            } else {
                val before = window.dropped
                window.offer(PhoneAudioPacket(sequence, pcm, capturedAt))
                request.droppedPackets += window.dropped - before
                request.diagnostics?.queued(window.size, window.dropped - before)
            }
            // At most one Main wake-up is outstanding, even when the capture worker keeps running.
            if (packetWakeScheduled) return
            packetWakeScheduled = true
            wakeScheduledAt = request.diagnostics?.timestamp()
        }
        scope.launch {
            if (current === request) request.diagnostics?.presentationReady(wakeScheduledAt)
            synchronized(lock) {
                packetWakeScheduled = false
                current?.let { droppedPackets = it.droppedPackets }
            }
            reflectMaintenance()
            pump()
        }
    }

    internal fun captureStopped(request: PhoneAudioRequest, cause: PhoneAudioStopCause) {
        if (current !== request) return
        when (cause) {
            PhoneAudioStopCause.LOCAL -> stop(reason = 0, message = "Phone audio capture ended.")
            PhoneAudioStopCause.REVOKED ->
                stop(reason = 4, message = "Screen capture consent ended. Start again to send audio.")
            PhoneAudioStopCause.FAILURE -> stop(reason = 6, message = "Phone audio capture failed.")
        }
    }

    internal fun captureFailed(request: PhoneAudioRequest, message: String) {
        if (current !== request) return
        failed(request, if (request.ready) 6 else 4, message)
    }

    fun invalidate() {
        stop(reason = 7, message = "Device trust or local identity changed.", notify = false)
        channel = null
        peer = null
        macReceiving = false
        synchronized(lock) {
            window.clear()
            outgoing.clear()
        }
        terminal = null
        waitingForCapacity = false
        reflectControlPending()
    }

    override suspend fun drain(descriptor: ChannelDescriptor) {
        if (channel?.descriptor == descriptor) stop(reason = 3, message = "Mac closed LAN.", notify = false)
    }

    private fun receiveResult(request: PhoneAudioRequest, result: Long) {
        if (current !== request) return
        if (request.ready) return
        val excluded = maxOf(0, (channel?.maintenance?.elapsedMillis ?: 0) - request.maintenanceAtStart)
        if (now() - request.startedAt - excluded >= 5000) {
            failed(request, 9, "The Mac did not accept phone audio in time.")
            return
        }
        if (result != 0L) {
            stop(reason = if (result == 2L) 2 else 6, message = resultMessage(result), notify = false)
            return
        }
        request.ready = true
        startCaptureIfReady(request)
    }

    private fun startCaptureIfReady(request: PhoneAudioRequest) {
        val control = request.control ?: return
        if (current !== request || !request.ready || request.captureStarted) return
        try {
            check(control.available)
            request.captureStarted = true
            control.start()
            if (current === request && !request.capturePrepared) {
                state = if (channel?.maintenance?.active == true) 4 else 1
                status = if (state == 4L) "Renewing secure LAN…" else "Starting phone audio capture…"
            }
        } catch (_: Exception) { failed(request, 6, "Phone audio capture could not start.") }
    }

    internal fun capturePrepared(request: PhoneAudioRequest) {
        if (current !== request || !request.ready || !request.captureStarted) return
        val excluded = maxOf(0, (channel?.maintenance?.elapsedMillis ?: 0) - request.maintenanceAtStart)
        if (now() - request.startedAt - excluded >= 5000) {
            failed(request, 9, "Phone audio capture preparation timed out.")
            return
        }
        request.capturePrepared = true
        state = if (channel?.maintenance?.active == true) 4 else 2
        status = if (state == 4L) "Renewing secure LAN…"
            else "Sending this phone's audio to ${request.descriptor.peer.deviceName}."
    }

    private fun failed(request: PhoneAudioRequest, result: Long, message: String) {
        if (current !== request) return
        stop(reason = if (result == 2L || result == 4L) 4 else 6, message = message)
    }

    private fun reflectMaintenance() {
        val request = current ?: return
        val active = channel?.maintenance?.active == true
        val total = channel?.maintenance?.elapsedMillis ?: 0
        val completed = !active && total > request.maintenanceTotal
        if (active == request.maintenanceActive && !completed) return
        request.maintenanceActive = active
        request.maintenanceTotal = total
        synchronized(lock) {
            request.droppedPackets += window.size
            request.diagnostics?.maintenanceDiscarded(window.size)
            window.clear()
            droppedPackets = request.droppedPackets
        }
        // Cancellation applies only before sealing; the session still owns sealed ordered records.
        if (inFlightKind == 3L) sendJob?.cancel()
        if (!active) waitingForCapacity = false
        if (!active && request.captureStarted && request.control?.available != true) {
            failed(request, 6, "Phone audio capture ended during LAN renewal.")
        } else if (active) {
            state = 4
            status = "Renewing secure LAN…"
        } else if (request.capturePrepared) {
            state = 2
            status = "Sending this phone's audio to ${request.descriptor.peer.deviceName}."
        } else {
            state = 1
            status = "Preparing to send this phone's audio…"
        }
    }

    private fun startTicks() {
        if (!automaticTicks) return
        tickJob = scope.launch {
            while (current != null) { tick(); delay(100) }
        }
    }

    internal fun tick() {
        val request = current ?: return
        reportDiagnostics(request)
        reflectMaintenance()
        if (current !== request) return
        if (channel?.maintenance?.active != true && (!request.ready || !request.capturePrepared)) {
            val excluded = maxOf(0, (channel?.maintenance?.elapsedMillis ?: 0) - request.maintenanceAtStart)
            if (now() - request.startedAt - excluded >= 5000) {
                failed(request, 9, if (request.ready) "Phone audio capture preparation timed out."
                    else "The Mac did not accept phone audio in time.")
                return
            }
        }
        pump()
    }

    private fun sendControl(message: PrivateListeningMessage) {
        synchronized(lock) {
            if (outgoing.size >= 8) return
            outgoing.addLast(reverse(message))
        }
        reflectControlPending()
        pump()
    }

    private fun pump() {
        val channel = channel ?: return
        synchronized(lock) {
            if (sending || waitingForCapacity || channel.maintenance?.active == true) return
            if (terminal == null && outgoing.isEmpty() && window.size == 0) return
            sending = true
        }
        val token = generation
        val work = scope.launch(start = CoroutineStart.LAZY) {
            try {
                while (token == generation && this@PhoneAudioController.channel === channel) {
                    if (channel.maintenance?.active == true) break
                    val request = current
                    var capturedAt: Long? = null
                    val message = synchronized(lock) {
                        val boundary = terminal
                        if (boundary != null) { terminal = null; boundary }
                        else outgoing.removeFirstOrNull()
                            ?: window.take()?.let { packet ->
                                if (request?.ready == true) {
                                    capturedAt = packet.capturedAtNanos
                                    reverse(PrivateListeningMessage.audio(request.id, packet.sequence, packet.pcm))
                                } else null
                            }
                    } ?: break
                    inFlightKind = message.kind
                    reflectControlPending()
                    val diagnostics = if (message.kind == 3L) request?.diagnostics else null
                    diagnostics?.dequeued(capturedAt)
                    val encodeStarted = diagnostics?.timestamp()
                    val encoded = message.encode()
                    diagnostics?.encoded(encodeStarted)
                    val submissionStarted = diagnostics?.timestamp()
                    try {
                        channel.sendData(encoded)
                        diagnostics?.submitted(submissionStarted, succeeded = true)
                        if (token == generation && message.kind == 3L && request != null) request.sentPackets += 1
                    } catch (_: SessionBackpressure) {
                        diagnostics?.submitted(submissionStarted, succeeded = false)
                        diagnostics?.backpressured()
                        if (token == generation) {
                            retainControlOrDropAudio(message, request)
                            waitingForCapacity = true
                        }
                        break
                    } catch (error: CancellationException) {
                        diagnostics?.submitted(submissionStarted, succeeded = false)
                        diagnostics?.sendCancelled()
                        if (token == generation) retainControlOrDropAudio(message, request)
                        throw error
                    } finally {
                        if (token == generation) { inFlightKind = null; reflectControlPending() }
                    }
                }
            } catch (_: CancellationException) {
            } catch (_: Exception) {
                if (token == generation) stop(reason = 3, message = "Phone audio DATA could not be sent.", notify = false)
            } finally {
                if (token == generation) {
                    val pending = synchronized(lock) {
                        sending = false
                        sendJob = null
                        inFlightKind = null
                        terminal != null || outgoing.isNotEmpty() || window.size > 0
                    }
                    reflectControlPending()
                    if (pending && !waitingForCapacity && channel.maintenance?.active != true) scope.launch { pump() }
                }
            }
        }
        sendJob = work
        work.start()
    }

    private fun retainControlOrDropAudio(message: PhoneAudioMessage, request: PhoneAudioRequest?) {
        synchronized(lock) {
            when (message.kind) {
                4L -> terminal = message
                3L -> if (current === request && request != null) {
                    request.droppedPackets += 1
                    droppedPackets = request.droppedPackets
                }
                else -> {
                    if (outgoing.size == 8) outgoing.removeLast()
                    outgoing.addFirst(message)
                }
            }
        }
        reflectControlPending()
    }

    private fun reflectControlPending() {
        controlPending = terminal != null || outgoing.isNotEmpty() ||
            (inFlightKind != null && inFlightKind != 3L)
    }

    private fun reportDiagnostics(request: PhoneAudioRequest, terminal: Boolean = false) {
        val diagnostics = request.diagnostics ?: return
        if (!terminal && !diagnostics.enabled) return
        // Observational failures must never stop capture, change consent or block native teardown.
        try {
            val activity = diagnosticActivity()
            val context = synchronized(lock) {
                PhoneAudioDiagnosticContext(state, window.size, inFlightKind == 3L,
                    channel?.maintenance?.active == true, request.control?.available,
                    activity.first, activity.second, activity.third)
            }
            diagnostics.report(context, terminal)?.let(diagnosticSink)
        } catch (_: Exception) {}
    }

    private fun reverse(message: PrivateListeningMessage) = PhoneAudioMessage.from(message)

    private fun resultMessage(result: Long): String = when (result) {
        1L -> "Allow phone audio on the Mac first."
        2L -> "The Mac is already receiving phone audio."
        3L -> "The Mac does not support this phone audio format."
        4L -> "The Mac blocked phone audio startup."
        5L -> "The Mac could not take audio focus."
        6L -> "The Mac audio output is unavailable."
        7L -> "The Mac could not set up its notification."
        8L -> "The Mac could not start phone audio."
        else -> "The Mac did not accept phone audio in time."
    }
}
