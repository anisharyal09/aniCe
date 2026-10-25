// SPDX-License-Identifier: GPL-3.0-or-later
// Owns a network-bound TCP socket with bounded frame assembly and write retirement.
package io.github.anisharyal09.anice.infrastructure.lan

import android.os.SystemClock
import io.github.anisharyal09.anice.infrastructure.session.*
import java.net.Socket
import java.net.SocketTimeoutException
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

internal class AndroidLanTransport(private val scope: CoroutineScope, val profile: SessionProfile = SessionProfile.STANDARD, private val changed: () -> Unit = {}) {
    private val socket = Socket()
    private val budget = LanQueueBudget(profile)
    private val writer = Mutex()
    // Framed writes reuse this scratch space; the writer mutex serializes every use of it.
    private val frame = ByteArray(profile.maximumEnvelope + 5)
    @Volatile private var closed = false
    @Volatile private var secured = false
    fun markSecured() { secured = true }
    var readNanos = 0L
        private set
    var deliveryNanos = 0L
        private set

    fun hasCapacity(size: Int): Boolean =
        synchronized(budget) { !closed && budget.canReserve(size) }

    suspend fun connect(endpoint: LanEndpoint) =
        withContext(Dispatchers.IO) {
            if (closed) throw SessionException(SessionFailure.CANCELLED)
            if (profile == SessionProfile.BULK_PROBE) {
                // Set before connect so TCP window scaling includes the bulk receive budget.
                socket.receiveBufferSize = 8 * 1024 * 1024
                socket.sendBufferSize = 2 * 1024 * 1024
            } else if (profile == SessionProfile.LAN_TRANSFER) {
                // Profile 3 LAN transfer uses 4 MiB buffers to support near-gigabit streaming without window stall.
                socket.receiveBufferSize = 4 * 1024 * 1024
                socket.sendBufferSize = 4 * 1024 * 1024
            } else {
                socket.receiveBufferSize = 2 * 1024 * 1024
                socket.sendBufferSize = 2 * 1024 * 1024
            }
            endpoint.network.bindSocket(socket)
            socket.connect(java.net.InetSocketAddress(endpoint.address, endpoint.port), 5000)
            socket.soTimeout = 0
            socket.tcpNoDelay = true
            socket.keepAlive = true
            if (closed) throw SessionException(SessionFailure.CANCELLED)
        }

    fun bufferSizes(): Pair<Int, Int> = socket.sendBufferSize to socket.receiveBufferSize

    suspend fun submit(envelope: ByteArray) {
        synchronized(budget) {
            if (closed) throw SessionException(SessionFailure.CANCELLED)
            budget.reserve(envelope.size)
        }
        // Socket writes are blocking; closing the descriptor, rather than coroutine cancellation,
        // bounds them.
        val timedOut = java.util.concurrent.atomic.AtomicBoolean()
        val watchdog =
            scope.launch {
                delay(10000)
                timedOut.set(true)
                close()
            }
        try {
            val writerStart = SessionTiming.start()
            writer.withLock {
                SessionTiming.end(this, "socket_writer_wait", writerStart, envelope.size, profile = profile.wire, direction = "send")
                val dispatchStart = SessionTiming.start()
                withContext(Dispatchers.IO) {
                    SessionTiming.end(this@AndroidLanTransport, "socket_write_dispatch", dispatchStart, envelope.size, profile = profile.wire, direction = "send")
                    if (closed) throw SessionException(SessionFailure.CANCELLED)
                    val framed = LanFraming.encodeInto(frame, envelope, profile)
                    val writeStart = SessionTiming.start()
                    try { socket.getOutputStream().write(frame, 0, framed) } finally {
                        SessionTiming.end(this@AndroidLanTransport, "socket_write", writeStart, framed, profile = profile.wire, direction = "send")
                    }
                }
            }
        } catch (error: Exception) {
            close()
            if (timedOut.get()) throw SocketTimeoutException("Local-network write timed out after 10 seconds.").also { it.initCause(error) }
            throw error
        } finally {
            watchdog.cancel()
            synchronized(budget) { budget.release(envelope.size) }
            changed()
        }
    }

