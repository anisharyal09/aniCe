// SPDX-License-Identifier: GPL-3.0-or-later
// Dispatches application DATA on live authenticated channel instances without owning transport queues.
package io.github.anisharyal09.anice.infrastructure.connections

import io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity
import io.github.anisharyal09.anice.infrastructure.session.*
import kotlinx.coroutines.ensureActive

enum class DataHandling { HANDLED, QUEUED, DISCARDED, UNRECOGNIZED }
data class ChannelDescriptor(val instance: String, val transport: String, val peer: DeviceIdentity, val maximumDataBytes: Int = 4000)
interface SecuredChannel {
    val descriptor: ChannelDescriptor
    val maintenance: ChannelMaintenance? get() = null
    suspend fun sendData(bytes: ByteArray)
    // Deferred handlers report activity only after successful handling, never on queue admission.
    fun received(bytes: ByteArray) {}
}
interface FeatureHandler {
    fun available(channel: SecuredChannel)
    fun retired(descriptor: ChannelDescriptor)
    fun capacityAvailable(descriptor: ChannelDescriptor)
    suspend fun handle(descriptor: ChannelDescriptor, bytes: ByteArray): DataHandling
    suspend fun ingest(descriptor: ChannelDescriptor, bytes: ByteArray): DataHandling = handle(descriptor, bytes)
    suspend fun drain(descriptor: ChannelDescriptor) {}
}
// Mutations follow FeatureDispatch's presentation owner; coroutine cancellation removes deferred awaiters.
class ChannelMaintenance(private val now: () -> Long) {
    @Volatile private var snapshot = SessionMaintenanceSnapshot()
    @Volatile private var ready = kotlinx.coroutines.CompletableDeferred<Unit>().also { it.complete(Unit) }
    @Volatile private var closed = false
    val active get() = snapshot.sinceMillis != null
    val elapsedMillis get(): Long {
        val current = snapshot
        return current.elapsedMillis + (current.sinceMillis?.let { (now() - it).coerceAtLeast(0) } ?: 0)
    }
    internal fun update(next: SessionMaintenanceSnapshot) {
        if (closed || next.revision <= snapshot.revision) return
        val previous = active
        // Publish the new wait lane before readers can observe the active interval.
        if (!previous && next.sinceMillis != null) ready = kotlinx.coroutines.CompletableDeferred()
        snapshot = next
        if (previous && !active) ready.complete(Unit)
    }
    suspend fun awaitAvailable() {
        if (closed) throw SessionException(SessionFailure.CANCELLED)
        while (active) ready.await()
        kotlinx.coroutines.currentCoroutineContext().ensureActive()
        if (closed) throw SessionException(SessionFailure.CANCELLED)
    }
    internal fun close() {
        closed = true
        ready.completeExceptionally(SessionException(SessionFailure.CANCELLED))
    }
}

class FeatureDispatch(private val now: () -> Long = { android.os.SystemClock.elapsedRealtime() }) {
    var applicationActivity: (ChannelDescriptor, ByteArray) -> Unit = { _, _ -> }
    private val handlers = mutableListOf<FeatureHandler>()
    private val channels = mutableMapOf<String, SecuredChannel>()
    fun register(handler: FeatureHandler) { check(channels.isEmpty()); check(handler !in handlers); handlers.add(handler) }
    fun available(descriptor: ChannelDescriptor, send: suspend (ByteArray) -> Unit) {
        if (channels[descriptor.transport]?.descriptor == descriptor) return
        retired(descriptor.transport)
        val channel = object : SecuredChannel {
            override val maintenance = ChannelMaintenance(now)
            override fun received(bytes: ByteArray) {
                if (channels[descriptor.transport] === this) applicationActivity(descriptor, bytes)
            }
            override val descriptor = descriptor
            override suspend fun sendData(bytes: ByteArray) {
                if (channels[descriptor.transport] !== this) throw SessionException(SessionFailure.CANCELLED)
                require(bytes.size <= descriptor.maximumDataBytes)
                send(bytes)
                if (channels[descriptor.transport] !== this) throw SessionException(SessionFailure.CANCELLED)
                applicationActivity(descriptor, bytes)
            }
        }
        channels[descriptor.transport] = channel
        handlers.forEach { it.available(channel) }
    }
    fun retired(transport: String) { channels.remove(transport)?.let { old ->
        old.maintenance?.close(); handlers.forEach { it.retired(old.descriptor) }
    } }
    fun maintenance(transport: String, instance: String, snapshot: SessionMaintenanceSnapshot) {
        channels[transport]?.takeIf { it.descriptor.instance == instance }?.maintenance?.update(snapshot)
    }
    fun capacityAvailable(transport: String) { channels[transport]?.let { channel -> handlers.forEach { it.capacityAvailable(channel.descriptor) } } }
    suspend fun drain(transport: String, instance: String) {
        val descriptor = channels[transport]?.descriptor ?: return
        if (descriptor.instance != instance) return
        for (handler in handlers) {
            if (channels[transport]?.descriptor != descriptor) return
            handler.drain(descriptor)
        }
    }
    suspend fun handle(transport: String, instance: String, bytes: ByteArray): DataHandling {
        val descriptor = channels[transport]?.descriptor ?: return DataHandling.DISCARDED
        if (descriptor.instance != instance) return DataHandling.DISCARDED
        for (handler in handlers) { val result = handler.ingest(descriptor, bytes); if (channels[transport]?.descriptor != descriptor) return DataHandling.DISCARDED; if (result == DataHandling.HANDLED) applicationActivity(descriptor, bytes); if (result != DataHandling.UNRECOGNIZED) return result }
        return DataHandling.UNRECOGNIZED
    }
}
