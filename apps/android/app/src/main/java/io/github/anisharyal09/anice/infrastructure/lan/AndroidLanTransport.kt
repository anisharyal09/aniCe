// SPDX-License-Identifier: GPL-3.0-or-later
// Owns a network-bound TCP socket with bounded frame assembly and write retirement.
package io.github.anisharyal09.anice.infrastructure.lan

import android.os.SystemClock
import io.github.anisharyal09.anice.infrastructure.bluetooth.GattQueueBudget
import io.github.anisharyal09.anice.infrastructure.session.*
import java.net.Socket
import java.net.SocketTimeoutException
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

internal class AndroidLanTransport(private val scope: CoroutineScope, private val changed: () -> Unit = {}) {
    private val socket = Socket()
    private val budget = GattQueueBudget()
    private val writer = Mutex()
    @Volatile private var closed = false

    fun hasCapacity(size: Int): Boolean =
        synchronized(budget) { !closed && budget.canReserve(size) }

    suspend fun connect(endpoint: LanEndpoint) =
        withContext(Dispatchers.IO) {
            if (closed) throw SessionException(SessionFailure.CANCELLED)
            endpoint.network.bindSocket(socket)
            socket.connect(java.net.InetSocketAddress(endpoint.address, endpoint.port), 5000)
            socket.soTimeout = 0
            socket.tcpNoDelay = true
            if (closed) throw SessionException(SessionFailure.CANCELLED)
        }

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
                    socket.getOutputStream().write(LanFraming.encode(envelope))
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
            val framing = LanFraming { SystemClock.elapsedRealtime() }
            val input = socket.getInputStream()
            val buffer = ByteArray(4096)
            while (!closed) {
                ensureActive()
                socket.soTimeout = framing.nextDeadline?.let {
                    (it - SystemClock.elapsedRealtime()).coerceIn(1, 10000).toInt()
                } ?: 0
                val count =
                    try {
                        input.read(buffer)
                    } catch (_: SocketTimeoutException) {
                        framing.tick()
                        continue
                    }
                if (count < 0) {
                    framing.end()
                    throw java.io.EOFException("Local-network connection ended.")
                }
                for (index in 0 until count) framing.feed(buffer[index])?.let { deliver(it) }
            }
        }

    fun close() {
        closed = true
        try {
            socket.close()
        } catch (_: java.io.IOException) {}
    }
}
