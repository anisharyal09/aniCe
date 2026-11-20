// SPDX-License-Identifier: GPL-3.0-or-later
// Bounds foreground handoff retention of an existing manual BLE channel, never reconnecting it.
package io.github.anisharyal09.anice.infrastructure.connections

internal class ManualBleGrace {
    var deadline: Long? = null
        private set
    fun begin(now: Long, secured: Boolean): Long? {
        if (!secured) return null
        if (deadline == null) deadline = now + 15_000
        return deadline
    }
    fun active(now: Long) = deadline?.let { now < it } == true
    fun clear() { deadline = null }
}
