// SPDX-License-Identifier: GPL-3.0-or-later
// Exchanges bounded LAN eligibility and direct locators only over a live authenticated BLE channel.
package io.github.anisharyal09.anice.infrastructure.connections

import io.github.anisharyal09.anice.infrastructure.session.*
import kotlinx.coroutines.*

internal data class LanDirectEndpoint(val ip: String, val port: Int, val profile: SessionProfile) {
    init {
        require(ipv4(ip) != null && port in 1..65535 &&
            profile in listOf(SessionProfile.STANDARD, SessionProfile.LAN_TRANSFER, SessionProfile.LAN_TRANSFER_512))
    }
    companion object {
        fun ipv4(ip: String): ByteArray? {
            if (ip.length !in 7..15 || ip.any { it !in '0'..'9' && it != '.' }) return null
            val octets = ip.split('.')
            if (octets.size != 4 || octets.any { it.isEmpty() || it.length > 1 && it[0] == '0' }) return null
            val values = octets.map { it.toIntOrNull() ?: return null }
            if (values.any { it !in 0..255 } || values[0] == 0 || values[0] == 127 || values[0] >= 224) return null
            return values.map { it.toByte() }.toByteArray()
        }
    }
}

internal data class LanRendezvousMessage(val version: Int, val state: Int, val endpoint: LanDirectEndpoint? = null)

internal object LanRendezvousWire {
    fun encode(state: Int): ByteArray {
        require(state in 0..4)
        return SessionCbor.encode(Cbor.Array(listOf(Cbor.Text("aniCe LAN"), Cbor.Integer(1), Cbor.Integer(state.toLong()))))
    }
    fun encode(message: LanRendezvousMessage): ByteArray {
        require(message.version in 1..2 && message.state in 0..(if (message.version == 1) 4 else 5))
        if (message.version == 1) { require(message.endpoint == null); return encode(message.state) }
        require(message.endpoint == null || message.state == 2)
        val fields = message.endpoint?.let {
            listOf(Cbor.Text(it.ip), Cbor.Integer(it.port.toLong()), Cbor.Integer(it.profile.wire.toLong()))
        }.orEmpty()
        return SessionCbor.encode(Cbor.Array(listOf(Cbor.Text("aniCe LAN"), Cbor.Integer(2),
            Cbor.Integer(message.state.toLong()), Cbor.Array(fields))))
    }
    fun decode(bytes: ByteArray): Int? = decodeMessage(bytes)?.state
    fun decodeMessage(bytes: ByteArray): LanRendezvousMessage? {
        if (bytes.size > 64 && (bytes[0].toInt() and 0xe0) != 0x80) return null
        val row = (SessionCbor.decode(bytes) as? Cbor.Array)?.value ?: return null
        if (row.firstOrNull() != Cbor.Text("aniCe LAN")) return null
        require(bytes.size <= 64)
        require(row.size in 3..4)
        val version = (row[1] as? Cbor.Integer)?.value
        require(version != null && version in 1L..2L && row.size == version.toInt() + 2)
        val state = (row[2] as? Cbor.Integer)?.value
        require(state != null && state in 0..(if (version == 1L) 4L else 5L))
        var endpoint: LanDirectEndpoint? = null
        if (version == 2L) {
            val fields = (row[3] as? Cbor.Array)?.value ?: throw IllegalArgumentException("Invalid LAN fields")
            require(fields.isEmpty() || fields.size == 3 && state == 2L)
            if (fields.isNotEmpty()) {
                val ip = (fields[0] as? Cbor.Text)?.value ?: throw IllegalArgumentException("Invalid LAN address")
                val port = (fields[1] as? Cbor.Integer)?.value
                val profile = (fields[2] as? Cbor.Integer)?.value
                require(port != null && port in 1..65535 && profile in listOf(1L, 3L, 4L))
                endpoint = LanDirectEndpoint(ip, port.toInt(), SessionProfile.entries.single { it.wire.toLong() == profile })
            }
        }
        return LanRendezvousMessage(version!!.toInt(), state.toInt(), endpoint)
    }
}

