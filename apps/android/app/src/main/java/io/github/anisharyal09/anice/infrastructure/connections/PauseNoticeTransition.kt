// SPDX-License-Identifier: GPL-3.0-or-later
// Bounds a pause notice independently of its producer and fences teardown after newer user actions.
package io.github.anisharyal09.anice.infrastructure.connections

import kotlinx.coroutines.*

internal class PauseNoticeTransition(private val scope: CoroutineScope, private val budgetMillis: Long = 1_000L) {
    private var active: Any? = null
    private var sending: Job? = null
    private var deadline: Job? = null

    fun start(announce: suspend () -> Unit, teardown: () -> Unit) {
        cancel()
        val token = Any()
        active = token
        fun finish() {
            if (active !== token) return
            cancel()
            teardown()
        }
        sending = scope.launch(start = CoroutineStart.LAZY) {
            try { announce() }
            catch (error: CancellationException) { throw error }
            catch (_: Exception) { /* Best effort; unavailable DATA must not prevent Pause. */ }
            if (isActive) finish()
        }
        deadline = scope.launch(start = CoroutineStart.LAZY) { delay(budgetMillis); finish() }
        sending?.start()
        deadline?.start()
    }

    fun cancel() {
        active = null
        sending?.cancel(); sending = null
        deadline?.cancel(); deadline = null
    }
}
