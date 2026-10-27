// SPDX-License-Identifier: GPL-3.0-or-later
// Dispatches application DATA on live authenticated channel instances without owning transport queues.
package io.github.anisharyal09.anice.infrastructure.connections

import io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity
import io.github.anisharyal09.anice.infrastructure.session.*

enum class DataHandling { HANDLED, QUEUED, DISCARDED, UNRECOGNIZED }
data class ChannelDescriptor(val instance: String, val transport: String, val peer: DeviceIdentity, val maximumDataBytes: Int = 4000)
interface SecuredChannel {
    val descriptor: ChannelDescriptor
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
class FeatureDispatch {
    var applicationActivity: (ChannelDescriptor, ByteArray) -> Unit = { _, _ -> }
    private val handlers = mutableListOf<FeatureHandler>()
    private val channels = mutableMapOf<String, SecuredChannel>()
    fun register(handler: FeatureHandler) { check(channels.isEmpty()); check(handler !in handlers); handlers.add(handler) }
    fun available(descriptor: ChannelDescriptor, send: suspend (ByteArray) -> Unit) {
        if (channels[descriptor.transport]?.descriptor == descriptor) return
        retired(descriptor.transport)
        val channel = object : SecuredChannel {
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
    fun retired(transport: String) { channels.remove(transport)?.let { old -> handlers.forEach { it.retired(old.descriptor) } } }
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
