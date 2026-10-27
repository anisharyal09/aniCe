// SPDX-License-Identifier: GPL-3.0-or-later
// Exchanges LAN eligibility only over a live authenticated BLE channel.
package io.github.anisharyal09.anice.infrastructure.connections

import io.github.anisharyal09.anice.infrastructure.session.*
import kotlinx.coroutines.*

internal object LanRendezvousWire {
    fun encode(state: Int): ByteArray {
        require(state in 0..4)
        return SessionCbor.encode(Cbor.Array(listOf(Cbor.Text("aniCe LAN"), Cbor.Integer(1), Cbor.Integer(state.toLong()))))
    }
    fun decode(bytes: ByteArray): Int? {
        if (bytes.size > 64) return null
        val row = (SessionCbor.decode(bytes) as? Cbor.Array)?.value ?: return null
        if (row.firstOrNull() != Cbor.Text("aniCe LAN")) return null
        require(row.size == 3 && row[1] == Cbor.Integer(1))
        val state = (row[2] as? Cbor.Integer)?.value
        require(state != null && state in 0..4)
        return state.toInt()
    }
}

internal class LanRendezvous(private val scope: CoroutineScope, private val changed: () -> Unit) : FeatureHandler {
    var channel: SecuredChannel? = null
        private set
    var remote: Int? = null
        private set
    var requests = 0L
        private set
    private var requestPending = false
    fun request() { requestPending = true; flush() }
    private var local = 0
    private var sent: Int? = null
    private var sending: Job? = null
    private var wake = false
    fun update(state: Int) { local = state; flush() }
    override fun available(channel: SecuredChannel) {
        if (channel.descriptor.transport != "ble") return
        sending?.cancel(); sending = null; wake = false
        this.channel = channel; remote = null; sent = null; requestPending = false
        changed(); flush()
    }
    override fun retired(descriptor: ChannelDescriptor) {
        if (channel?.descriptor != descriptor) return
        sending?.cancel(); sending = null; wake = false; channel = null; remote = null; sent = null; requestPending = false
        changed()
    }
    override fun capacityAvailable(descriptor: ChannelDescriptor) {
        if (channel?.descriptor != descriptor) return
        if (sending?.isActive == true) wake = true else flush()
    }
    override suspend fun handle(descriptor: ChannelDescriptor, bytes: ByteArray): DataHandling {
        if (channel?.descriptor != descriptor) return DataHandling.UNRECOGNIZED
        val value = try { LanRendezvousWire.decode(bytes) }
        catch (_: IllegalArgumentException) { return DataHandling.DISCARDED }
        catch (_: SessionException) { return DataHandling.DISCARDED }
        if (value == null) return DataHandling.UNRECOGNIZED
        if (value == 4) requests++ else remote = value
        changed()
        return DataHandling.HANDLED
    }
    private fun flush() {
        val target = channel ?: return
        if ((!requestPending && sent == local) || sending?.isActive == true) return
        val work = scope.launch(start = CoroutineStart.LAZY) {
            var requested = false
            try {
                while (channel === target && (requestPending || sent != local)) {
                    val value = if (requestPending) 4 else local
                    requested = value == 4
                    if (requested) requestPending = false
                    target.sendData(LanRendezvousWire.encode(value))
                    requested = false
                    if (channel === target && value != 4) sent = value
                }
            } catch (_: SessionBackpressure) {
                if (channel === target) requestPending = requestPending || requested
                // A transport capacity event retries the latest state before sealing.
            } catch (error: CancellationException) {
                throw error
            } catch (_: Exception) {
                // Failed submissions close the session; retirement clears this advertisement.
            } finally {
                if (channel === target && currentCoroutineContext().isActive) {
                    sending = null
                    if (wake) { wake = false; flush() }
                }
            }
        }
        sending = work
        work.start()
    }
}

internal class LanAttemptGate {
    private var channel: String? = null
    private var eligible = false
    private var remoteEligible = false
    private var ready = false
    private var requests = 0L
    private var attempted = false
    private var activityDemanded = false
    fun update(channel: String?, eligible: Boolean, remoteEligible: Boolean, ready: Boolean, requests: Long) {
        if (this.channel != channel || (eligible && !this.eligible) || (remoteEligible && !this.remoteEligible)) activityDemanded = false
        if (this.channel != channel || this.requests != requests || (eligible && !this.eligible) ||
            (remoteEligible && !this.remoteEligible) || (ready && !this.ready)) attempted = false
        this.channel = channel; this.eligible = eligible; this.remoteEligible = remoteEligible
        this.ready = ready; this.requests = requests
    }
    fun claimActivity(): Boolean {
        if (activityDemanded) return false
        activityDemanded = true
        return true
    }
    fun trigger() { attempted = false }
    fun claim(connected: Boolean = false): Boolean { if (connected || attempted) return false; attempted = true; return true }
}
