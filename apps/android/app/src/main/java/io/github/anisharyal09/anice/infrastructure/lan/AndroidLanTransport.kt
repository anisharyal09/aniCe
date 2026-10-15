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
            } else {
                socket.receiveBufferSize = 2 * 1024 * 1024
                socket.sendBufferSize = 2 * 1024 * 1024
            }
            endpoint.network.bindSocket(socket)
            socket.connect(java.net.InetSocketAddress(endpoint.address, endpoint.port), 5000)
            socket.soTimeout = 0
            socket.tcpNoDelay = true
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
        val watchdog =
            scope.launch {
                delay(10000)
                close()
            }
        try {
            writer.withLock {
                withContext(Dispatchers.IO) {
                    if (closed) throw SessionException(SessionFailure.CANCELLED)
                    val framed = LanFraming.encodeInto(frame, envelope, profile)
                    socket.getOutputStream().write(frame, 0, framed)
                }
            }
        } catch (error: Exception) {
            close()
            throw error
        } finally {
            watchdog.cancel()
            synchronized(budget) { budget.release(envelope.size) }
            changed()
        }
    }

    suspend fun receive(deliver: suspend (ByteArray) -> Unit) =
        withContext(Dispatchers.IO) {
            coroutineScope {
                val framing = LanFraming(profile) { SystemClock.elapsedRealtime() }
                val input = socket.getInputStream()
                // One whole profile record fits one read. TCP returns as soon as any byte is available,
                // so sizing the buffer to the record does not delay a partial frame.
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
                                deliver(envelope)
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
                        val count =
                            try {
                                input.read(buffer)
                            } catch (_: SocketTimeoutException) {
                                framing.tick()
                                continue
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
                            if (envelope != null) queue.send(envelope)
                        }
                    }
                } catch (error: Exception) {
                    ended = error
                } finally {
                    queue.close()
                }
                // The hand-off drains before the stream end is reported. `Channel.close` leaves the
                // buffered envelopes for the consumer, but throwing here cancels this scope and would
                // discard them, losing a record that arrived before the end — which inline delivery
                // never did. A cancelled read loop is not drained: there, stopping is the point.
                consumer.join()
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
