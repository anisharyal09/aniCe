// SPDX-License-Identifier: GPL-3.0-or-later
// Tunes local buffering without changing wire format, headphone authorization or the hard audio budget.
package io.github.anisharyal09.anice.features.privatelistening

internal enum class ListeningBufferProfile(
    val preference: String,
    val initialFrames: Int,
    val minimumFrames: Int,
    val maximumFrames: Int,
) {
    BALANCED("balanced", 9600, 7680, 15360),
    LOWER_DELAY("lower_delay", 3840, 3840, 7680);

    companion object {
        fun restored(value: String?): ListeningBufferProfile =
            entries.firstOrNull { it.preference == value } ?: BALANCED
    }
}

/** Arrival spacing is local jitter, not a synchronized source-to-headphone latency measurement. */
internal class PrivateListeningBufferPolicy(
    private val profile: ListeningBufferProfile = ListeningBufferProfile.BALANCED,
) {
    @Volatile var targetFrames = profile.initialFrames
        private set
    private var previousSequence: Long? = null
    private var previousArrival: Long? = null
    private var lateMillis = 0.0
    private var stableSince: Long? = null
    private var lastIncrease: Long? = null
    private var previousUnderruns: Long? = null

    @Synchronized fun arrived(sequence: Long, now: Long) {
        require(sequence > 0 && now >= 0)
        val previous = previousSequence
        val at = previousArrival
        if (previous != null && sequence <= previous) return
        if (previous != null && at != null && now >= at) {
            val expected = (sequence - previous).toDouble() * 20
            val late = (now - at - expected).coerceIn(0.0, 1000.0)
            // React quickly to late bursts, but let old jitter fade rather than retaining a lifetime maximum.
            lateMillis += (late - lateMillis) * if (late > lateMillis) 0.25 else 0.02
            val jitterTarget = profile.minimumFrames + (lateMillis * 2 * 48).toInt()
            if (jitterTarget > targetFrames) increase(jitterTarget, now)
        }
        previousSequence = sequence
        previousArrival = now
    }

    @Synchronized fun underruns(count: Long, now: Long, playing: Boolean = true) {
        require(count >= 0 && now >= 0)
        val previous = previousUnderruns
        previousUnderruns = count
        if (playing && previous != null && count > previous) starved(now)
    }

    @Synchronized fun starved(now: Long) {
        require(now >= 0)
        // One continuous starvation episode must not inflate the target every worker turn.
        if (lastIncrease?.let { now - it < 1000 } == true) return
        increase(targetFrames + 1920, now)
    }

    @Synchronized fun healthy(now: Long) {
        require(now >= 0)
        val stable = stableSince
        if (stable == null) { stableSince = now; return }
        if (now - stable < 10000) return
        stableSince = now
        val jitterFloor = roundPacket(profile.minimumFrames + (lateMillis * 2 * 48).toInt())
            .coerceAtMost(profile.maximumFrames)
        targetFrames = maxOf(jitterFloor, targetFrames - 960)
    }

    @Synchronized fun interrupted() {
        previousSequence = null
        previousArrival = null
        previousUnderruns = null
        stableSince = null
        lateMillis = 0.0
    }

    @Synchronized fun buffering() { stableSince = null }

    private fun increase(frames: Int, now: Long) {
        targetFrames = roundPacket(frames).coerceIn(profile.minimumFrames, profile.maximumFrames)
        lastIncrease = now
        stableSince = null
    }

    private fun roundPacket(frames: Int) = (frames + 959) / 960 * 960
}

/** Memory capacity is not a requirement to keep that much audio pending in AudioTrack. */
internal object PrivateListeningNativeBufferPolicy {
    const val MAXIMUM_NATIVE_FRAMES = 37400 // Leaves one bounded resampler output under the 800-ms ceiling.
    fun requestedFrames(targetFrames: Int): Int {
        require(targetFrames in 960..38400)
        return maxOf(1920, targetFrames / 2).coerceAtMost(MAXIMUM_NATIVE_FRAMES)
    }

    fun writeLimit(requested: Int, effectiveBuffer: Int, startThreshold: Int?): Int {
        require(requested > 0 && effectiveBuffer in 1..MAXIMUM_NATIVE_FRAMES)
        // API 29/30 start at the effective buffer size; never starve an unadjustable startup threshold.
        val startup = (startThreshold ?: effectiveBuffer).coerceIn(1, effectiveBuffer)
        return maxOf(requested, startup).coerceAtMost(effectiveBuffer)
    }

    fun combinedTarget(targetFrames: Int, nativeWriteLimit: Int): Int {
        require(targetFrames in 960..38400 && nativeWriteLimit in 1..MAXIMUM_NATIVE_FRAMES)
        return maxOf(targetFrames, nativeWriteLimit)
    }
}
