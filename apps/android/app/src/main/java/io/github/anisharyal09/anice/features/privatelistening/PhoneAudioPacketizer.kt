// SPDX-License-Identifier: GPL-3.0-or-later
// Combines bounded partial PCM reads into fixed packets without persistence or unbounded backlog.
package io.github.anisharyal09.anice.features.privatelistening

internal class PhoneAudioPacketizer {
    private val partial = ByteArray(3840)
    private var count = 0
    private var sequence = 0L
    var discardedPartialBytes = 0
        private set
    var emittedPackets = 0L
        private set

    fun accept(bytes: ByteArray, length: Int, emit: (Long, ByteArray) -> Unit) {
        require(length in 0..bytes.size && length <= 15360 && length % 4 == 0)
        var offset = 0
        while (offset < length) {
            val copied = minOf(3840 - count, length - offset)
            bytes.copyInto(partial, count, offset, offset + copied)
            offset += copied
            count += copied
            if (count == 3840) {
                check(sequence < PrivateListeningMessage.MAX_SEQUENCE)
                sequence++
                count = 0
                emittedPackets++
                emit(sequence, partial.copyOf())
            }
        }
    }

    fun discardPartial() {
        discardedPartialBytes += count
        partial.fill(0)
        count = 0
    }
}
