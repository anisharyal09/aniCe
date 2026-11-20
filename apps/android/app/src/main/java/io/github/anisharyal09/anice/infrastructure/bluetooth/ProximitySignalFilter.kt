// SPDX-License-Identifier: GPL-3.0-or-later
// Qualifies anonymous scan-local candidates without treating signal strength as authentication.
package io.github.anisharyal09.anice.infrastructure.bluetooth

/**
 * Caller-confined, memory-only RSSI policy. Candidate keys must be scan-local handles, not identities.
 * Both observation and expiry use a monotonic clock. No radio work or storage access occurs here.
 */
internal class ProximitySignalFilter(
    private val now: () -> Long,
    private val capacity: Int = 32,
) {
    data class Candidate(val id: Long, val rssi: Int, val nearby: Boolean)
    private data class Signal(
        var samples: MutableList<Int> = mutableListOf(),
        var seen: Long,
        var strongSince: Long? = null,
        var weakSince: Long? = null,
        var nearby: Boolean = false,
    )
    private val signals = linkedMapOf<Long, Signal>()
    private var lastInstant = Long.MIN_VALUE

    init { require(capacity in 1..32) }

    /** The platform's unavailable value (127), zero and implausible RSSI never refresh presence. */
    fun observe(id: Long, rssi: Int): List<Candidate> {
        val instant = instant()
        expire(instant)
        if (rssi !in -126..-1) return snapshot()
        val signal = signals[id] ?: run {
            if (signals.size >= capacity) return snapshot()
            Signal(seen = instant).also { signals[id] = it }
        }
        signal.seen = instant
        signal.samples.add(rssi)
        if (signal.samples.size > 5) signal.samples.removeAt(0)
        val median = median(signal)
        if (median > -65) {
            signal.weakSince = null
            if (signal.strongSince == null) signal.strongSince = instant
            if (signal.samples.size >= 3 && instant - signal.strongSince!! >= 1_000)
                signal.nearby = true
        } else {
            signal.strongSince = null
            if (median < -72) {
                if (signal.weakSince == null) signal.weakSince = instant
                if (instant - signal.weakSince!! >= 3_000) signal.nearby = false
            } else signal.weakSince = null
        }
        return snapshot()
    }

    fun current(): List<Candidate> { expire(instant()); return snapshot() }
    val nextExpiry: Long? get() = signals.values.minOfOrNull { it.seen + 5_000 }
    fun clear() { signals.clear(); lastInstant = Long.MIN_VALUE }

    private fun instant(): Long {
        val value = now()
        check(value >= lastInstant) { "Proximity requires a monotonic clock" }
        lastInstant = value
        return value
    }
    private fun expire(instant: Long) { signals.entries.removeAll { instant - it.value.seen >= 5_000 } }
    private fun median(signal: Signal): Int = signal.samples.sorted()[signal.samples.size / 2]
    private fun snapshot() = signals.map { (id, signal) -> Candidate(id, median(signal), signal.nearby) }
}
