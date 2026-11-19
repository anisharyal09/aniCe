// SPDX-License-Identifier: GPL-3.0-or-later
// Negotiates a short native enrollment window without creating trust or initiating a connection.
package io.github.anisharyal09.anice.infrastructure.connections

import kotlinx.coroutines.*

internal class CompanionSetupLink(
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate),
    private val now: () -> Long = android.os.SystemClock::elapsedRealtime,
) : FeatureHandler {
    private class Link(val channel: SecuredChannel) {
        var capabilitySent = false
        var sending = false
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
        link?.takeIf { it.channel.descriptor.instance == descriptor.instance }?.let(::sendCapability)
    }
    private fun sendCapability(current: Link) {
        if (current.capabilitySent || current.sending || link !== current) return
        current.sending = true
        scope.launch {
            try {
                current.channel.sendData(CompanionSetupMessage(1).encode())
                if (link === current) {
                    current.capabilitySent = true
                    current.submitted.complete(Unit)
                }
            } catch (error: CancellationException) { throw error }
            catch (_: Exception) {}
            finally { current.sending = false }
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
                if (!current.capability.isCompleted || !current.capabilitySent || current.acknowledgment == null)
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
            return withTimeoutOrNull(5_000) {
                current.capability.await()
                current.submitted.await()
                if (link !== current || !target.matches(current.channel.descriptor.peer,
                        current.channel.descriptor.instance, now())) return@withTimeoutOrNull false
                val reply = CompletableDeferred<Boolean>()
                current.acknowledgment = reply
                current.channel.sendData(CompanionSetupMessage(2, seconds = 60).encode())
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
                it.channel.descriptor.peer.deviceId == target.peer.deviceId &&
                it.channel.descriptor.peer.fingerprint == target.peer.fingerprint &&
                it.channel.descriptor.peer.publicKey == target.peer.publicKey
        } ?: return
        scope.launch {
            try { current.channel.sendData(CompanionSetupMessage(2, seconds = 0).encode()) }
            catch (error: CancellationException) { throw error }
            catch (_: Exception) {}
        }
    }
}
