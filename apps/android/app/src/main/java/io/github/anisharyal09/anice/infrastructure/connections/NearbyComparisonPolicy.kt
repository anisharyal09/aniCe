// SPDX-License-Identifier: GPL-3.0-or-later
// Selects only an unambiguous qualified candidate and never retries a dismissed comparison automatically.
package io.github.anisharyal09.anice.infrastructure.connections

internal class NearbyComparisonPolicy {
    private var chooserRequired = false
    private var consumed = false
    val requiresSelection get() = chooserRequired
    val allowsAutomatic get() = !chooserRequired && !consumed

    fun candidate(ids: List<Long>, eligible: Boolean, dismissed: Boolean): Long? {
        if (!eligible || dismissed || consumed) return null
        if (ids.size > 1) chooserRequired = true
        if (chooserRequired || ids.size != 1) return null
        consumed = true
        return ids.single()
    }

    fun reset() { chooserRequired = false; consumed = false }
}
