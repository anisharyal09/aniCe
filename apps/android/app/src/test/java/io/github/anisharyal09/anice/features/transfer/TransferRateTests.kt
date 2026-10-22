// SPDX-License-Identifier: GPL-3.0-or-later
// Probes the rolling-window rate: recency, the two-observation floor, stalls and window bounds.
package io.github.anisharyal09.anice.features.transfer

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class TransferRateTests {
    @Test
    fun recentSliceDecidesTheRateNotTheLifetimeAverage() {
        val rate = TransferRate(samples = 3)
        assertEquals(0.0, rate.add(0L, 0L), 0.0)
        assertEquals(10485760.0, rate.add(1048576L, 100L), 1.0)
        // The origin is still in the window, so this covers the whole 200 ms observed so far.
        assertEquals(5898240.0, rate.add(1179648L, 200L), 1.0)
        // 1 MiB at t=0 has aged out: only 128 KiB across the window's 200 ms remains, so the rate
        // must drop 16x. A lifetime average would still report 3932160 B/s here, which is the drift
        // this replaced.
        assertEquals(655360.0, rate.add(1179648L, 300L), 1.0)
        assertEquals(0.0, rate.add(1179648L, 400L), 1.0)
    }

    @Test
    fun anIncompleteWindowMeasuresFromItsOldestSample() {
        val rate = TransferRate()
        assertEquals(0.0, rate.add(4096L, 0L), 0.0)
        // Two observations at one instant span no time and cannot yield a rate.
        assertEquals(0.0, rate.add(8192L, 0L), 0.0)
        assertEquals(0.0, rate.add(8192L, 0L), 0.0)
        // 4096 B arrived across the window's single elapsed second; the lifetime average is 8192 B/s.
        assertEquals(4096.0, rate.add(8192L, 1000L), 1.0)
    }

    @Test
    fun defaultWindowKeepsBurstyConfirmationsButStillExpiresARealStall() {
        val rate = TransferRate()
        rate.add(0, 0)
        for (sample in 1..12) assertEquals(262144000.0 / (sample * 250), rate.add(262144, sample * 250L), 0.001)
        for (sample in 13..20) rate.add(262144, sample * 250L)
        assertEquals(0.0, rate.add(262144, 5250), 0.0)
    }

    @Test
    fun aWindowShorterThanTwoObservationsCannotMeasureAnything() {
        assertThrows(IllegalArgumentException::class.java) { TransferRate(samples = 1) }
        assertThrows(IllegalArgumentException::class.java) { TransferRate(samples = 0) }
        TransferRate(samples = 2)
    }
}
