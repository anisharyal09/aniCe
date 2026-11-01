// SPDX-License-Identifier: GPL-3.0-or-later
// Qualifies LAN throughput and bounds transfer sender credit.
package io.github.anisharyal09.anice.features.transfer

// Reduced LAN chunks need immediate credit to keep the sender's smaller pipeline supplied.
internal fun transferAckThreshold(maximumChunk: Long, maximumWindow: Long, chunkBytes: Long): Long {
    if (maximumChunk <= 3072) return maximumChunk * minOf(8L, maxOf(1L, maximumWindow / 2))
    val chunk = minOf(maximumChunk, chunkBytes)
    return chunk * if (maximumChunk > 4096 && chunk < maximumChunk) 1L else maxOf(1L, maximumWindow / 4)
}

// Bounds unacknowledged LAN bytes before allowing the negotiated high-throughput window.
internal class TransferSendWindow(private val maximumChunk: Long, private val maximumWindow: Long,
    private val lan: Boolean, started: Long) {
    private var probing = lan && maximumChunk > 4096
    private var probeSubmitted = false
    private var constrained = false
    private var lastAcknowledgedAt = started
    private var probeStartedAt = started
    private var reprobe = false
    private var drainRequested = false
    private var draining = false
    private var decision: Boolean? = null
    private var timelySince: Long? = null
    // Sustained fallback amortizes live per-record validation under a 128-KiB fallback backlog cap.
    val chunkBytes get() = when {
        probing -> minOf(4096L, maximumChunk)
        constrained -> minOf(65536L, maximumChunk)
        else -> maximumChunk
    }
    val creditBytes get() = chunkBytes * when {
        probing || draining -> 1L
        constrained -> minOf(2L, maximumWindow)
        else -> maximumWindow
    }
    // Source IO and encoding precede submission and cannot measure the path's acknowledgement delay.
    fun beginSubmission(now: Long, windowEmpty: Boolean = false) {
        if (probing && !probeSubmitted) {
            lastAcknowledgedAt = now
            probeStartedAt = now
            probeSubmitted = true
        } else if (!probing && windowEmpty) {
            if (now - lastAcknowledgedAt > 100) timelySince = null
            lastAcknowledgedAt = now
        }
    }
    // Only advancing, correlated ACKs reach this method; duplicates cannot qualify a fast path.
    fun acknowledged(now: Long, fullyConfirmed: Boolean) {
        if (probing && !fullyConfirmed) return
        val elapsed = now - lastAcknowledgedAt
        if (probing) { if (decision == null) decision = elapsed > 100 }
        else if (constrained) {
            if (elapsed > 100) timelySince = null else if (timelySince == null) timelySince = lastAcknowledgedAt
            // Batched ACK arrivals cannot qualify recovery without a full second of steady progress.
            val stable = timelySince?.let { now - it >= 1000 } == true
            if (draining && fullyConfirmed || stable && now - probeStartedAt >= 5000) {
                if (fullyConfirmed) reprobe = true else drainRequested = true
            }
        }
        else if (lan && maximumChunk > 4096 && elapsed > 1000) decision = true
        lastAcknowledgedAt = now
    }
    // Apply shrinkage between records, never while a previously admitted source read is suspended.
    fun advance() {
        decision?.let { constrained = it; probing = false; timelySince = null }
        decision = null
        // A one-chunk budget drains a continuously replenished two-chunk pipeline before probing.
        if (drainRequested) { draining = true; drainRequested = false }
        if (reprobe) { probing = true; probeSubmitted = false; draining = false; probeStartedAt = lastAcknowledgedAt; reprobe = false }
    }
}
