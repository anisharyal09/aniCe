// SPDX-License-Identifier: GPL-3.0-or-later
// Verifies idle deadlines survive callbacks, socket replacement and elapsed time during suspension.
package io.github.anisharyal09.anice.infrastructure.connections

import org.junit.Assert.*
import org.junit.Test

class LanBackgroundIdleTests {
    @Test fun duplicateIdleEventsAndConnectionReplacementCannotExtendTheDeadline() {
        val idle = LanBackgroundIdle()
        assertEquals(60_100L, idle.update(100, true, false, 60_000))
        repeat(100) { assertEquals(60_100L, idle.update(50_000, true, false, 60_000)) }
        assertFalse(idle.expired(60_099))
        assertTrue(idle.expired(60_100))
        assertEquals(60_100L, idle.update(90_000, true, false, 60_000))
        assertTrue(idle.expired(90_000))
    }

    @Test fun workReleaseStartsOneNewIdleIntervalAndIdleCallbacksDoNotResetIt() {
        val idle = LanBackgroundIdle()
        idle.update(100, true, false, 60_000)
        assertNull(idle.update(30_000, true, true, 60_000))
        assertFalse(idle.expired(500_000))
        assertEquals(560_000L, idle.update(500_000, true, false, 60_000))
        assertEquals(560_000L, idle.update(559_999, true, false, 60_000))
        assertTrue(idle.expired(560_000))
    }

    @Test fun changingTheSettingUsesElapsedIdleTimeInsteadOfRestartingTheClock() {
        val idle = LanBackgroundIdle()
        assertNull(idle.update(100, true, false, 0))
        assertEquals(300_100L, idle.update(120_100, true, false, 300_000))
        assertEquals(60_100L, idle.update(120_100, true, false, 60_000))
        assertTrue(idle.expired(120_100))
        assertNull(idle.update(120_100, true, false, 0))
        assertFalse(idle.expired(Long.MAX_VALUE))
    }

    @Test fun appReturnCanObserveAnOverdueDeadlineBeforeClearingTheIdleInterval() {
        val idle = LanBackgroundIdle()
        idle.update(100, true, false, 300_000)
        assertTrue(idle.expired(500_100))
        assertNull(idle.update(500_100, false, false, 300_000))
        assertEquals(800_200L, idle.update(500_200, true, false, 300_000))
    }

    @Test fun lockAndHomeShareAnIdleIntervalButAVisibleAppIsNotIdle() {
        val idle = LanBackgroundIdle()
        assertNull(idle.update(100, false, false, 60_000))
        assertEquals(60_200L, idle.update(200, true, false, 60_000))
        assertEquals(60_200L, idle.update(30_000, true, false, 60_000))
        assertNull(idle.update(40_000, false, false, 60_000))
        assertEquals(100_100L, idle.update(40_100, true, false, 60_000))
    }
}