internal class LanRendezvous(private val scope: CoroutineScope,
    private val now: () -> Long = android.os.SystemClock::elapsedRealtime,
    private val changed: () -> Unit) : FeatureHandler {
    var channel: SecuredChannel? = null
        private set
    var remote: Int? = null
        private set
    var remoteEndpoint: LanDirectEndpoint? = null
        private set
    private var remoteVersion = 0
    private var version2 = false
    private var probePending = true
    var requests = 0L
        private set
    var remoteStateChanged: (ChannelDescriptor, Int?, Int) -> Unit = { _, _, _ -> }
    var transferRequested: (ChannelDescriptor) -> Unit = {}
    private var requestPending = false
    fun request() { requestPending = true; flush() }
    private var transferRequestUntil: Long? = null
    private var transferRevision = 0
    private var transferRequestInFlight: Int? = null
    fun requestTransfer() {
        if (channel == null || transferRequestInFlight == transferRevision) return
        // Repeated clicks while unsent cannot extend or duplicate this one bounded demand.
        if (transferRequestUntil == null) transferRequestUntil = now() + 10_000
        flush()
    }
    fun cancelTransferRequest() {
        transferRevision++; transferRequestUntil = null
        if (transferRequestInFlight != null) {
            // Cancel unsealed work; an already nonce-owned record still follows shared session rules.
            sending?.cancel(); sending = null; wake = false
            transferRequestInFlight = null
        }
    }
    private var local = 0
    private var endpoint: LanDirectEndpoint? = null
    private var sent: LanRendezvousMessage? = null
    private var sending: Job? = null
    private var wake = false
    fun update(state: Int, endpoint: LanDirectEndpoint? = null) {
        require(state in 0..3 && (endpoint == null || state in 1..2))
        local = state; this.endpoint = endpoint; flush()
    }
    private fun publication(version: Int = if (version2) 2 else 1): LanRendezvousMessage =
        LanRendezvousMessage(version, if (version == 2 && local == 1 && endpoint != null) 2 else local,
            if (version == 2) endpoint else null)
    override fun available(channel: SecuredChannel) {
        if (channel.descriptor.transport != "ble") return
        sending?.cancel(); sending = null; wake = false
        this.channel = channel; remote = null; remoteEndpoint = null; remoteVersion = 0
        version2 = false; probePending = true; sent = null; requestPending = false; transferRequestUntil = null
        transferRevision++; transferRequestInFlight = null
        changed(); flush()
    }
    override fun retired(descriptor: ChannelDescriptor) {
        if (channel?.descriptor != descriptor) return
        sending?.cancel(); sending = null; wake = false; channel = null; remote = null
        remoteEndpoint = null; remoteVersion = 0; version2 = false; probePending = true; sent = null; requestPending = false
        transferRequestUntil = null
        transferRevision++; transferRequestInFlight = null
        changed()
    }
    override fun capacityAvailable(descriptor: ChannelDescriptor) {
        if (channel?.descriptor != descriptor) return
        if (sending?.isActive == true) wake = true else flush()
    }
    override suspend fun handle(descriptor: ChannelDescriptor, bytes: ByteArray): DataHandling {
        if (channel?.descriptor != descriptor) return DataHandling.UNRECOGNIZED
        val value = try { LanRendezvousWire.decodeMessage(bytes) }
        catch (_: IllegalArgumentException) { return DataHandling.DISCARDED }
        catch (_: SessionException) { return DataHandling.DISCARDED }
        if (value == null) return DataHandling.UNRECOGNIZED
        if (value.version == 2) version2 = true
        if (value.state == 4 || value.state == 5) {
            requests++
            if (value.state == 5) transferRequested(descriptor)
        } else if (value.version >= remoteVersion) {
            val previous = remote
            remoteVersion = value.version; remote = value.state; remoteEndpoint = value.endpoint
            if (previous != value.state) remoteStateChanged(descriptor, previous, value.state)
        }
        changed()
        flush()
        return DataHandling.HANDLED
    }
    private fun flush() {
        val target = channel ?: return
        if (transferRequestUntil?.let { now() >= it } == true) transferRequestUntil = null
        if ((!probePending && !requestPending && transferRequestUntil == null && sent == publication()) || sending?.isActive == true) return
        val work = scope.launch(start = CoroutineStart.LAZY) {
            var requested = false
            var probing = false
            var transferUntil: Long? = null
            var transferOp = transferRevision
            val sender = currentCoroutineContext().job
            try {
                while (channel === target && (probePending || requestPending || transferRequestUntil != null || sent != publication())) {
                    if (transferRequestUntil?.let { now() >= it } == true) transferRequestUntil = null
                    if (!probePending && !requestPending && transferRequestUntil == null && sent == publication()) break
                    probing = probePending
                    transferUntil = if (!probing) transferRequestUntil else null
                    val value = if (probing) publication(2) else if (transferUntil != null)
                        LanRendezvousMessage(if (version2) 2 else 1, if (version2) 5 else 4)
                    else if (requestPending) LanRendezvousMessage(if (version2) 2 else 1, 4) else publication()
                    requested = value.state == 4 && transferUntil == null
                    if (probing) probePending = false
                    if (requested) requestPending = false
                    if (transferUntil != null) {
                        transferOp = transferRevision
                        transferRequestUntil = null; requestPending = false; transferRequestInFlight = transferOp
                    }
                    target.sendData(LanRendezvousWire.encode(value))
                    probing = false
                    requested = false
                    transferUntil = null
                    if (sending === sender) transferRequestInFlight = null
                    if (channel === target && value.state < 4) sent = value
                }
            } catch (_: SessionBackpressure) {
                if (channel === target && sending === sender) {
                    requestPending = requestPending || requested
                    probePending = probePending || probing
                    if (transferOp == transferRevision && transferUntil?.let { now() < it } == true && transferRequestUntil == null)
                        transferRequestUntil = transferUntil
                }
                // A transport capacity event retries the latest state before sealing.
            } catch (error: CancellationException) {
                throw error
            } catch (_: Exception) {
                // Failed submissions close the session; retirement clears this advertisement.
            } finally {
                if (channel === target && sending === sender) {
                    transferRequestInFlight = null
                    sending = null
                    if (wake) { wake = false; flush() }
                }
            }
        }
        sending = work
        work.start()
    }
}

