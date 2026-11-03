// SPDX-License-Identifier: GPL-3.0-or-later
// Owns the Android side of one bounded Phone-to-Mac session on an authenticated BLE channel.
package io.github.anisharyal09.anice.features.phoneinput

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
import io.github.anisharyal09.anice.infrastructure.session.SessionException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.UUID

enum class PhoneInputState { IDLE, STARTING, ACTIVE }

class PhoneInputController(
    private val dispatcher: CoroutineDispatcher = Dispatchers.Main.immediate,
) : FeatureHandler {
    private class Link(val channel: SecuredChannel) {
        var remoteTextBytes = 0L
        var remoteEvents = 0L
        val queue = ArrayDeque<ByteArray>()
        var pendingPointer: PendingPointer? = null
        var pointerFlushJob: Job? = null
        var sending = false
        var wake = false
    }

    // Keep pointer and scroll coalescing separate so changing gesture types preserves order.
    private enum class PointerKind(val messageKind: Long) { MOTION(6), SCROLL(8) }
    private data class PendingPointer(
        val sessionId: String,
        val kind: PointerKind,
        var horizontal: Long = 0,
        var vertical: Long = 0,
    )

    private data class PendingStart(val id: String, val peer: DeviceIdentity, var cancelled: Boolean = false)
    private data class ActiveSession(val id: String, var sequence: Long = 0L)

    private val scope = CoroutineScope(SupervisorJob() + dispatcher)
    private var link: Link? = null
    private var pendingStart: PendingStart? = null
    private var startTimeout: Job? = null
    private var activeSession: ActiveSession? = null
    var state by mutableStateOf(PhoneInputState.IDLE)
        private set
    var status by mutableStateOf("Connect to your Mac over Bluetooth to get started.")
        private set

    val active: Boolean get() = state == PhoneInputState.ACTIVE

    fun connected(peer: DeviceIdentity): Boolean = liveLink(peer) != null

    /** Returns this authenticated Mac's current per-record text limit. */
    fun maximumTextBytes(peer: DeviceIdentity): Int? = liveLink(peer)?.remoteTextBytes?.toInt()

    fun compatible(peer: DeviceIdentity): Boolean {
        val current = liveLink(peer) ?: return false
        return current.remoteTextBytes > 0 && (current.remoteEvents and REQUIRED_INPUT_EVENTS) == REQUIRED_INPUT_EVENTS
    }

    fun supportsPointer(peer: DeviceIdentity): Boolean =
        (liveLink(peer)?.remoteEvents?.and(POINTER_INPUT_EVENT) ?: 0L) != 0L

    fun canStart(peer: DeviceIdentity): Boolean = compatible(peer) &&
        state == PhoneInputState.IDLE && pendingStart == null

    fun start(peer: DeviceIdentity): Boolean {
        if (state != PhoneInputState.IDLE || pendingStart != null) return false
        val current = liveLink(peer)
        if (current == null) {
            status = "Connect to this Mac over Bluetooth first."
            return false
        }
        if (current.remoteTextBytes == 0L || (current.remoteEvents and REQUIRED_INPUT_EVENTS) != REQUIRED_INPUT_EVENTS) {
            status = "Update aniCe on your Mac to enable phone typing."
            return false
        }

        val request = PendingStart(UUID.randomUUID().toString(), peer)
        pendingStart = request
        state = PhoneInputState.STARTING
        status = "Waiting for your Mac…"
        if (!enqueue(current, PhoneInputMessage.of(2, Cbor.Text(request.id)))) {
            pendingStart = null
            state = PhoneInputState.IDLE
            status = "The Bluetooth connection is busy. Try again."
            return false
        }
        startTimeout = scope.launch {
            delay(START_TIMEOUT_MILLIS)
            if (pendingStart === request) {
                request.cancelled = true
                state = PhoneInputState.IDLE
                status = "Mac did not respond. Reconnect before trying again."
            }
        }
        return true
    }

    /** Stops immediately in the UI and orders release-all before the session boundary on the wire. */
    fun stop() {
        pendingStart?.let { request ->
            request.cancelled = true
            startTimeout?.cancel()
            startTimeout = null
            state = PhoneInputState.IDLE
            status = "Typing stopped."
            return
        }
        val session = activeSession ?: run {
            state = PhoneInputState.IDLE
            return
        }
        activeSession = null
        state = PhoneInputState.IDLE
        status = "Typing stopped."
        sendTerminal(session)
    }

    fun sendText(plan: PhoneInputTextPlan): Boolean {
        val session = activeSession ?: return false
        val current = link ?: return false
        if (!live(current.channel.descriptor)) return false
        if (plan.actions.any { action ->
                action is PhoneInputTextAction.Commit &&
                    action.value.toByteArray(Charsets.UTF_8).size > current.remoteTextBytes
            }) {
            abortSession(session, "The Mac's text limit changed. Typing stopped.")
            return false
        }

        val messageCount = plan.actions.sumOf { action ->
            when (action) {
                is PhoneInputTextAction.Commit -> 1
                is PhoneInputTextAction.Backspace -> action.count * 2
            }
        }
        if (session.sequence + messageCount + TERMINAL_MESSAGES > MAX_SEQUENCE) {
            abortSession(session, "Input stopped at the session limit. Start a new session to continue.")
            return false
        }
        if (current.queue.size + messageCount + TERMINAL_MESSAGES > MAX_QUEUED_EVENTS) {
            abortSession(session)
            return false
        }
        flushPendingPointer(current, session, reserveMessages = messageCount)
        if (current.queue.size + messageCount + TERMINAL_MESSAGES > MAX_QUEUED_EVENTS) {
            abortSession(session)
            return false
        }

        for (action in plan.actions) {
            when (action) {
                is PhoneInputTextAction.Commit -> enqueueSession(
                    current, session, PhoneInputMessage.of(
                        4, Cbor.Text(session.id), sequence(session), Cbor.Text(action.value),
                    ),
                )
                is PhoneInputTextAction.Backspace -> repeat(action.count) {
                    enqueueSession(
                        current, session, PhoneInputMessage.of(
                            5, Cbor.Text(session.id), sequence(session), Cbor.Integer(BACKSPACE_USAGE.toLong()),
                            Cbor.Integer(0), Cbor.Bool(true),
                        ),
                    )
                    enqueueSession(
                        current, session, PhoneInputMessage.of(
                            5, Cbor.Text(session.id), sequence(session), Cbor.Integer(BACKSPACE_USAGE.toLong()),
                            Cbor.Integer(0), Cbor.Bool(false),
                        ),
                    )
                }
            }
        }
        pump(current)
        return true
    }

    fun sendKey(usage: Int, modifiers: Int, pressed: Boolean): Boolean {
        val session = activeSession ?: return false
        val current = link ?: return false
        if (!live(current.channel.descriptor) || (current.remoteEvents and KEY_TRANSITION_EVENT) == 0L ||
            usage !in 4..231 || modifiers !in 0..255) return false
        if (session.sequence + TERMINAL_MESSAGES + 1 > MAX_SEQUENCE) {
            abortSession(session, "Input stopped at the session limit. Start a new session to continue.")
            return false
        }
        if (current.queue.size + 1 + TERMINAL_MESSAGES > MAX_QUEUED_EVENTS) {
            abortSession(session)
            return false
        }
        flushPendingPointer(current, session, reserveMessages = 1)
        if (current.queue.size + 1 + TERMINAL_MESSAGES > MAX_QUEUED_EVENTS) {
            abortSession(session)
            return false
        }
        enqueueSession(
            current, session, PhoneInputMessage.of(
                5, Cbor.Text(session.id), sequence(session), Cbor.Integer(usage.toLong()),
                Cbor.Integer(modifiers.toLong()), Cbor.Bool(pressed),
            ),
        )
        pump(current)
        return true
    }

    fun sendPointerMotion(deltaX: Int, deltaY: Int): Boolean =
        accumulatePointer(PointerKind.MOTION, deltaX, deltaY)

    fun sendScroll(horizontal: Int, vertical: Int): Boolean =
        accumulatePointer(PointerKind.SCROLL, horizontal, vertical)

    fun sendPointerButtons(mask: Int, modifiers: Int = 0): Boolean {
        val session = activeSession ?: return false
        val current = link ?: return false
        if (!live(current.channel.descriptor) || !supportsPointer(current) || mask !in 0..7 || modifiers !in 0..255) {
            return false
        }
        if (session.sequence + TERMINAL_MESSAGES + 1 > MAX_SEQUENCE) {
            abortSession(session, "Input stopped at the session limit. Start a new session to continue.")
            return false
        }
        flushPendingPointer(current, session, reserveMessages = 1)
        if (current.queue.size + 1 + TERMINAL_MESSAGES > MAX_QUEUED_EVENTS) {
            abortSession(session)
            return false
        }
        enqueueSession(
            current, session, PhoneInputMessage.of(
                7, Cbor.Text(session.id), sequence(session), Cbor.Integer(mask.toLong()),
                Cbor.Integer(modifiers.toLong()),
            ),
        )
        pump(current)
        return true
    }

    private fun accumulatePointer(kind: PointerKind, horizontal: Int, vertical: Int): Boolean {
        val session = activeSession ?: return false
        val current = link ?: return false
        if (!live(current.channel.descriptor) || !supportsPointer(current)) return false
        if (horizontal == 0 && vertical == 0) return true
        if (session.sequence + TERMINAL_MESSAGES + 1 > MAX_SEQUENCE) {
            abortSession(session, "Input stopped at the session limit. Start a new session to continue.")
            return false
        }

        val pending = current.pendingPointer
        if (pending != null && (pending.sessionId != session.id || pending.kind != kind)) {
            flushPendingPointer(current, session, reserveMessages = 0)
            if (current.pendingPointer != null) current.pendingPointer = null
        }
        val accumulator = current.pendingPointer?.takeIf { it.sessionId == session.id && it.kind == kind }
            ?: PendingPointer(session.id, kind).also { current.pendingPointer = it }
        accumulator.horizontal = (accumulator.horizontal + horizontal).coerceIn(
            -MAX_PENDING_POINTER_DELTA, MAX_PENDING_POINTER_DELTA,
        )
        accumulator.vertical = (accumulator.vertical + vertical).coerceIn(
            -MAX_PENDING_POINTER_DELTA, MAX_PENDING_POINTER_DELTA,
        )
        schedulePointerFlush(current)
        return true
    }

    private fun schedulePointerFlush(current: Link) {
        if (current.pointerFlushJob?.isActive == true) return
        current.pointerFlushJob = scope.launch {
            delay(POINTER_FLUSH_MILLIS)
            if (live(current.channel.descriptor)) pump(current)
        }
    }

    // Keep high-rate deltas in one bounded slot and leave queue capacity for keys, clicks, and stop messages.
    private fun flushPendingPointer(
        current: Link,
        session: ActiveSession,
        reserveMessages: Int,
        flushAll: Boolean = true,
    ) {
        val pending = current.pendingPointer?.takeIf { it.sessionId == session.id } ?: return
        val queueLimit = MAX_QUEUED_EVENTS - TERMINAL_MESSAGES - reserveMessages
        var flushed = false
        while ((pending.horizontal != 0L || pending.vertical != 0L) && current.queue.size < queueLimit) {
            if (flushed && !flushAll) break
            if (session.sequence + TERMINAL_MESSAGES + reserveMessages + 1 > MAX_SEQUENCE) {
                clearPendingPointer(current)
                abortSession(session, "Input stopped at the session limit. Start a new session to continue.")
                return
            }
            val horizontal = pending.horizontal.coerceIn(-MAX_POINTER_DELTA, MAX_POINTER_DELTA).toInt()
            val vertical = pending.vertical.coerceIn(-MAX_POINTER_DELTA, MAX_POINTER_DELTA).toInt()
            pending.horizontal -= horizontal
            pending.vertical -= vertical
            val message = PhoneInputMessage.of(
                pending.kind.messageKind, Cbor.Text(session.id), sequence(session),
                Cbor.Integer(horizontal.toLong()), Cbor.Integer(vertical.toLong()),
            )
            val bytes = try { message.encode() } catch (_: Exception) { break }
            current.queue.addLast(bytes)
            flushed = true
        }
        if (pending.horizontal == 0L && pending.vertical == 0L) clearPendingPointer(current)
        // Motion may be dropped under pressure, but it never consumes slots reserved for discrete input.
        else if (reserveMessages > 0) clearPendingPointer(current)
    }

    private fun clearPendingPointer(current: Link) {
        current.pendingPointer = null
    }

    private fun supportsPointer(current: Link): Boolean =
        (current.remoteEvents and POINTER_INPUT_EVENT) != 0L

    override fun available(channel: SecuredChannel) {
        val descriptor = channel.descriptor
        if (descriptor.transport != "ble") return
        link?.let { retired(it.channel.descriptor) }
        val fresh = Link(channel)
        link = fresh
        enqueue(
            fresh,
            PhoneInputMessage.of(
                1, Cbor.Integer(PhoneInputMessage.MAX_TEXT_BYTES),
                Cbor.Integer(ANDROID_SUPPORTED_EVENTS),
            ),
        )
    }

    override fun retired(descriptor: ChannelDescriptor) {
        val current = link?.takeIf { it.channel.descriptor == descriptor } ?: return
        if (activeSession != null) {
            activeSession = null
            status = "Bluetooth disconnected. Typing stopped."
        } else if (pendingStart != null) {
            status = "Bluetooth disconnected before Mac was ready."
        }
        pendingStart = null
        startTimeout?.cancel()
        startTimeout = null
        current.queue.clear()
        clearPendingPointer(current)
        current.pointerFlushJob?.cancel()
        link = null
        state = PhoneInputState.IDLE
    }

    override fun capacityAvailable(descriptor: ChannelDescriptor) {
        val current = link?.takeIf { it.channel.descriptor == descriptor } ?: return
        if (current.sending) current.wake = true else pump(current)
    }

    override suspend fun handle(descriptor: ChannelDescriptor, bytes: ByteArray): DataHandling =
        withContext(dispatcher) {
            if (descriptor.transport != "ble") return@withContext DataHandling.UNRECOGNIZED
            val current = link?.takeIf { it.channel.descriptor == descriptor }
                ?: return@withContext DataHandling.DISCARDED
            val message = try {
                PhoneInputMessage.decode(bytes) ?: return@withContext DataHandling.UNRECOGNIZED
            } catch (_: PhoneInputWireException) {
                activeSession?.let { abortSession(it, "Invalid Mac input stopped this session.") }
                status = "The Mac sent an invalid input message. Reconnect to try again."
                return@withContext DataHandling.DISCARDED
            } catch (_: SessionException) {
                activeSession?.let { abortSession(it, "Invalid Mac input stopped this session.") }
                status = "The Mac sent an invalid input message. Reconnect to try again."
                return@withContext DataHandling.DISCARDED
            }

            when (message.kind) {
                1L -> {
                    current.remoteTextBytes = message.number(0)
                    current.remoteEvents = message.number(1)
                    if (state == PhoneInputState.IDLE && status.startsWith("Connect to your Mac")) {
                        status = if (current.remoteTextBytes > 0 &&
                            (current.remoteEvents and REQUIRED_INPUT_EVENTS) == REQUIRED_INPUT_EVENTS)
                            "Ready when your Mac is set up to receive input."
                        else "Update aniCe on your Mac to enable phone typing."
                    }
                    DataHandling.HANDLED
                }
                3L -> receiveStartResult(current, message)
                11L -> receiveEnd(message)
                else -> DataHandling.DISCARDED
            }
        }

    private fun receiveStartResult(current: Link, message: PhoneInputMessage): DataHandling {
        val request = pendingStart?.takeIf { it.id == message.text(0) }
            ?: return DataHandling.DISCARDED
        startTimeout?.cancel()
        startTimeout = null
        pendingStart = null
        when (message.number(1)) {
            START_ACCEPTED -> if (request.cancelled) {
                val session = ActiveSession(request.id)
                status = "Typing stopped."
                sendTerminal(session, current)
            } else {
                activeSession = ActiveSession(request.id)
                state = PhoneInputState.ACTIVE
                status = "Typing to ${request.peer.deviceName}."
            }
            1L -> { state = PhoneInputState.IDLE; status = "Your Mac is not ready to receive input yet." }
            2L -> {
                state = PhoneInputState.IDLE
                status = "Allow aniCe in Device Control and Data Access on your Mac, then try again."
            }
            else -> { state = PhoneInputState.IDLE; status = "Update aniCe on your Mac to enable phone typing." }
        }
        return DataHandling.HANDLED
    }

    private fun receiveEnd(message: PhoneInputMessage): DataHandling {
        val id = message.text(0)
        val request = pendingStart?.takeIf { it.id == id }
        if (request != null) {
            clearEndedInput()
            pendingStart = null
            startTimeout?.cancel()
            startTimeout = null
            state = PhoneInputState.IDLE
            status = endedStatus(message.number(1))
            return DataHandling.HANDLED
        }
        val session = activeSession
        if (session?.id == id) {
            clearEndedInput()
            activeSession = null
            state = PhoneInputState.IDLE
            status = endedStatus(message.number(1))
        }
        return DataHandling.HANDLED
    }

    // A remote stop invalidates unsent events too; they must not delay the next session.
    private fun clearEndedInput() {
        link?.let { current ->
            current.queue.clear()
            clearPendingPointer(current)
            current.pointerFlushJob?.cancel()
        }
    }

    private fun endedStatus(reason: Long) = when (reason) {
        0L -> "The Mac stopped phone input."
        1L -> "macOS input access changed. Typing stopped."
        2L -> "The Mac rejected an input event. Typing stopped."
        else -> "The Mac input surface closed. Typing stopped."
    }

    private fun sendTerminal(session: ActiveSession, current: Link? = link) {
        val target = current ?: return
        flushPendingPointer(target, session, reserveMessages = 0)
        clearPendingPointer(target)
        if (!live(target.channel.descriptor) || session.sequence + TERMINAL_MESSAGES > MAX_SEQUENCE) return
        val terminal = listOf(
            PhoneInputMessage.of(9, Cbor.Text(session.id), sequence(session)),
            PhoneInputMessage.of(10, Cbor.Text(session.id), sequence(session)),
        )
        terminal.forEach { enqueue(target, it) }
        pump(target)
    }

    private fun abortSession(
        session: ActiveSession,
        message: String = "Input stopped because Bluetooth could not keep up. Start a new session to continue.",
    ) {
        val current = link ?: return
        activeSession = null
        state = PhoneInputState.IDLE
        current.queue.clear()
        clearPendingPointer(current)
        status = message
        sendTerminal(session, current)
    }

    private fun enqueueSession(current: Link, session: ActiveSession, message: PhoneInputMessage) {
        if (activeSession !== session) return
        enqueue(current, message)
    }

    private fun sequence(session: ActiveSession): Cbor.Integer {
        session.sequence += 1
        return Cbor.Integer(session.sequence)
    }

    private fun enqueue(current: Link, message: PhoneInputMessage): Boolean {
        if (!live(current.channel.descriptor) || current.queue.size >= MAX_QUEUED_EVENTS) return false
        return try {
            current.queue.addLast(message.encode())
            pump(current)
            true
        } catch (_: PhoneInputWireException) {
            false
        } catch (_: IllegalArgumentException) {
            false
        }
    }

    private fun pump(current: Link) {
        if (!live(current.channel.descriptor)) return
        if (current.sending) { current.wake = true; return }
        current.sending = true
        scope.launch {
            try {
                do {
                    current.wake = false
                    while (live(current.channel.descriptor)) {
                        if (current.queue.isEmpty()) {
                            activeSession?.takeIf { it.id == current.pendingPointer?.sessionId }
                                ?.let { flushPendingPointer(current, it, reserveMessages = 0, flushAll = false) }
                        }
                        val next = current.queue.firstOrNull() ?: break
                        try { current.channel.sendData(next) }
                        catch (_: SessionBackpressure) { break }
                        catch (error: CancellationException) { throw error }
                        catch (_: Exception) {
                            retired(current.channel.descriptor)
                            break
                        }
                        if (current.queue.firstOrNull() === next) current.queue.removeFirst()
                    }
                } while (current.wake && live(current.channel.descriptor))
            } finally {
                current.sending = false
                if (current.wake && live(current.channel.descriptor)) pump(current)
            }
        }
    }

    private fun live(descriptor: ChannelDescriptor): Boolean = link?.channel?.descriptor == descriptor

    private fun liveLink(peer: DeviceIdentity): Link? = link?.takeIf {
        live(it.channel.descriptor) && samePeer(it.channel.descriptor.peer, peer)
    }

    private fun samePeer(first: DeviceIdentity, second: DeviceIdentity) =
        first.deviceId == second.deviceId && first.fingerprint == second.fingerprint

    companion object {
        private const val BACKSPACE_USAGE = 0x2A
        private const val START_ACCEPTED = 0L
        private const val START_TIMEOUT_MILLIS = 15_000L
        private const val MAX_QUEUED_EVENTS = 768
        private const val TERMINAL_MESSAGES = 2L
        private const val MAX_SEQUENCE = 4_294_967_295L
        private const val REQUIRED_INPUT_EVENTS = 0x03L
        private const val KEY_TRANSITION_EVENT = 0x02L
        private const val POINTER_INPUT_EVENT = 0x04L
        private const val MAX_POINTER_DELTA = 32_767L
        // Cap accumulated motion to four wire-sized records per axis while the channel is busy.
        private const val MAX_PENDING_POINTER_DELTA = MAX_POINTER_DELTA * 4
        // Coalesce at a responsive cadence; channel-capacity callbacks can flush sooner.
        private const val POINTER_FLUSH_MILLIS = 16L
        private const val ANDROID_SUPPORTED_EVENTS = 0x07L
    }
}
