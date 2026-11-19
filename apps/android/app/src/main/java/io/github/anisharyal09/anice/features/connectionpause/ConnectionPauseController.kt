// SPDX-License-Identifier: GPL-3.0-or-later
// Mirrors a peer's pause state on device surfaces without changing local automatic policy.
package io.github.anisharyal09.anice.features.connectionpause

import androidx.compose.runtime.mutableStateMapOf
import io.github.anisharyal09.anice.infrastructure.connections.*
import io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity
import kotlinx.coroutines.*

class ConnectionPauseController(
    private val formatTime: (Long) -> String,
    private val now: () -> Long = System::currentTimeMillis,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate),
) : FeatureHandler {
    private data class PeerPause(val peer: DeviceIdentity, val until: Long?)

    private val links = mutableMapOf<String, SecuredChannel>()
    private val peers = mutableStateMapOf<String, PeerPause>()
    private val expiry = mutableMapOf<String, Job>()

    fun status(peer: DeviceIdentity): String? {
        val pause = peers[peer.fingerprint] ?: return null
        if (pause.peer.deviceId != peer.deviceId || pause.peer.publicKey != peer.publicKey) return null
        if (pause.until != null && pause.until <= now()) return null
        return pause.until?.let {
            "Paused on ${pause.peer.deviceName} until ${formatTime(it)}"
        } ?: "Paused on ${pause.peer.deviceName}"
    }

    /** A local Resume supersedes a mirrored deadline even before a fresh secured channel exists. */
    fun clear() {
        peers.keys.toList().forEach(::clear)
    }

    fun reconcileTime() {
        peers.entries.filter { it.value.until?.let { until -> until <= now() } == true }
            .map { it.key }.forEach(::clear)
    }

    override fun available(channel: SecuredChannel) {
        links[channel.descriptor.transport] = channel
        // A fresh authenticated channel is the authoritative replacement for an older pause notice.
        clear(channel.descriptor.peer.fingerprint)
    }

    override fun retired(descriptor: ChannelDescriptor) {
        if (links[descriptor.transport]?.descriptor == descriptor) links.remove(descriptor.transport)
    }

    override fun capacityAvailable(descriptor: ChannelDescriptor) {}

    override suspend fun handle(descriptor: ChannelDescriptor, bytes: ByteArray): DataHandling {
        val link = links[descriptor.transport] ?: return DataHandling.DISCARDED
        if (link.descriptor != descriptor) return DataHandling.DISCARDED
        val message = try { ConnectionPauseMessage.decode(bytes) }
            catch (_: ConnectionPauseWireException) { return DataHandling.DISCARDED }
            ?: return DataHandling.UNRECOGNIZED
        when (message.kind) {
            1L -> apply(descriptor.peer, message.until)
            2L -> clear(descriptor.peer.fingerprint)
        }
        return DataHandling.HANDLED
    }

    suspend fun announcePause(until: Long) = announce(ConnectionPauseMessage(1L, until).encode())

    suspend fun announceResume() = announce(ConnectionPauseMessage(2L).encode())

    private suspend fun announce(bytes: ByteArray) {
        // One ordered submission is enough for the peer; do not duplicate notices across transports.
        for (channel in links.values.sortedBy { if (it.descriptor.transport == "lan") 0 else 1 }) {
            try {
                if (withTimeoutOrNull(800) { channel.sendData(bytes); true } == true) return
            } catch (error: CancellationException) {
                throw error
            } catch (_: Exception) {
                // Best effort: pause teardown must not depend on a peer's DATA capacity.
            }
        }
    }

    private fun apply(peer: DeviceIdentity, until: Long) {
        if (until > 0L && until <= now()) {
            clear(peer.fingerprint)
            return
        }
        if (peer.fingerprint !in peers && peers.size == 16) clear(peers.keys.first())
        val pause = PeerPause(peer, until.takeIf { it > 0L })
        peers[peer.fingerprint] = pause
        expiry.remove(peer.fingerprint)?.cancel()
        if (until > 0L) {
            expiry[peer.fingerprint] = scope.launch {
                // Wall-clock rollback must not expire a notice early; no periodic polling is needed.
                while (isActive && peers[peer.fingerprint] === pause) {
                    delay((until - now()).coerceAtLeast(0L))
                    if (until <= now()) { clear(peer.fingerprint); break }
                }
            }
        }
    }

    private fun clear(fingerprint: String) {
        peers.remove(fingerprint)
        expiry.remove(fingerprint)?.cancel()
    }
}
