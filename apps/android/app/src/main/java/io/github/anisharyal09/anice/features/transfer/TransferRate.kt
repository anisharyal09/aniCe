// SPDX-License-Identifier: GPL-3.0-or-later
// Measures an in-flight transfer rate over a bounded rolling window.
package io.github.anisharyal09.anice.features.transfer

/**
 * Reports the rate across the most recent [samples] observations rather than across the whole
 * transfer.
 *
 * A lifetime average (`total / elapsed`) cannot answer "how fast is it going now": it hides a ramp
 * up, keeps reporting a healthy number while the link has stalled, and drags a genuinely fast
 * second file down behind a slow first one. A bounded window decays toward zero when the link
 * stops delivering and reflects the current link again as soon as bytes resume.
 *
 * Samples are cumulative byte counts, so the caller passes the running total it already keeps.
 */
internal class TransferRate(private val samples: Int = 8) {
    init {
        require(samples >= 2) { "A rate needs two observations." }
    }

    private val counts = LongArray(samples)
    private val times = LongArray(samples)
    private var size = 0
    private var next = 0

    /**
     * Records [totalBytes] observed at [at] and returns the rate in bytes per second.
     * Returns `0.0` until two observations exist and whenever the window covers no progress, which
     * callers present as "no rate available" rather than as a measured zero.
     */
    fun add(totalBytes: Long, at: Long): Double {
        counts[next] = totalBytes
        times[next] = at
        next = (next + 1) % samples
        if (size < samples) size++
        if (size < 2) return 0.0
        val oldest = if (size < samples) 0 else next
        val newest = (next - 1 + samples) % samples
        val span = times[newest] - times[oldest]
        val delta = counts[newest] - counts[oldest]
        if (span <= 0L || delta <= 0L) return 0.0
        return delta * 1000.0 / span
    }
}
