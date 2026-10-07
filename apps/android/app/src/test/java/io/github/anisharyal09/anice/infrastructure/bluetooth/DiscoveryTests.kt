// SPDX-License-Identifier: GPL-3.0-or-later
package io.github.anisharyal09.anice.infrastructure.bluetooth

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class DiscoveryTests {
    private fun hex(value: String) = value.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
    @Test fun sharedVectors() {
        val resource = checkNotNull(javaClass.classLoader?.getResourceAsStream("discovery-vectors.json"))
        val fixture = JSONObject(resource.bufferedReader().use { it.readText() })
        assertEquals(1, fixture.getInt("fixtureVersion"))
        val valid = fixture.getJSONArray("valid")
        for (i in 0 until valid.length()) {
            val vector = valid.getJSONObject(i)
            val bytes = hex(vector.getString("payloadHex"))
            val payload = BlePayloadCodec.decode(bytes)
            assertEquals(vector.getInt("flags"), payload.flags)
            assertArrayEquals(hex(vector.getString("nonceHex")), payload.nonce)
            assertArrayEquals(bytes, BlePayloadCodec.encode(payload.nonce, payload.flags))
        }
        val invalid = fixture.getJSONArray("invalid")
        for (i in 0 until invalid.length()) {
            val vector = invalid.getJSONObject(i)
            val error = assertThrows(IllegalArgumentException::class.java) { BlePayloadCodec.decode(hex(vector.getString("payloadHex"))) }
            assertEquals(vector.getString("reason"), error.message)
        }
        assertThrows(IllegalArgumentException::class.java) { BlePayloadCodec.encode(ByteArray(15)) }
    }
    private class Fake : CentralAdapter {
        var found: (Long) -> Unit = {}
        var scanFailure: () -> Unit = {}
        var event: (CentralEvent) -> Unit = {}
        var scanStarts = true; var connects = true; var discovers = true; var reads = true
        var stopped = 0; var closed = 0; var disconnected = 0
        override fun scan(found: (Long) -> Unit, failed: () -> Unit): Boolean { this.found = found; scanFailure = failed; return scanStarts }
        override fun stopScan() { stopped++ }
        override fun connect(rowId: Long, event: (CentralEvent) -> Unit): Boolean { this.event = event; return connects }
        override fun discoverServices() = discovers
        override fun read() = reads
        override fun disconnect() { disconnected++ }
        override fun close() { closed++ }
    }
    private class Rig {
        var time = 0L
        val fake = Fake()
        val session = CentralDiscoverySession(fake) { time }
        fun connect() { session.start(); fake.found(1); session.select(1) }
        fun validRead() { fake.event(CentralEvent.Connected); fake.event(CentralEvent.ServicesFound); fake.event(CentralEvent.Read(BlePayloadCodec.encode(ByteArray(16)))) }
    }
    @Test fun deduplicatesCapsAndClearsCandidates() {
        val r = Rig(); r.session.start()
        repeat(40) { r.fake.found(it.toLong()); r.fake.found(it.toLong()) }
        assertEquals(32, r.session.snapshot.candidates.size)
        r.time = 15_000; r.session.tick()
        assertTrue(r.session.snapshot.candidates.isEmpty()); assertFalse(r.session.snapshot.scanning)
        r.fake.found(100); assertTrue(r.session.snapshot.candidates.isEmpty())
    }
    @Test fun rejectsExpiredSelections() {
        val r = Rig(); r.session.start(); r.fake.found(1); r.time = 15_000; r.session.select(1)
        assertEquals(DiscoveryState.idle, r.session.snapshot.state)
    }
    @Test fun readyOnlyAfterCloseWithBoundedGrace() {
        val r = Rig(); r.connect(); assertTrue(r.session.snapshot.candidates.isEmpty())
        val closed = r.fake.closed; r.validRead()
        assertEquals(ConnectionStage.disconnecting, r.session.snapshot.stage)
        r.time = 1_999; r.session.tick(); assertEquals(closed, r.fake.closed)
        r.time = 2_000; r.session.tick()
        assertEquals(DiscoveryState.ready, r.session.snapshot.state); assertEquals(closed + 1, r.fake.closed)
        assertEquals(1, r.fake.disconnected)
    }
    @Test fun callbackCleanupWinsAndDuplicateReadIgnored() {
        val r = Rig(); r.connect(); r.validRead(); r.fake.event(CentralEvent.Read(byteArrayOf()))
        r.fake.event(CentralEvent.Disconnected); assertEquals(DiscoveryState.ready, r.session.snapshot.state)
        val closes = r.fake.closed; r.time = 3_000; r.session.tick(); assertEquals(closes, r.fake.closed)
    }
    @Test fun malformedPayloadAndMissingServiceFail() {
        for (event in listOf(CentralEvent.Read(byteArrayOf()), CentralEvent.Failed("Missing service"))) {
            val r = Rig(); r.connect(); r.fake.event(CentralEvent.Connected); r.fake.event(CentralEvent.ServicesFound)
            r.fake.event(event); r.fake.event(CentralEvent.Disconnected)
            assertEquals(DiscoveryState.failed, r.session.snapshot.state)
        }
    }
    @Test fun failedOperationStartsCleanup() {
        val scanning = Rig(); scanning.fake.scanStarts = false; scanning.session.start()
        assertEquals(DiscoveryState.failed, scanning.session.snapshot.state)
        for (stage in 0..2) {
            val r = Rig()
            if (stage == 0) r.fake.connects = false
            if (stage == 1) r.fake.discovers = false
            if (stage == 2) r.fake.reads = false
            r.connect(); r.fake.event(CentralEvent.Connected); r.fake.event(CentralEvent.ServicesFound)
            r.time = 2_000; r.session.tick()
            assertEquals(DiscoveryState.failed, r.session.snapshot.state)
        }
    }
    @Test fun absentCallbacksTimeoutAtAnyStage() {
        for (stage in 0..2) {
            val r = Rig(); r.connect()
            if (stage >= 1) r.fake.event(CentralEvent.Connected)
            if (stage == 2) r.fake.event(CentralEvent.ServicesFound)
            r.time = 15_000; r.session.tick(); assertEquals(ConnectionStage.disconnecting, r.session.snapshot.stage)
            r.time = 17_000; r.session.tick(); assertEquals(DiscoveryState.failed, r.session.snapshot.state)
        }
    }
    @Test fun staleScanAndGattCallbacksCannotChangeNewOperation() {
        val r = Rig(); r.connect(); val oldEvent = r.fake.event; val oldFound = r.fake.found
        r.session.start(); oldEvent(CentralEvent.Connected); oldFound(33)
        assertEquals(DiscoveryState.discovering, r.session.snapshot.state); assertTrue(r.session.snapshot.candidates.isEmpty())
        r.fake.found(2); r.session.select(1); assertEquals(DiscoveryState.found, r.session.snapshot.state)
    }
    @Test fun permissionLossDoesNotBlockCleanup() {
        val r = Rig(); r.connect()
        r.session.unavailable(DiscoveryState.permissionNeeded, RecoveryReason.permission, "Permission needed")
        r.time = 2_000; r.session.tick()
        assertEquals(DiscoveryState.permissionNeeded, r.session.snapshot.state); assertFalse(r.session.snapshot.busy)
    }
    @Test fun cancellationOverridesPendingSuccess() {
        val r = Rig(); r.connect(); r.validRead(); r.session.cancel(); r.fake.event(CentralEvent.Disconnected)
        assertEquals(DiscoveryState.idle, r.session.snapshot.state)
        r.session.start(); r.session.cancel(); assertFalse(r.session.snapshot.busy)
    }
    @Test fun foregroundExitReleasesImmediatelyAndRetiresCallbacks() {
        val r = Rig(); r.connect(); val old = r.fake.event; val closed = r.fake.closed
        r.session.cancel(); r.session.retire()
        assertEquals(closed + 1, r.fake.closed); assertFalse(r.session.snapshot.busy)
        old(CentralEvent.Read(BlePayloadCodec.encode(ByteArray(16))))
        assertEquals(DiscoveryState.idle, r.session.snapshot.state)
    }
    @Test fun scanFailureAndConnectionErrorAreTerminal() {
        val r = Rig(); r.session.start(); r.fake.scanFailure()
        assertEquals(DiscoveryState.failed, r.session.snapshot.state)
        r.connect(); r.fake.event(CentralEvent.Failed("Connection error")); r.fake.event(CentralEvent.Disconnected)
        assertEquals(DiscoveryState.failed, r.session.snapshot.state)
    }
}
