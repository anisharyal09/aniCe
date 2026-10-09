// SPDX-License-Identifier: GPL-3.0-or-later
// Probes LAN framing, peer exclusion, native-resolution retirement and scoped-address boundaries.
package io.github.anisharyal09.anice.infrastructure.session

import io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity
import io.github.anisharyal09.anice.infrastructure.lan.*
import java.net.Inet6Address
import java.net.InetAddress
import kotlinx.coroutines.*
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class LanTests {
    private fun bytes(text: String) = text.chunked(2).map { it.toInt(16).toByte() }.toByteArray()

    private fun decode(framing: LanFraming, wire: ByteArray) =
        wire.map { framing.feed(it) }.filterNotNull()

    private fun reject(reason: SessionFailure, body: () -> Unit) {
        try {
            body()
            fail("Expected $reason")
        } catch (error: SessionException) {
            assertEquals(reason, error.reason)
        }
    }

    @Test
    fun framingFixturesAndAllSplitPoints() {
        val root =
            JSONObject(
                requireNotNull(javaClass.classLoader!!.getResourceAsStream("lan/lan-vectors.json"))
                    .bufferedReader()
                    .use { it.readText() }
            )
        val valid = root.getJSONArray("valid")
        val invalid = root.getJSONArray("invalid")
        assertTrue(valid.length() >= 8)
        assertTrue(invalid.length() >= 10)
        repeat(valid.length()) { index ->
            val row = valid.getJSONObject(index)
            val envelope = bytes(row.getString("envelopeHex"))
            val wire = bytes(row.getString("frameHex"))
            assertArrayEquals(wire, LanFraming.encode(envelope))
            for (split in 0..wire.size) {
                val framing = LanFraming()
                val actual =
                    decode(framing, wire.copyOfRange(0, split)) +
                        decode(framing, wire.copyOfRange(split, wire.size))
                assertEquals(1, actual.size)
                assertArrayEquals(envelope, actual.single())
                framing.end()
            }
        }
        repeat(invalid.length()) { index ->
            val row = invalid.getJSONObject(index)
            val framing = LanFraming()
            reject(
                if (row.getString("reason") == "unsupportedProfile")
                    SessionFailure.UNSUPPORTED_PROFILE
                else SessionFailure.MALFORMED
            ) {
                decode(framing, bytes(row.getString("frameHex")))
                framing.end()
            }
            reject(SessionFailure.CANCELLED) { framing.feed(1) }
        }
    }

    @Test
    fun coalescingAndNonExtendingAssemblyDeadline() {
        val envelope = byteArrayOf(1, 42)
        val frame = LanFraming.encode(envelope)
        val framing = LanFraming()
        val result = decode(framing, frame + frame + frame)
        assertEquals(3, result.size)
        result.forEach { assertArrayEquals(envelope, it) }
        var clock = 0L
        val slow = LanFraming { clock }
        slow.feed(1)
        clock = 9999
        slow.feed(0)
        clock = 10000
        reject(SessionFailure.EXPIRED) { slow.feed(0) }
        reject(SessionFailure.CANCELLED) { slow.end() }
        for (size in listOf(0, 1, 4097)) reject(SessionFailure.MALFORMED) {
            LanFraming.encode(ByteArray(size))
        }
    }

    @Test
    fun timeoutCancellationAndStaleCallbackNeverOverlapResolutions() = runBlocking {
        val lane = LegacyResolutionLane<String>()
        val first = lane.begin()
        assertNull(withTimeoutOrNull(1) { first.result.await() })
        try {
            lane.begin()
            fail("Timed-out native resolution still owns its slot")
        } catch (_: IllegalStateException) {}
        first.result.cancel()
        try {
            lane.begin()
            fail("Cancelling await must not release native resolution")
        } catch (_: IllegalStateException) {}
        lane.finish(first.token, Result.success("late"))
        val second = lane.begin()
        lane.finish(first.token, Result.failure(IllegalStateException("stale")))
        try {
            lane.begin()
            fail("Stale callback released a newer native resolution")
        } catch (_: IllegalStateException) {}
        lane.finish(second.token, Result.success("fresh"))
        assertEquals("fresh", second.result.await())
        val failed = lane.begin()
        lane.finish(failed.token, Result.failure(NsdResolutionFailure(3)))
        try {
            failed.result.await()
            fail("Already-active resolution accepted")
        } catch (error: NsdResolutionFailure) {
            assertEquals(3, error.code)
        }
        assertNotNull(lane.begin())
    }

    @Test
    fun ipv6ScopeMustMatchTheSelectedInterface() {
        val raw = bytes("fe800000000000000000000000000001")
        val bare = Inet6Address.getByAddress(null, raw, 0)
        assertEquals(7, (LanAddress.scoped(bare, 7) as Inet6Address).scopeId)
        assertEquals(
            7,
            (LanAddress.scoped(Inet6Address.getByAddress(null, raw, 7), 7) as Inet6Address).scopeId,
        )
        for (index in listOf(null, 0, -1)) {
            try {
                LanAddress.scoped(bare, index)
                fail("Missing interface accepted")
            } catch (_: IllegalArgumentException) {}
        }
        try {
            LanAddress.scoped(Inet6Address.getByAddress(null, raw, 8), 7)
            fail("Wrong scope accepted")
        } catch (_: IllegalArgumentException) {}
        val ipv4 = InetAddress.getByAddress(byteArrayOf(192.toByte(), 168.toByte(), 1, 2))
        assertSame(ipv4, LanAddress.scoped(ipv4, null))
    }

    @Test
    fun simultaneousOwnersCannotReplacePeerOrLocalIdentity() {
        val peer = DeviceIdentity("id", "Mac", "macos", "key", "fingerprint")
        val reservation = SessionPeerReservation()
        val ble = Any()
        val lan = Any()
        assertTrue(reservation.acquire(ble, peer, "local"))
        assertTrue(reservation.acquire(lan, peer.copy(deviceName = "Renamed"), "local"))
        for (other in
            listOf(
                peer.copy(deviceId = "other"),
                peer.copy(publicKey = "other"),
                peer.copy(fingerprint = "other"),
            )) {
            assertFalse(reservation.permits(other))
            assertFalse(reservation.acquire(Any(), other, "local"))
        }
        assertFalse(reservation.acquire(lan, peer, "new-local"))
        reservation.release(ble)
        assertFalse(reservation.permits(peer.copy(deviceId = "other")))
        reservation.release(Any())
        assertFalse(reservation.acquire(ble, peer, "new-local"))
        reservation.release(lan)
        assertTrue(reservation.acquire(ble, peer.copy(deviceId = "other"), "new-local"))
    }
}
