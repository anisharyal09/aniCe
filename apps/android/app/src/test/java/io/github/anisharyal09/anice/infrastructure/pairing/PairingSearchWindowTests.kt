// SPDX-License-Identifier: GPL-3.0-or-later
// Checks rendezvous search deadlines and candidate bounds across resumed scans.
package io.github.anisharyal09.anice.infrastructure.pairing

import io.github.anisharyal09.anice.infrastructure.bluetooth.PairingSearchWindow
import org.junit.Assert.*
import org.junit.Test

class PairingSearchWindowTests {
    @Test
    fun immediateConnectionAndWrongCandidateDoNotExtendSearch() {
        var now = 100L
        val search = PairingSearchWindow<String> { now }
        search.begin()
        assertTrue(search.claim("first")) // no wait for the full scan timer
        now += 2000
        assertFalse(search.claim("first"))
        assertTrue(search.claim("second"))
        assertEquals(15100L, search.deadline)
        now = search.deadline
        assertFalse(search.canContinue())
        assertFalse(search.claim("third"))
    }

    @Test
    fun boundedCandidatesAndFreshRestart() {
        var now = 0L
        val search = PairingSearchWindow<Int> { now }
        search.begin()
        for (i in 0 until 32) assertTrue(search.claim(i))
        assertFalse(search.claim(32))
        search.clear()
        assertFalse(search.canContinue())
        now = 100000
        search.begin()
        assertTrue(search.claim(0))
        assertEquals(115000L, search.deadline)
    }
}
