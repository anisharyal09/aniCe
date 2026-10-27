// SPDX-License-Identifier: GPL-3.0-or-later
// Exercises streaming discovery bounds, late candidates, service loss and callback retirement.
package io.github.anisharyal09.anice.infrastructure.session

import io.github.anisharyal09.anice.infrastructure.lan.LanDiscoveryCandidates
import io.github.anisharyal09.anice.infrastructure.lan.NsdResolutionFailure
import io.github.anisharyal09.anice.infrastructure.lan.consumeLanEndpoints
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.produceIn
import kotlinx.coroutines.flow.toList
import org.junit.Assert.*
import org.junit.Test

class LanDiscoveryTests {
    @Test fun ownerCancellationRetiresDiscoveryWithoutBecomingAFailure() = runBlocking {
        val candidates = LanDiscoveryCandidates<String>()
        val resolving = CompletableDeferred<Unit>()
        val retired = CompletableDeferred<Unit>()
        var cancelled = false
        var failed = false
        val owner = launch {
            try {
                candidates.endpoints<String>(key = { it }) {
                    try { resolving.complete(Unit); awaitCancellation() }
                    finally { retired.complete(Unit) }
                }.consumeLanEndpoints { endpoints ->
                    candidates.offer("mac", "locator")
                    for (endpoint in endpoints) fail("Cancelled resolution emitted $endpoint")
                }
            } catch (error: CancellationException) { cancelled = true; throw error }
            catch (_: NsdResolutionFailure) { failed = true }
        }
        try {
            withTimeout(1000) { resolving.await() }
            withTimeout(1000) { owner.cancelAndJoin() }
            assertTrue(cancelled)
            assertTrue(owner.isCancelled)
            assertTrue(retired.isCompleted)
            assertFalse(failed)
        } finally { owner.cancelAndJoin(); candidates.close() }
    }

    @Test fun discoveryFailuresReachTheOwnerHandlerWithoutCancellingIt() = runBlocking {
        for (duringResolution in listOf(false, true)) {
            val candidates = LanDiscoveryCandidates<String>()
            val uncaught = mutableListOf<Throwable>()
            var handled = false
            val owner = launch(CoroutineExceptionHandler { _, error -> uncaught.add(error) }) {
                try {
                    candidates.endpoints<String>(key = { it }) { throw NsdResolutionFailure(3) }
                        .consumeLanEndpoints { endpoints ->
                            if (duringResolution) candidates.offer("mac", "locator")
                            else candidates.close(NsdResolutionFailure(3))
                            for (endpoint in endpoints) fail("Failed discovery emitted $endpoint")
                        }
                } catch (error: NsdResolutionFailure) {
                    assertEquals(3, error.code)
                    handled = true
                }
            }
            try {
                withTimeout(1000) { owner.join() }
                assertTrue("Owner error handler was bypassed", handled)
                assertFalse("Discovery failure cancelled its owner", owner.isCancelled)
                assertTrue("Discovery failure escaped uncaught", uncaught.isEmpty())
            } finally { owner.cancelAndJoin(); candidates.close() }
        }
    }

    @Test fun consumerFailureCancelsAndDrainsAnActiveResolver() = runBlocking {
        val candidates = LanDiscoveryCandidates<String>()
        val resolving = CompletableDeferred<Unit>()
        val retired = CompletableDeferred<Unit>()
        val failure = java.io.IOException("injected authentication failure")
        try {
            candidates.endpoints<String>(key = { it }) {
                try { resolving.complete(Unit); awaitCancellation() }
                finally { retired.complete(Unit) }
            }.consumeLanEndpoints {
                candidates.offer("mac", "locator")
                withTimeout(1000) { resolving.await() }
                throw failure
            }
            fail("Consumer failure was swallowed")
        } catch (error: java.io.IOException) { assertEquals(failure.message, error.message) }
        finally { candidates.close() }
        assertTrue("Resolver cleanup outlived its consumer", retired.isCompleted)
    }

    @Test fun wrongMacFirstDoesNotHideSelectedMacArrivingLater() = runBlocking {
        val candidates = LanDiscoveryCandidates<String>()
        val endpoints = candidates.endpoints(key = { it }) { listOf(it) }.produceIn(this)
        try {
            candidates.offer("first", "wrong-mac")
            assertEquals("wrong-mac", withTimeout(1000) { endpoints.receive() })
            // The first locator has already been delivered while discovery remains open.
            candidates.offer("later", "selected-mac")
            assertEquals("selected-mac", withTimeout(1000) { endpoints.receive() })
        } finally { endpoints.cancel(); candidates.close() }
    }

    @Test fun boundsApplyToDistinctServicesAndDeduplicatedEndpoints() = runBlocking {
        val candidates = LanDiscoveryCandidates<Int>()
        repeat(10) { candidates.offer("service-$it", it); candidates.offer("service-$it", 100 + it) }
        val resolved = mutableListOf<Int>()
        val result = withTimeout(1000) {
            candidates.endpoints(key = { it }) {
                resolved.add(it)
                listOf(it.toString(), it.toString())
            }.toList()
        }
        assertEquals((0..7).toList(), resolved)
        assertEquals((0..7).map { it.toString() }, result)
        candidates.close()
        val addresses = LanDiscoveryCandidates<Int>()
        addresses.offer("one-service", 0)
        val limited = withTimeout(1000) { addresses.endpoints(key = { it.toString() }) { (0..20).toList() }.toList() }
        assertEquals((0..7).toList(), limited)
        addresses.close()
    }

    @Test fun serviceLostDuringResolutionCannotPublishItsStaleAddress() = runBlocking {
        val candidates = LanDiscoveryCandidates<String>()
        val resolving = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val endpoints = candidates.endpoints(key = { it }) {
            if (it == "lost") { resolving.complete(Unit); release.await() }
            listOf(it)
        }.produceIn(this)
        try {
            candidates.offer("old", "lost")
            withTimeout(1000) { resolving.await() }
            candidates.lost("old")
            candidates.offer("new", "selected")
            release.complete(Unit)
            assertEquals("selected", withTimeout(1000) { endpoints.receive() })
        } finally { endpoints.cancel(); candidates.close() }
    }

    @Test fun cancellationFencesResolutionAndLaterNativeCallbacks() = runBlocking {
        val candidates = LanDiscoveryCandidates<String>()
        val resolving = CompletableDeferred<Unit>()
        val retired = CompletableDeferred<Unit>()
        val endpoints = candidates.endpoints<String>(key = { it }) {
            try { resolving.complete(Unit); awaitCancellation() }
            finally { retired.complete(Unit) }
        }.produceIn(this)
        candidates.offer("old", "old-address")
        withTimeout(1000) { resolving.await() }
        endpoints.cancel()
        withTimeout(1000) { retired.await() }
        candidates.close()
        candidates.offer("late", "late-address")
        assertTrue(candidates.endpoints<String>(key = { it }) { listOf(it) }.toList().isEmpty())
    }

    @Test fun alreadyActiveFailureIsTerminalInsteadOfResolvingMoreCandidates() = runBlocking {
        val candidates = LanDiscoveryCandidates<String>()
        candidates.offer("stale", "stale-address")
        candidates.close(NsdResolutionFailure(3))
        var resolved = false
        try {
            candidates.endpoints(key = { it }) { resolved = true; listOf(it) }.toList()
            fail("Native resolution failure must terminate discovery")
        } catch (error: NsdResolutionFailure) { assertEquals(3, error.code) }
        assertFalse(resolved)
    }
}
