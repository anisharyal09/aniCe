// SPDX-License-Identifier: GPL-3.0-or-later
// Bounds queued BLE envelopes separately from the single envelope currently being authenticated.
package io.github.anisharyal09.anice.infrastructure.connections

import io.github.anisharyal09.anice.infrastructure.bluetooth.GattQueueBudget
import kotlinx.coroutines.channels.Channel

internal class SessionInputQueue {
    private val budget = GattQueueBudget()
    private val queue = Channel<ByteArray>(8)
    private var closed = false
    val count get() = synchronized(this) { budget.messages }
    val bytes get() = synchronized(this) { budget.bytes }

    @Synchronized fun offer(envelope: ByteArray): Boolean {
        if (closed || !budget.canReserve(envelope.size)) return false
        // Reserve before waking a consumer; an immediate dispatcher may dequeue inline.
        budget.reserve(envelope.size)
        if (queue.trySend(envelope).isSuccess) return true
        budget.release(envelope.size)
        return false
    }

    suspend fun next(): ByteArray? {
        val envelope = queue.receiveCatching().getOrNull() ?: return null
        return synchronized(this) {
            if (closed) null else {
                budget.release(envelope.size)
                envelope
            }
        }
    }

    @Synchronized fun close() {
        closed = true
        queue.cancel()
        budget.clear()
    }
}
