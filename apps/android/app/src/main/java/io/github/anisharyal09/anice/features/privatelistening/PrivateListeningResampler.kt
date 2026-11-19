// SPDX-License-Identifier: GPL-3.0-or-later
// Fractionally resamples stereo PCM with shared channel phase and bounded backlog-driven clock correction.
package io.github.anisharyal09.anice.features.privatelistening

import kotlin.math.roundToInt

internal class PrivateListeningResampler {
    private val input = FloatArray((960 + 4) * 2)
    private var frames = 0
    private var phase = 1.0
    private var initialized = false
    private var filteredFrames = 9600.0
    private var integral = 0.0
    var ratio = 1.0
        private set
    val bufferedFrames: Int get() = frames

    fun reset(targetFrames: Int = 9600) {
        require(targetFrames > 0)
        frames = 0
        phase = 1.0
        initialized = false
        filteredFrames = targetFrames.toDouble()
        integral = 0.0
        ratio = 1.0
    }

    fun correct(queuedFrames: Int, targetFrames: Int = 9600) {
        require(queuedFrames >= 0 && targetFrames > 0)
        filteredFrames += (queuedFrames - filteredFrames) * 0.002
        val error = (filteredFrames - targetFrames) / 48000.0
        integral = (integral + error * 0.000002).coerceIn(-0.001, 0.001)
        val requested = (1.0 + error * 0.015 + integral).coerceIn(0.997, 1.003)
        ratio += (requested - ratio).coerceIn(-0.000002, 0.000002)
    }

    /** Returns bytes written into caller-owned scratch; history/phase survive every normal packet boundary. */
    fun process(pcm: ByteArray, output: ByteArray): Int {
        require(pcm.size == 3840 && output.size >= 4000)
        if (!initialized) {
            // Duplicate the first sample only at a new timeline boundary to supply cubic left history.
            input[0] = sample(pcm, 0)
            input[1] = sample(pcm, 2)
            frames = 1
            initialized = true
        }
        for (frame in 0 until 960) {
            input[(frames + frame) * 2] = sample(pcm, frame * 4)
            input[(frames + frame) * 2 + 1] = sample(pcm, frame * 4 + 2)
        }
        frames += 960
        var bytes = 0
        while (phase.toInt() + 2 < frames) {
            val index = phase.toInt()
            val fraction = (phase - index).toFloat()
            for (channel in 0..1) {
                val a = input[(index - 1) * 2 + channel]
                val b = input[index * 2 + channel]
                val c = input[(index + 1) * 2 + channel]
                val d = input[(index + 2) * 2 + channel]
                val value = (b + 0.5f * fraction * (c - a + fraction *
                    (2f * a - 5f * b + 4f * c - d + fraction * (3f * (b - c) + d - a))))
                    .roundToInt().coerceIn(-32768, 32767)
                output[bytes++] = value.toByte()
                output[bytes++] = (value shr 8).toByte()
            }
            phase += ratio
        }
        val consumed = phase.toInt() - 1
        val remaining = frames - consumed
        System.arraycopy(input, consumed * 2, input, 0, remaining * 2)
        frames = remaining
        phase -= consumed
        return bytes
    }

    private fun sample(bytes: ByteArray, offset: Int): Float =
        (((bytes[offset].toInt() and 255) or (bytes[offset + 1].toInt() shl 8)).toShort()).toFloat()
}
