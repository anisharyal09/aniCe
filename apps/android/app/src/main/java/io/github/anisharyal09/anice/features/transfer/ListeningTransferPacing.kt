// SPDX-License-Identifier: GPL-3.0-or-later
// Recovers bounded file credit only while current listening health advances without underruns.
package io.github.anisharyal09.anice.features.transfer

internal class ListeningTransferPacing {
    var creditBytes = 131072L
        private set
    private var healthySince: Long? = null
    private var lastSequence = 0L
    private var lastUnderruns: Long? = null
    private var lastReport: Long? = null

    fun reset() {
        creditBytes = 131072
        healthySince = null
        lastSequence = 0
        lastUnderruns = null
        lastReport = null
    }

    fun report(healthy: Boolean, sequence: Long, underruns: Long, now: Long) {
        val progressing = sequence > lastSequence
        val starved = lastUnderruns?.let { underruns > it } ?: false
        val stale = lastReport?.let { now - it > 2500 } ?: false
        lastSequence = maxOf(lastSequence, sequence)
        lastUnderruns = underruns
        lastReport = now
        if (!healthy || !progressing || starved || stale) {
            creditBytes = 131072
            healthySince = null
            return
        }
        val since = healthySince
        if (since == null) { healthySince = now; return }
        if (now - since >= 4000) {
            creditBytes = minOf(1048576, creditBytes + 131072)
            healthySince = now
        }
    }
}
