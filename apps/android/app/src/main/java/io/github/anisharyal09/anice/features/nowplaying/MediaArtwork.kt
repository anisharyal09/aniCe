// SPDX-License-Identifier: GPL-3.0-or-later
// Assembles one revision-bound thumbnail with sequential chunks and a fixed monotonic deadline.
package io.github.anisharyal09.anice.features.nowplaying

import java.security.MessageDigest

internal class MediaArtwork {
    private var buffer: ByteArray?=null
    private var digest=byteArrayOf()
    private var received=0
    private var deadline=0L
    fun reset() { buffer=null;digest=byteArrayOf();received=0;deadline=0 }
    fun expire(now: Long) { if(deadline!=0L && now>=deadline) { buffer=null;received=0 } }
    fun accept(hash: ByteArray, total: Int, offset: Int, chunk: ByteArray, now: Long): ByteArray? {
        expire(now)
        if(hash.size!=32 || total !in 1..65536 || chunk.size !in 1..2048 || offset<0 || offset.toLong()+chunk.size>total) { buffer=null;return null }
        if(buffer==null) {
            if(offset!=0 || digest.contentEquals(hash)) return null
            buffer=ByteArray(total);digest=hash.copyOf();received=0;deadline=now+10000
        }
        val bytes=buffer ?: return null
        if(total!=bytes.size || offset!=received || !digest.contentEquals(hash)) { buffer=null;return null }
        chunk.copyInto(bytes,offset);received+=chunk.size
        if(received!=total) return null
        buffer=null
        return bytes.takeIf { MessageDigest.getInstance("SHA-256").digest(it).contentEquals(hash) }
    }
}
