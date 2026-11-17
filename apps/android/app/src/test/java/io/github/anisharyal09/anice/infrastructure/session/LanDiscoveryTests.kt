// SPDX-License-Identifier: GPL-3.0-or-later
// Exercises streaming discovery bounds, late candidates, service loss and callback retirement.
package io.github.anisharyal09.anice.infrastructure.session

import io.github.anisharyal09.anice.infrastructure.lan.LanDiscoveryCandidates
import io.github.anisharyal09.anice.infrastructure.lan.NsdResolutionFailure
import io.github.anisharyal09.anice.infrastructure.lan.consumeLanEndpoints
import io.github.anisharyal09.anice.infrastructure.lan.consumeLanCandidates
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.produceIn
import kotlinx.coroutines.flow.toList
import org.junit.Assert.*
import org.junit.Test

class LanDiscoveryTests {
    @Test fun missingAuthenticatedEndpointStartsOnlyBoundedDiscovery() = runBlocking {
        for (ready in listOf(true, false)) {
            var browses = 0
            val attempts = mutableListOf<Pair<String, Boolean>>()
            val discovered = (0..20).map { "discovered-$it" }
            assertEquals(ready, consumeLanCandidates<String>(null, discover = {
                browses++; kotlinx.coroutines.flow.flowOf(*discovered.toTypedArray())
            }, key = { it }) { endpoint, direct -> attempts.add(endpoint to direct); ready })
            assertEquals(1, browses)
            assertEquals(discovered.take(if (ready) 1 else 8).map { it to false }, attempts)
        }
    }

    @Test fun directReadinessNeverCreatesDiscovery() = runBlocking {
        var browses = 0
        val attempts = mutableListOf<Pair<String, Boolean>>()
        assertTrue(consumeLanCandidates("direct", discover = {
            browses++; kotlinx.coroutines.flow.flowOf("discovered")
        }, key = { it }) { endpoint, direct -> attempts.add(endpoint to direct); true })
        assertEquals(0, browses)
        assertEquals(listOf("direct" to true), attempts)
    }

    @Test fun discoveryWaitsForDirectFailureAndSharesItsEndpointBound() = runBlocking {
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        var browses = 0
        val attempts = mutableListOf<String>()
        val work = async {
            consumeLanCandidates("same", discover = {
                browses++; kotlinx.coroutines.flow.flowOf("same", *(0..20).map { "fallback-$it" }.toTypedArray())
            }, key = { it }) { endpoint, direct ->
                attempts.add(endpoint)
                if (direct) { entered.complete(Unit); release.await() }
                false
            }
        }
        try {
            withTimeout(1000) { entered.await() }
            assertEquals(0, browses)
            release.complete(Unit)
            assertFalse(withTimeout(1000) { work.await() })
            assertEquals(1, browses)
            assertEquals(listOf("same") + (0..6).map { "fallback-$it" }, attempts)
        } finally { release.complete(Unit); work.cancelAndJoin() }
    }

    @Test fun directAuthenticationFailureAndCancellationDoNotBrowse() = runBlocking {
        var browses = 0
        try {
            consumeLanCandidates("direct", discover = {
                browses++; kotlinx.coroutines.flow.flowOf("fallback")
            }, key = { it }) { _, _ -> throw SessionException(SessionFailure.AUTHENTICATION) }
            fail("Authentication failure was swallowed")
        } catch (error: SessionException) { assertEquals(SessionFailure.AUTHENTICATION, error.reason) }
        val entered = CompletableDeferred<Unit>()
        val work = launch {
            consumeLanCandidates("direct", discover = {
                browses++; kotlinx.coroutines.flow.flowOf("fallback")
            }, key = { it }) { _, _ -> entered.complete(Unit); awaitCancellation() }
        }
        withTimeout(1000) { entered.await(); work.cancelAndJoin() }
        assertTrue(work.isCancelled)
        assertEquals(0, browses)
    }

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
