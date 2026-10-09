// SPDX-License-Identifier: GPL-3.0-or-later
// Keeps legacy native NSD resolutions exclusive across coroutine cancellation and timeout.
package io.github.anisharyal09.anice.infrastructure.lan

import kotlinx.coroutines.CompletableDeferred

class LegacyResolutionLane<T> {
    data class Request<T>(val token: Long, val result: CompletableDeferred<T>)

    private var serial = 0L
    private var active: Request<T>? = null

    @Synchronized
    fun begin(): Request<T> {
        check(active == null) {
            "Local-network discovery is still finishing. Retry when available."
        }
        return Request(++serial, CompletableDeferred<T>()).also { active = it }
    }

    @Synchronized
    fun finish(token: Long, result: Result<T>) {
        val request = active?.takeIf { it.token == token } ?: return
        active = null
        result.fold({ request.result.complete(it) }, { request.result.completeExceptionally(it) })
    }
}
