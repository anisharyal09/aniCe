// SPDX-License-Identifier: GPL-3.0-or-later
// Exercises proximity jitter, bounds and expiry without Bluetooth or persistent identity access.
package io.github.anisharyal09.anice.infrastructure.bluetooth

import org.junit.Assert.*
import org.junit.Test

class ProximitySignalFilterTests {
    private class Rig {
        var time = 0L
        val filter = ProximitySignalFilter({ time })
        fun sample(rssi: Int, id: Long = 1) = filter.observe(id, rssi)
        fun qualify() {
            sample(-60); time = 500; sample(-60); time = 1_000; sample(-60)
        }
    }
    @Test fun requiresThreeSamplesAndSustainedStrength() {
        val r = Rig()
        assertFalse(r.sample(-60).single().nearby)
        r.time = 500; assertFalse(r.sample(-60).single().nearby)
        r.time = 999; assertFalse(r.sample(-60).single().nearby)
        r.time = 1_000; assertTrue(r.sample(-60).single().nearby)
    }
    @Test fun exactThresholdAndSingleSpikeDoNotQualify() {
        val r = Rig()
        repeat(5) { r.time = it * 500L; assertFalse(r.sample(-65).single().nearby) }
        r.time = 2_500; assertFalse(r.sample(-30).single().nearby)
    }
    @Test fun hysteresisRetainsNearCandidateThroughJitter() {
        val r = Rig(); r.qualify()
        repeat(8) { r.time += 300; assertTrue(r.sample(-70).single().nearby) }
    }
    @Test fun sustainedWeakSignalRemovesQualification() {
        val r = Rig(); r.qualify()
        repeat(3) { r.time += 100; r.sample(-80) }
        r.time += 2_999; assertTrue(r.sample(-80).single().nearby)
        r.time += 1; assertFalse(r.sample(-80).single().nearby)
    }
    @Test fun missingAndUnavailableSignalsExpire() {
        val r = Rig(); r.qualify()
        r.time = 5_999
        for (invalid in listOf(127, 0, -127, 20)) assertTrue(r.sample(invalid).single().nearby)
        r.time = 6_000; assertTrue(r.filter.current().isEmpty())
        assertNull(r.filter.nextExpiry)
    }
    @Test fun expiryResetsSmoothingAndQualification() {
        val r = Rig(); r.qualify(); r.time = 6_000
        assertFalse(r.sample(-60).single().nearby)
    }
    @Test fun boundedCandidatesAndClear() {
        val r = Rig()
        repeat(40) { r.sample(-60, it.toLong()) }
        assertEquals(32, r.filter.current().size)
        r.filter.clear(); assertTrue(r.filter.current().isEmpty())
        r.time = 0; assertEquals(1, r.sample(-60).size)
    }
    @Test fun clockRollbackIsRejected() {
        val r = Rig(); r.time = 10; r.sample(-60); r.time = 9
        assertThrows(IllegalStateException::class.java) { r.filter.current() }
    }
}
