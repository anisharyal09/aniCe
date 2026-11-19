// SPDX-License-Identifier: GPL-3.0-or-later
// Retains the elapsed-realtime idle interval independently of a LAN socket generation.
package io.github.anisharyal09.anice.infrastructure.connections

internal class LanBackgroundIdle {
    private var since: Long? = null
    var deadline: Long? = null
        private set

    fun update(now: Long, backgrounded: Boolean, leased: Boolean, timeoutMillis: Long): Long? {
        if (!backgrounded || leased) {
            since = null
            deadline = null
        } else {
            val start = since ?: now.also { since = it }
            deadline = timeoutMillis.takeIf { it > 0 }?.let {
                if (start > Long.MAX_VALUE - it) Long.MAX_VALUE else start + it
            }
        }
        return deadline
    }

    fun expired(now: Long): Boolean = deadline?.let { now >= it } == true
}
