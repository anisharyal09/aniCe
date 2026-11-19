// SPDX-License-Identifier: GPL-3.0-or-later
// Maps unsigned native playback-head progress through bounded resampled packet intervals to the source timeline.
package io.github.anisharyal09.anice.features.privatelistening

internal class PrivateListeningPlaybackClock {
    private data class Interval(val firstOutput: Long, val lastOutput: Long, val firstSource: Long)
    private val intervals = ArrayDeque<Interval>()
    private var previousHead = 0L
    private var headWrap = 0L
    var playedFrames = 0L
        private set
    var sourcePosition = 0L
        private set

    fun reset() {
        intervals.clear()
        previousHead = 0
        headWrap = 0
        playedFrames = 0
        sourcePosition = 0
    }

    fun submitted(outputEnd: Long, outputFrames: Int, sourceOffset: Long) {
        require(outputFrames in 1..1000 && outputEnd >= outputFrames && sourceOffset >= 0 &&
            sourceOffset <= Long.MAX_VALUE - 960)
        check(intervals.size < 64) { "Playback mapping exceeded the native audio budget" }
        intervals.addLast(Interval(outputEnd - outputFrames, outputEnd, sourceOffset))
        updateSource()
    }

    fun head(unsignedBits: Int): Long {
        val head = unsignedBits.toLong() and 0xffffffffL
        if (head < previousHead) headWrap += 1L shl 32
        previousHead = head
        playedFrames = headWrap + head
        updateSource()
        return playedFrames
    }

    private fun updateSource() {
        while (intervals.isNotEmpty() && playedFrames >= intervals.first().lastOutput) {
            sourcePosition = intervals.removeFirst().firstSource + 960
        }
        intervals.firstOrNull()?.let {
            if (playedFrames >= it.firstOutput) {
                sourcePosition = it.firstSource +
                    (playedFrames - it.firstOutput) * 960 / (it.lastOutput - it.firstOutput)
            }
        }
    }
}
