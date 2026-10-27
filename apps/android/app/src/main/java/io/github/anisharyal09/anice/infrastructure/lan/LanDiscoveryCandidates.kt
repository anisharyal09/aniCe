// SPDX-License-Identifier: GPL-3.0-or-later
// Owns bounded LAN discovery candidates and failure-isolated stream consumption.
package io.github.anisharyal09.anice.infrastructure.lan

import kotlinx.coroutines.supervisorScope
import kotlinx.coroutines.channels.ReceiveChannel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.produceIn

internal class LanDiscoveryCandidates<T> {
    private class Candidate<T>(val value: T)
    // Keep names for this attempt so service churn cannot repeatedly refill the bounded queue.
    private val accepted = mutableSetOf<String>()
    private val current = mutableMapOf<String, Candidate<T>>()
    private val pending = Channel<Pair<String, Candidate<T>>>(8)
    private var closed = false

    @Synchronized fun offer(key: String, value: T) {
        if (closed || key in accepted || accepted.size == 8) return
        accepted.add(key)
        val candidate = Candidate(value)
        current[key] = candidate
        check(pending.trySend(key to candidate).isSuccess)
    }

    @Synchronized fun lost(key: String) { current.remove(key) }

    @Synchronized fun close(cause: Throwable? = null) {
        closed = true
        current.clear()
        pending.close(cause)
    }

    @Synchronized private fun isCurrent(key: String, candidate: Candidate<T>) =
        !closed && current[key] === candidate

    fun <E> endpoints(key: (E) -> String, resolve: suspend (T) -> List<E>): Flow<E> = flow {
        val emitted = mutableSetOf<String>()
        for ((name, candidate) in pending) {
            if (!isCurrent(name, candidate)) continue
            val endpoints = resolve(candidate.value)
            if (!isCurrent(name, candidate)) continue
            for (endpoint in endpoints) {
                if (emitted.add(key(endpoint))) {
                    emit(endpoint)
                    if (emitted.size == 8) return@flow
                }
            }
        }
    }
}

internal suspend fun <T> Flow<T>.consumeLanEndpoints(consume: suspend (ReceiveChannel<T>) -> Unit) =
    supervisorScope {
        // Discovery failures reach the consumer through its channel instead of cancelling its owner.
        val endpoints = produceIn(this)
        try { consume(endpoints) }
        finally { endpoints.cancel() }
    }
