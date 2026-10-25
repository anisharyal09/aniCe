// SPDX-License-Identifier: GPL-3.0-or-later
// Bounds authenticated transfer chunks under the feature's serial owner until ordered consumption completes.
package io.github.anisharyal09.anice.features.transfer

import io.github.anisharyal09.anice.infrastructure.connections.ChannelDescriptor
import io.github.anisharyal09.anice.infrastructure.session.SessionTiming
import kotlinx.coroutines.*
import java.util.ArrayDeque
import java.util.UUID

internal class TransferIngress(private val scope: CoroutineScope, private val consume: suspend (ChannelDescriptor, UUID, ByteArray) -> Unit) {
    private data class Entry(val descriptor: ChannelDescriptor, val epoch: UUID, val bytes: ByteArray)
    private val pending = ArrayDeque<Entry>()
    private val waiters = mutableListOf<CompletableDeferred<Unit>>()
    private var worker: Job? = null
    private var active: ChannelDescriptor? = null
    private var count = 0
    private var bytes = 0
    // Accounting includes the active write: removing it from FIFO does not release its capacity.
    suspend fun enqueue(descriptor: ChannelDescriptor, epoch: UUID, data: ByteArray, byteLimit: Int, recordLimit: Int, live: () -> Boolean): Boolean {
        if (data.size > byteLimit) return false
        val started = SessionTiming.start()
        while (live() && scope.isActive) {
            currentCoroutineContext().ensureActive()
            if (count < recordLimit && bytes <= byteLimit - data.size) {
                if (started != 0L) SessionTiming.end(this, "transfer_ingress_admission", started,
                    data.size, if (descriptor.maximumDataBytes > 4000) 3 else 1, "receive")
                pending.add(Entry(descriptor, epoch, data)); count++; bytes += data.size
                startWorker()
                return true
            }
            awaitChange()
        }
        return false
    }
    private fun startWorker() {
        if (worker != null || pending.isEmpty() || !scope.isActive) return
        worker = scope.launch(start = CoroutineStart.LAZY) { run() }
        worker!!.start()
    }
    private suspend fun run() {
        try {
            while (currentCoroutineContext().isActive && pending.isNotEmpty()) {
                val next = pending.removeFirst()
                active = next.descriptor
                val started = SessionTiming.start()
                try { consume(next.descriptor, next.epoch, next.bytes) }
                finally {
                    if (started != 0L) SessionTiming.end(this, "transfer_ingress_delivery", started,
                        next.bytes.size, if (next.descriptor.maximumDataBytes > 4000) 3 else 1, "receive")
                    active = null; count--; bytes -= next.bytes.size; wake()
                }
            }
        } finally { worker = null; startWorker(); wake() }
    }
    fun invalidate(descriptor: ChannelDescriptor? = null) {
        val iterator = pending.iterator()
        while (iterator.hasNext()) {
            val next = iterator.next()
            if (descriptor == null || next.descriptor == descriptor) {
                iterator.remove(); count--; bytes -= next.bytes.size
            }
        }
        // Cancel a storage dispatch that has not begun; an already-running blocking write may finish.
        if (active != null && (descriptor == null || active == descriptor)) worker?.cancel()
        wake()
    }
    suspend fun drain(descriptor: ChannelDescriptor? = null) {
        while (if (descriptor == null) count > 0 else active == descriptor || pending.any { it.descriptor == descriptor }) awaitChange()
    }
    private suspend fun awaitChange() {
        val waiter = CompletableDeferred<Unit>()
        waiters.add(waiter)
        try { waiter.await() } finally { waiters.remove(waiter) }
    }
    private fun wake() { waiters.toList().forEach { it.complete(Unit) } }
}
