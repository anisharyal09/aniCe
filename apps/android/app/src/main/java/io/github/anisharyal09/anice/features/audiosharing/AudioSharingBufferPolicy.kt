// SPDX-License-Identifier: GPL-3.0-or-later
// Tunes local buffering without changing wire format, headphone authorization or the hard audio budget.
package io.github.anisharyal09.anice.features.audiosharing

internal enum class ListeningBufferProfile(
    val preference: String,
    val initialFrames: Int,
    val minimumFrames: Int,
    val maximumFrames: Int,
) {
    BALANCED("balanced", 5760, 2880, 11520),
    LOWER_DELAY("lower_delay", 1920, 960, 7680);

    companion object {
        fun restored(value: String?): ListeningBufferProfile =
            entries.firstOrNull { it.preference == value } ?: BALANCED
    }
}

/** Arrival spacing is local jitter, not a synchronized source-to-headphone latency measurement. */
internal class AudioSharingBufferPolicy(
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
    private var learnedFloor = profile.minimumFrames
    private var recoveryUntil = 0L
    private var floorHealthySince: Long? = null

    @Synchronized fun arrived(sequence: Long, now: Long) {
        require(sequence > 0 && now >= 0)
        val previous = previousSequence
        val at = previousArrival
        if (previous != null && sequence <= previous) return
        if (previous != null && at != null && now >= at && now >= recoveryUntil) {
            val expected = (sequence - previous).toDouble() * 20
            val late = (now - at - expected).coerceIn(0.0, 1000.0)
            // React quickly to late bursts, but let old jitter fade rather than retaining a lifetime maximum.
            lateMillis += (late - lateMillis) * if (late > lateMillis) 0.25 else 0.02
            val jitterTarget = learnedFloor + (lateMillis * 2 * 48).toInt()
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
        // The growth cooldown limits target inflation, not healthy time.
        // Every starvation breaks a continuous recovery probe.
        floorHealthySince = null
        stableSince = null
        // One continuous starvation episode must not inflate the target every worker turn.
        if (lastIncrease?.let { now - it < 1000 } == true) return
        learnedFloor = maxOf(learnedFloor, targetFrames + 960).coerceAtMost(profile.maximumFrames)
        recoveryUntil = now + 1000 // Do not count catch-up spacing as new arrival jitter.
        increase(targetFrames + 1920, now)
    }

    @Synchronized fun healthy(now: Long) {
        require(now >= 0)
        if (floorHealthySince == null) floorHealthySince = now
        // Remember short-term underruns, but do not retain one transfer/radio burst
        // as a permanent latency floor. Reprobe only one packet after a long
        // uninterrupted healthy interval; a real underrun immediately relearns it.
        if (learnedFloor > profile.minimumFrames && now - requireNotNull(floorHealthySince) >= 120000) {
            learnedFloor = maxOf(profile.minimumFrames, learnedFloor - 960)
            floorHealthySince = now
        }
        val stable = stableSince
        if (stable == null) { stableSince = now; return }
        if (now - stable < 15000) return
        stableSince = now
        val jitterFloor = roundPacket(learnedFloor + (lateMillis * 2 * 48).toInt())
            .coerceAtMost(profile.maximumFrames)
        targetFrames = maxOf(jitterFloor, targetFrames - 960)
    }

    @Synchronized fun interrupted() {
        previousSequence = null
        previousArrival = null
        previousUnderruns = null
        stableSince = null
        floorHealthySince = null
        lateMillis = 0.0
    }

    @Synchronized fun buffering() { stableSince = null; floorHealthySince = null }

    private fun increase(frames: Int, now: Long) {
        targetFrames = roundPacket(frames).coerceIn(profile.minimumFrames, profile.maximumFrames)
        lastIncrease = now
        stableSince = null
        floorHealthySince = null
    }

    private fun roundPacket(frames: Int) = (frames + 959) / 960 * 960
}

/** Memory capacity is not a requirement to keep that much audio pending in AudioTrack. */
internal object AudioSharingNativeBufferPolicy {
    const val MAXIMUM_NATIVE_FRAMES = 37400 // Leaves one bounded resampler output under the 800-ms ceiling.
    fun requestedFrames(targetFrames: Int, profile: ListeningBufferProfile = ListeningBufferProfile.BALANCED): Int {
        require(targetFrames in 960..38400)
        val portion = if (profile == ListeningBufferProfile.BALANCED) targetFrames * 3 / 4 else targetFrames / 2
        return maxOf(960, portion).coerceAtMost(MAXIMUM_NATIVE_FRAMES)
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
