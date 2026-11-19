// SPDX-License-Identifier: GPL-3.0-or-later
// Verifies monotonic manual-channel grace never extends on duplicate background events.
package io.github.anisharyal09.anice.infrastructure.connections

import org.junit.Assert.*
import org.junit.Test

class ManualBleGraceTests {
    @Test fun onlySecuredChannelsHaveABoundedReturnWindow() {
        val grace = ManualBleGrace()
        assertNull(grace.begin(0, false))
        assertFalse(grace.active(0))
        assertEquals(15_000L, grace.begin(0, true))
        assertTrue(grace.active(14_999))
        assertFalse(grace.active(15_000))
        assertFalse(grace.active(60_000))
    }
    @Test fun duplicateStopsCannotExtendDeadlineAndReturnStartsAFreshWindow() {
        val grace = ManualBleGrace()
        grace.begin(100, true)
        assertEquals(15_100L, grace.begin(14_000, true))
        grace.clear()
        assertFalse(grace.active(14_000))
        assertEquals(29_000L, grace.begin(14_000, true))
        grace.clear()
        assertNull(grace.deadline)
    }
}
