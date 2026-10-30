// SPDX-License-Identifier: GPL-3.0-or-later
// Bounds central compatibility discovery and rejects callbacks from retired operations.
package io.github.anisharyal09.anice.infrastructure.bluetooth

sealed interface CentralEvent {
    data object Connected : CentralEvent
    data object ServicesFound : CentralEvent
    data class Read(val bytes: ByteArray) : CentralEvent
    data object Disconnected : CentralEvent
    data class Failed(val message: String) : CentralEvent
}
/** All methods and callbacks belong to one serial execution context. No addresses cross this boundary. */
interface CentralAdapter {
    fun scan(found: (Long) -> Unit, failed: () -> Unit): Boolean
    fun stopScan()
    fun connect(rowId: Long, event: (CentralEvent) -> Unit): Boolean
    fun discoverServices(): Boolean
    fun read(): Boolean
    fun disconnect()
    fun close()
}

class CentralDiscoverySession(private val adapter: CentralAdapter, private val now: () -> Long) {
    var snapshot = DiscoverySnapshot(); private set
    var onChange: (DiscoverySnapshot) -> Unit = {}
    private var generation = 0L
    private var deadline = 0L
    private var cleanupDeadline = 0L
    private var hasClient = false
    private var terminal: DiscoverySnapshot? = null
    private fun update(value: DiscoverySnapshot) { snapshot = value; onChange(value) }

    fun unavailable(state: DiscoveryState, reason: RecoveryReason, message: String) {
        cancel()
        // Resource cleanup remains bounded even when prerequisites disappear mid-connection.
        val result = DiscoverySnapshot(state = state, recovery = reason, message = message)
        if (hasClient) { terminal = result; update(result.copy(busy = true, stage = ConnectionStage.disconnecting)) }
        else update(result)
    }
    fun start() {
        retire()
        val operation = ++generation
        deadline = now() + 15_000
        update(DiscoverySnapshot(state = DiscoveryState.discovering, message = "Looking for nearby aniCe devices…", scanning = true, busy = true, remainingSeconds = 15))
        val started = adapter.scan(found = { id ->
            if (generation == operation && snapshot.scanning && now() < deadline && snapshot.candidates.none { it.rowId == id } && snapshot.candidates.size < 32) {
                update(snapshot.copy(state = DiscoveryState.found, candidates = snapshot.candidates + DiscoveryCandidate(id, snapshot.candidates.size + 1)))
            }
        }, failed = {
            if (generation == operation && snapshot.scanning) finish(DiscoverySnapshot(state = DiscoveryState.failed, recovery = RecoveryReason.retry, message = "Scanning failed. Try a fresh scan."))
        })
        if (!started) finish(DiscoverySnapshot(state = DiscoveryState.failed, recovery = RecoveryReason.retry, message = "Scanning could not start. Try again."))
    }
    fun select(rowId: Long) {
        if (!snapshot.scanning || snapshot.candidates.none { it.rowId == rowId }) return
        if (now() >= deadline) { tick(); return }
        val operation = ++generation
        deadline = now() + 15_000
        // The adapter captures the selected handle before stopping/clearing the active scan.
        update(DiscoverySnapshot(state = DiscoveryState.connecting, message = "Connecting…", busy = true, stage = ConnectionStage.connecting))
        hasClient = true
        if (!adapter.connect(rowId) { event ->
                if (generation == operation && hasClient) receive(event)
            }) finish(DiscoverySnapshot(state = DiscoveryState.failed, recovery = RecoveryReason.retry, message = "Connection could not start. Scan again."))
    }
    private fun receive(event: CentralEvent) {
        if (terminal != null) {
            if (event == CentralEvent.Disconnected) completeCleanup()
            return
        }
        if (now() >= deadline) { tick(); return }
        when (event) {
            CentralEvent.Connected -> if (snapshot.stage == ConnectionStage.connecting) {
                update(snapshot.copy(stage = ConnectionStage.services, message = "Checking discovery service…"))
                if (!adapter.discoverServices()) failed("Service discovery could not start. Scan again.")
            }
            CentralEvent.ServicesFound -> if (snapshot.stage == ConnectionStage.services) {
                update(snapshot.copy(stage = ConnectionStage.reading, message = "Reading discovery protocol…"))
                if (!adapter.read()) failed("Discovery read could not start. Scan again.")
            }
            is CentralEvent.Read -> if (snapshot.stage == ConnectionStage.reading) {
                try {
                    BlePayloadCodec.decode(event.bytes)
                    finish(DiscoverySnapshot(state = DiscoveryState.ready, message = "aniCe discovery confirmed. This device is not paired."))
                } catch (_: IllegalArgumentException) { failed("Malformed or unsupported discovery payload. Scan again.") }
            }
            CentralEvent.Disconnected -> {
                failed("Connection ended before discovery was confirmed. Scan again.")
                completeCleanup()
            }
            is CentralEvent.Failed -> failed(event.message)
        }
    }
    private fun failed(message: String) = finish(DiscoverySnapshot(state = DiscoveryState.failed, recovery = RecoveryReason.retry, message = message))
    private fun finish(result: DiscoverySnapshot) {
        adapter.stopScan()
        if (hasClient) {
            terminal = result; cleanupDeadline = now() + 2_000
            update(DiscoverySnapshot(state = DiscoveryState.connecting, busy = true, stage = ConnectionStage.disconnecting, message = "Closing Bluetooth connection…"))
            adapter.disconnect()
        } else { generation++; update(result) }
    }
    private fun completeCleanup() {
        val result = terminal ?: DiscoverySnapshot()
        adapter.close(); hasClient = false; terminal = null; generation++
        update(result)
    }
    fun tick() {
        if (terminal != null) {
            if (now() >= cleanupDeadline) completeCleanup()
        } else if (snapshot.scanning) {
            if (now() >= deadline) finish(DiscoverySnapshot(message = "Scan ended. Scan again to find nearby devices."))
            else update(snapshot.copy(remainingSeconds = ((deadline - now() + 999) / 1000).toInt()))
        } else if (hasClient && now() >= deadline) failed("Discovery timed out. Scan again.")
    }
    fun cancel() {
        if (terminal != null) {
            terminal = DiscoverySnapshot(message = "Discovery cancelled.")
        } else finish(DiscoverySnapshot(message = "Discovery cancelled."))
    }
    /** New scans and ViewModel destruction release retired clients immediately. */
    fun retire() {
        generation++; adapter.stopScan(); if (hasClient) adapter.disconnect(); adapter.close(); hasClient = false; terminal = null
        update(DiscoverySnapshot())
    }
}
