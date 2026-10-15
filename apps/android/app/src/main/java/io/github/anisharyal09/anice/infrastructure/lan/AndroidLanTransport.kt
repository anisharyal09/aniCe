// SPDX-License-Identifier: GPL-3.0-or-later
// Owns a network-bound TCP socket with bounded frame assembly and write retirement.
package io.github.anisharyal09.anice.infrastructure.lan

import android.os.SystemClock
import io.github.anisharyal09.anice.infrastructure.session.*
import java.net.Socket
import java.net.SocketTimeoutException
import kotlinx.coroutines.*
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
            val framing = LanFraming(profile) { SystemClock.elapsedRealtime() }
            val input = socket.getInputStream()
            val buffer = ByteArray(65536)
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
                    if (envelope != null) {
                        val deliveryStarted = if (profile != SessionProfile.STANDARD) System.nanoTime() else 0L
                        deliver(envelope)
                        if (profile != SessionProfile.STANDARD) deliveryNanos += System.nanoTime() - deliveryStarted
                    }
                }
            }
        }

    fun close() {
        closed = true
        try {
            socket.close()
        } catch (_: java.io.IOException) {}
    }
}
