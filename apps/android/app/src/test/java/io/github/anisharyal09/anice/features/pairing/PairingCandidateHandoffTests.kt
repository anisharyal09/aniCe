// SPDX-License-Identifier: GPL-3.0-or-later
// Exercises the production one-shot post-trust handoff without native locators, devices or reflection.
package io.github.anisharyal09.anice.features.pairing

import org.junit.Assert.*
import org.junit.Test

class PairingCandidateHandoffTests {
    @Test fun pendingTrustAndCleanupCannotConsumeTheCandidate() {
        val discarded = mutableListOf<Any>()
        val handoff = PairingCandidateHandoff<Any> { discarded.add(it) }
        val candidate = Any()
        handoff.offer(candidate)
        for (phase in listOf("idle", "scan", "connecting", "authenticating", "comparison",
            "approval", "waiting", "verifying", "saving", "cleanup", "failed", "cancelling")) {
            assertNull(phase, handoff.take(phase))
        }
        assertSame(candidate, handoff.take("paired"))
        repeat(10) { assertNull(handoff.take("paired")) }
        assertTrue(discarded.isEmpty())
    }

    @Test fun replacingOrCancellingDiscardsOnlyTheUnconsumedCandidate() {
        val discarded = mutableListOf<Any>()
        val handoff = PairingCandidateHandoff<Any> { discarded.add(it) }
        val old = Any()
        val next = Any()
        handoff.offer(old)
        handoff.offer(next)
        assertEquals(listOf(old), discarded)
        handoff.clear()
        handoff.clear()
        assertEquals(listOf(old, next), discarded)
        assertNull(handoff.take("paired"))
        val consumed = Any()
        handoff.offer(consumed)
        assertSame(consumed, handoff.take("paired"))
        handoff.clear()
        assertEquals(listOf(old, next), discarded)
    }
}
