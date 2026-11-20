// SPDX-License-Identifier: GPL-3.0-or-later
// Tests progressive credit recovery and immediate audio-health contraction without changing negotiated file data.
package io.github.anisharyal09.anice.features.transfer

import org.junit.Assert.*
import org.junit.Test

class ListeningTransferPacingTests {
    @Test fun onlyAdvancingHealthyAudioRecoversBoundedCredit() {
        val pacing = ListeningTransferPacing()
        for (second in 0L..8) pacing.report(true, second + 1, 0, second * 1000)
        assertEquals(393216L, pacing.creditBytes)
        pacing.report(true, 10, 1, 9000)
        assertEquals(131072L, pacing.creditBytes)
        for (second in 10L..45) pacing.report(true, second + 1, 1, second * 1000)
        assertEquals(1048576L, pacing.creditBytes)
        pacing.report(false, 47, 1, 46000)
        assertEquals(131072L, pacing.creditBytes)
    }

    @Test fun duplicateOrStaleReportsCannotRetainExpandedCredit() {
        val pacing = ListeningTransferPacing()
        for (second in 0L..4) pacing.report(true, second + 1, 0, second * 1000)
        assertEquals(262144L, pacing.creditBytes)
        pacing.report(true, 5, 0, 5000)
        assertEquals(131072L, pacing.creditBytes)
        for (second in 6L..10) pacing.report(true, second + 1, 0, second * 1000)
        assertEquals(262144L, pacing.creditBytes)
        pacing.report(true, 12, 0, 15000)
        assertEquals(131072L, pacing.creditBytes)
    }
}
