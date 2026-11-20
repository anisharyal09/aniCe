// SPDX-License-Identifier: GPL-3.0-or-later
// Negotiates a short native enrollment window without creating trust or initiating a connection.
package io.github.anisharyal09.anice.infrastructure.connections

import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import io.github.anisharyal09.anice.infrastructure.session.SessionBackpressure

internal class CompanionSetupLink(
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate),
    private val now: () -> Long = android.os.SystemClock::elapsedRealtime,
) : FeatureHandler {
    private class Link(val channel: SecuredChannel) {
        var capabilitySent = false
        var sending = false
        var capacityPending = false
        val capacity = MutableStateFlow(0L)
        val capability = CompletableDeferred<Unit>()
        val submitted = CompletableDeferred<Unit>()
        var preparing = false
        var acknowledgment: CompletableDeferred<Boolean>? = null
    }
    private var link: Link? = null

    override fun available(channel: SecuredChannel) {
        if (channel.descriptor.transport != "ble") return
        link?.let(::retire)
        val current = Link(channel)
        link = current
        sendCapability(current)
    }
    override fun retired(descriptor: ChannelDescriptor) {
        val current = link ?: return
        if (current.channel.descriptor.instance != descriptor.instance) return
        retire(current)
        link = null
    }
    private fun retire(link: Link) {
        link.capability.cancel()
        link.submitted.cancel()
        link.acknowledgment?.cancel()
    }
    override fun capacityAvailable(descriptor: ChannelDescriptor) {
        link?.takeIf { it.channel.descriptor.instance == descriptor.instance }?.let {
            it.capacity.value++
            if (it.sending) it.capacityPending = true else sendCapability(it)
        }
    }
    private fun sendCapability(current: Link) {
        if (current.capabilitySent || current.sending || link !== current) return
        current.sending = true
        current.capacityPending = false
        scope.launch {
            var backpressured = false
            try {
                current.channel.sendData(CompanionSetupMessage(1).encode())
                if (link === current) {
                    current.capabilitySent = true
                    current.submitted.complete(Unit)
                }
            } catch (error: CancellationException) { throw error }
            catch (_: SessionBackpressure) { backpressured = true }
            catch (_: Exception) {}
            finally {
                current.sending = false
                if (backpressured && current.capacityPending) sendCapability(current)
            }
        }
    }
    override suspend fun handle(descriptor: ChannelDescriptor, bytes: ByteArray): DataHandling {
        val message = try { CompanionSetupMessage.decode(bytes) ?: return DataHandling.UNRECOGNIZED }
            catch (_: Exception) { return DataHandling.DISCARDED }
        val current = link?.takeIf { it.channel.descriptor == descriptor }
            ?: return DataHandling.DISCARDED
        if (descriptor.transport != "ble" || descriptor.peer.platform != "macos")
            return DataHandling.DISCARDED
        return when (message.kind) {
            1L -> { current.capability.complete(Unit); DataHandling.HANDLED }
            3L -> {
                if (!current.capability.isCompleted || current.acknowledgment == null)
                    DataHandling.DISCARDED
                else { current.acknowledgment?.complete(message.available); DataHandling.HANDLED }
            }
            else -> DataHandling.DISCARDED
        }
    }
    suspend fun prepare(target: CompanionSetupTarget): Boolean {
        val current = link ?: return false
        if (!target.matches(current.channel.descriptor.peer, current.channel.descriptor.instance,
                now()) || current.preparing) return false
        current.preparing = true
        try {
            val capable = withTimeoutOrNull(5_000) {
                current.capability.await()
                current.submitted.await()
                true
            } ?: false
            if (!capable) return false
            return withTimeoutOrNull(5_000) {
                if (link !== current || !target.matches(current.channel.descriptor.peer,
                        current.channel.descriptor.instance, now())) return@withTimeoutOrNull false
                val reply = CompletableDeferred<Boolean>()
                current.acknowledgment = reply
                while (true) {
                    val capacity = current.capacity.value
                    try {
                        current.channel.sendData(CompanionSetupMessage(2, seconds = 60).encode())
                        break
                    } catch (_: SessionBackpressure) {
                        // Only a refused, unsealed request can wait for capacity; never replay a submission.
                        current.capacity.first { it != capacity }
                        if (link !== current || !target.matches(current.channel.descriptor.peer,
                                current.channel.descriptor.instance, now())) return@withTimeoutOrNull false
                    }
                }
                reply.await() && link === current && target.matches(current.channel.descriptor.peer,
                    current.channel.descriptor.instance, now())
            } ?: false
        } finally {
            current.acknowledgment = null
            current.preparing = false
        }
    }
    fun finish(target: CompanionSetupTarget) {
        val current = link?.takeIf {
            it.channel.descriptor.instance == target.channel &&
                companionSetupPeerMatches(target.peer, it.channel.descriptor.peer)
        } ?: return
        scope.launch {
            try { current.channel.sendData(CompanionSetupMessage(2, seconds = 0).encode()) }
            catch (error: CancellationException) { throw error }
            catch (_: Exception) {}
        }
    }
}