    suspend fun receive(drained: suspend () -> Unit = {}, deliver: suspend (ByteArray) -> Unit) =
        withContext(Dispatchers.IO) {
            coroutineScope {
                val framing = LanFraming(profile, secured = { secured }) { SystemClock.elapsedRealtime() }
                val input = socket.getInputStream()
                // Reuse one record buffer; each read stops at the current header/body boundary.
                val buffer = ByteArray(profile.maximumEnvelope + 5)
                // Bounded ordered handoff. The capacity restates the documented admission bound
                // (8 envelopes / 32,768 bytes standard, 4 envelopes / 1,048,700 bytes otherwise) and
                // every envelope is at most profile.maximumEnvelope, so the queue is bounded in
                // records and in bytes. A full queue suspends the reader rather than buffering without
                // limit, which is the TCP backpressure the link should see.
                val queue = Channel<ByteArray>(if (profile == SessionProfile.STANDARD) 8 else 4)
                // Reading must not wait on delivery: the previous shape held the socket unread for the
                // whole decode, native validation and main-thread hop of every record, so TCP
                // backpressure amplified each stall. A single consumer keeps record order, which is
                // what SecureSession's sequencing depends on.
                val consumer =
                    launch {
                        try {
                            for (envelope in queue) {
                                val deliveryStarted = if (profile != SessionProfile.STANDARD) System.nanoTime() else 0L
                                val deliveryStart = SessionTiming.start()
                                try { deliver(envelope) } finally {
                                    SessionTiming.end(this@AndroidLanTransport, "ingress_delivery", deliveryStart, envelope.size, profile = profile.wire, direction = "receive")
                                }
                                if (profile != SessionProfile.STANDARD) deliveryNanos += System.nanoTime() - deliveryStarted
                            }
                        } catch (error: Throwable) {
                            // A blocking socket read cannot observe a consumer failure; closing the
                            // descriptor is what releases it. This failure remains the reported cause
                            // because it is what cancels this scope.
                            close()
                            throw error
                        }
                    }
                var ended: Exception? = null
                try {
                    while (!closed) {
                        ensureActive()
                        socket.soTimeout = framing.nextDeadline?.let {
                            (it - SystemClock.elapsedRealtime()).coerceIn(1, 10000).toInt()
                        } ?: 0
                        val readStarted = if (profile != SessionProfile.STANDARD) System.nanoTime() else 0L
                        val readTiming = SessionTiming.start()
                        val count =
                            try {
                                input.read(buffer, 0, framing.readLimit)
                            } catch (_: SocketTimeoutException) {
                                framing.tick()
                                continue
                            } finally {
                                SessionTiming.end(this@AndroidLanTransport, "socket_read", readTiming, profile = profile.wire, direction = "receive")
                            }
                        if (profile != SessionProfile.STANDARD) readNanos += System.nanoTime() - readStarted
                        if (count < 0) {
                            framing.end()
                            throw java.io.EOFException("Local-network connection ended.")
                        }
                        val receivedAt = framing.beginBuffer()
                        var offset = 0
                        while (offset < count) {
                            val envelope = framing.feed(buffer, offset, count - offset, receivedAt)
                            offset += framing.consumed
                            if (envelope != null) {
                                val admissionStart = SessionTiming.start()
                                try { queue.send(envelope) } finally {
                                    SessionTiming.end(this@AndroidLanTransport, "ingress_backpressure", admissionStart, envelope.size, profile = profile.wire, direction = "receive")
                                }
                            }
                        }
                    }
                } catch (error: Exception) {
                    ended = error
                } finally {
                    queue.close()
                }
                // FIN can follow the final result; one deadline covers both frame and feature drains.
                // Path failure or explicit cancellation must not start another buffered delivery.
                if (ended is java.io.EOFException) {
                    val complete = withTimeoutOrNull(10000) { consumer.join(); drained(); true } ?: false
                    if (!complete) {
                        consumer.cancelAndJoin()
                        throw SocketTimeoutException("Local-network receive drain timed out after 10 seconds.")
                    }
                } else { consumer.cancelAndJoin() }
                if (ended != null) throw ended
            }
        }

    fun close() {
        closed = true
        try {
            socket.close()
        } catch (_: java.io.IOException) {}
    }
}
