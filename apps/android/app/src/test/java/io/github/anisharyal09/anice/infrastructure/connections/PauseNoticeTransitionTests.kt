// SPDX-License-Identifier: GPL-3.0-or-later
// Proves that pause teardown is bounded and that cancelled or superseded sends cannot close newer work.
package io.github.anisharyal09.anice.infrastructure.connections

import java.io.IOException
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test

class PauseNoticeTransitionTests {
    @Test fun teardownWaitsForTheNoticeAndRunsOnlyOnce() = runBlocking {
        val scope = CoroutineScope(coroutineContext + SupervisorJob())
        val transition = PauseNoticeTransition(scope)
        try {
            val entered = CompletableDeferred<Unit>()
            val release = CompletableDeferred<Unit>()
            val closed = CompletableDeferred<Unit>()
            val events = mutableListOf<String>()
            transition.start(announce = { events.add("notice"); entered.complete(Unit); release.await(); events.add("sent") },
                teardown = { events.add("closed"); closed.complete(Unit) })
            withTimeout(1000) { entered.await() }
            assertEquals(listOf("notice"), events)
            release.complete(Unit)
            withTimeout(1000) { closed.await() }
            transition.cancel()
            assertEquals(listOf("notice", "sent", "closed"), events)
        } finally { transition.cancel(); scope.cancel() }
    }

    @Test fun newerResumeOrConnectWinsEvenWhenAnOldSendIgnoresCancellation() = runBlocking {
        val scope = CoroutineScope(coroutineContext + SupervisorJob())
        val transition = PauseNoticeTransition(scope)
        val release = CompletableDeferred<Unit>()
        try {
            val entered = CompletableDeferred<Unit>()
            val returned = CompletableDeferred<Unit>()
            var oldClosed = 0
            var newClosed = 0
            transition.start(announce = {
                entered.complete(Unit)
                withContext(NonCancellable) { release.await() }
                returned.complete(Unit)
            }, teardown = { oldClosed++ })
            withTimeout(1000) { entered.await() }
            transition.cancel()
            transition.start(announce = {}, teardown = { newClosed++ })
            release.complete(Unit)
            withTimeout(1000) { returned.await() }
            yield()
            assertEquals(0, oldClosed)
            assertEquals(1, newClosed)
        } finally { release.complete(Unit); transition.cancel(); scope.cancel() }
    }

    @Test fun deadlineDoesNotWaitForANonceOwnedProducerToReturn() = runBlocking {
        val scope = CoroutineScope(coroutineContext + SupervisorJob())
        val transition = PauseNoticeTransition(scope, budgetMillis = 10)
        val release = CompletableDeferred<Unit>()
        try {
            val entered = CompletableDeferred<Unit>()
            val returned = CompletableDeferred<Unit>()
            val closed = CompletableDeferred<Unit>()
            var closes = 0
            transition.start(announce = {
                entered.complete(Unit)
                withContext(NonCancellable) { release.await() }
                returned.complete(Unit)
            }, teardown = { closes++; closed.complete(Unit) })
            withTimeout(1000) { entered.await(); closed.await() }
            assertFalse(returned.isCompleted)
            release.complete(Unit)
            withTimeout(1000) { returned.await() }
            yield()
            assertEquals(1, closes)
        } finally { release.complete(Unit); transition.cancel(); scope.cancel() }
    }

    @Test fun failedMetadataStillClosesAndANewerPauseSupersedesTheOldOne() = runBlocking {
        val scope = CoroutineScope(coroutineContext + SupervisorJob())
        val transition = PauseNoticeTransition(scope)
        try {
            var oldClosed = 0
            var newClosed = 0
            val closed = CompletableDeferred<Unit>()
            transition.start(announce = { awaitCancellation() }, teardown = { oldClosed++ })
            transition.start(announce = { throw IOException("unavailable") },
                teardown = { newClosed++; closed.complete(Unit) })
            withTimeout(1000) { closed.await() }
            assertEquals(0, oldClosed); assertEquals(1, newClosed)
        } finally { transition.cancel(); scope.cancel() }
    }
}