internal class LanAttemptGate(private val recoveryLimit: Int = 3) {
    private var channel: String? = null
    private var eligible = false
    private var remoteEligible = false
    private var ready = false
    private var requests = 0L
    private var attempted = false
    private var cancelled = false
    private var activityDemanded = false
    private var recovery = recoveryLimit
    private var demand = false
    fun update(channel: String?, eligible: Boolean, remoteEligible: Boolean, ready: Boolean, requests: Long) {
        val renewed = this.channel != channel || (eligible && !this.eligible) || (remoteEligible && !this.remoteEligible)
        if (renewed) { activityDemanded = false; recovery = recoveryLimit; cancelled = false }
        if (this.requests != requests) cancelled = false
        if (renewed || this.requests != requests || (ready && !this.ready && !cancelled)) attempted = false
        this.channel = channel; this.eligible = eligible; this.remoteEligible = remoteEligible
        this.ready = ready; this.requests = requests
    }
    fun claimActivity(): Boolean {
        if (cancelled || activityDemanded) return false
        activityDemanded = true
        return true
    }
    /** An explicit request or preference change gets one attempt, even after recovery is exhausted. */
    fun trigger() { cancelled = false; demand = true; attempted = false }
    fun claim(connected: Boolean = false): Boolean {
        if (connected || cancelled || attempted) return false
        if (demand) { demand = false; attempted = true; if (recovery > 0) recovery--; return true }
        if (recovery <= 0) return false
        recovery--; attempted = true
        return true
    }
    /** Marks an in-flight attempt without spending another recovery slot. */
    fun hold() { attempted = true }
    /** Cancel consumes this event, including a late listener-ready callback, without disabling automation. */
    fun cancel() { cancelled = true; attempted = true; demand = false; activityDemanded = true }
    /** Releases the event latch after a failed attempt so a bounded retry can run. */
    fun release() { if (!cancelled) attempted = false }
    fun claimRecovery(): Boolean {
        if (cancelled || attempted || recovery <= 0) return false
        demand = false; recovery--; attempted = true
        return true
    }
    /** App open, wake, pause expiry or a new BLE channel restores the bounded recovery budget. */
    fun rearm() { cancelled = false; recovery = recoveryLimit; attempted = false; demand = false }
}
