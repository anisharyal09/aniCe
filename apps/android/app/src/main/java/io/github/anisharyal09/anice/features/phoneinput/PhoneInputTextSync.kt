// SPDX-License-Identifier: GPL-3.0-or-later
// Reconciles committed editor snapshots with the Mac's append-at-cursor text stream.
package io.github.anisharyal09.anice.features.phoneinput

import android.icu.text.BreakIterator
import java.nio.CharBuffer
import java.nio.charset.CodingErrorAction
import java.util.Locale

sealed interface PhoneInputTextAction {
    data class Commit(val value: String) : PhoneInputTextAction
    data class Backspace(val count: Int) : PhoneInputTextAction
    data class MoveCursor(val delta: Int) : PhoneInputTextAction
}

class PhoneInputTextPlan internal constructor(val actions: List<PhoneInputTextAction>)

sealed interface PhoneInputTextResult {
    data class Ready(val plan: PhoneInputTextPlan) : PhoneInputTextResult
    data object Unchanged : PhoneInputTextResult
    data object TooLarge : PhoneInputTextResult
    data object InvalidUnicode : PhoneInputTextResult
    data object CorrectionTooLarge : PhoneInputTextResult
    data object GraphemeTooLarge : PhoneInputTextResult
}

fun interface PhoneInputGraphemeSegmenter {
    /** UTF-16 offsets including zero and the string length. */
    fun boundaries(value: String): List<Int>
}

/** Uses Android ICU so emoji sequences, combining marks and joined scripts stay intact. */
class AndroidPhoneInputGraphemes : PhoneInputGraphemeSegmenter {
    override fun boundaries(value: String): List<Int> {
        val iterator = BreakIterator.getCharacterInstance(Locale.ROOT)
        iterator.setText(value)
        val result = ArrayList<Int>(value.length + 1)
        var boundary = iterator.first()
        while (boundary != BreakIterator.DONE) {
            result += boundary
            boundary = iterator.next()
        }
        return result
    }
}

/**
 * Android's editor keeps the IME's full working text locally. This reconciler emits only the
 * difference from the already-sent text, so autocorrect and range replacement become Mac
 * Backspaces followed by literal text instead of duplicate append-only commits.
 */
class PhoneInputTextSync(
    private val segmenter: PhoneInputGraphemeSegmenter = AndroidPhoneInputGraphemes(),
) {
    private var sentText = ""
    private var sentCaret = 0

    fun reset() {
        sentText = ""
        sentCaret = 0
    }

    /** Chunks commits to the receiver's negotiated per-record text limit. */
    fun plan(nextText: String, maxCommitBytes: Int = MAX_COMMIT_BYTES): PhoneInputTextResult {
        require(maxCommitBytes in 1..MAX_COMMIT_BYTES)
        if (nextText == sentText) return PhoneInputTextResult.Unchanged
        if (nextText.length > MAX_EDITOR_BYTES) return PhoneInputTextResult.TooLarge
        val encodedSize = encodedUtf8(nextText)?.size ?: return PhoneInputTextResult.InvalidUnicode
        if (encodedSize > MAX_EDITOR_BYTES) return PhoneInputTextResult.TooLarge

        val oldBoundaries = segmenter.boundaries(sentText)
        val newBoundaries = segmenter.boundaries(nextText)
        if (!validBoundaries(sentText, oldBoundaries) || !validBoundaries(nextText, newBoundaries)) {
            return PhoneInputTextResult.InvalidUnicode
        }

        val oldCount = oldBoundaries.size - 1
        val newCount = newBoundaries.size - 1
        fun oldCluster(index: Int) = sentText.substring(oldBoundaries[index], oldBoundaries[index + 1])
        fun newCluster(index: Int) = nextText.substring(newBoundaries[index], newBoundaries[index + 1])

        var commonPrefix = 0
        while (commonPrefix < oldCount && commonPrefix < newCount &&
            oldCluster(commonPrefix) == newCluster(commonPrefix)
        ) {
            commonPrefix++
        }

        val maxSuffix = minOf(oldCount - commonPrefix, newCount - commonPrefix)
        var commonSuffix = 0
        while (commonSuffix < maxSuffix &&
            oldCluster(oldCount - 1 - commonSuffix) == newCluster(newCount - 1 - commonSuffix)
        ) {
            commonSuffix++
        }

        // Preserve edits directly at sentCaret when repeated clusters make prefix/suffix placement ambiguous.
        if (sentCaret in 0..oldCount) {
            val suffixLen = oldCount - sentCaret
            if (suffixLen > commonSuffix && newCount >= suffixLen &&
                (0 until suffixLen).all { i -> oldCluster(oldCount - 1 - i) == newCluster(newCount - 1 - i) }
            ) {
                val maxPrefixAtCaret = minOf(sentCaret, newCount - suffixLen)
                var prefixAtCaret = 0
                while (prefixAtCaret < maxPrefixAtCaret && oldCluster(prefixAtCaret) == newCluster(prefixAtCaret)) {
                    prefixAtCaret++
                }
                commonPrefix = prefixAtCaret
                commonSuffix = suffixLen
            }
        }

        val rewriteTailCount = oldCount - commonPrefix
        val useCursorNavigation = commonSuffix > 2 || sentCaret < oldCount || rewriteTailCount > MAX_CORRECTION_GRAPHEMES
        val effectiveSuffix = if (useCursorNavigation) commonSuffix else 0

        val editEndOld = oldCount - effectiveSuffix
        val cursorDelta = editEndOld - sentCaret
        val backspaces = editEndOld - commonPrefix
        if (backspaces > MAX_CORRECTION_GRAPHEMES || kotlin.math.abs(cursorDelta) > MAX_CORRECTION_GRAPHEMES) {
            return PhoneInputTextResult.CorrectionTooLarge
        }

        val insertStartByte = newBoundaries[commonPrefix]
        val insertEndIndex = newCount - effectiveSuffix
        val insertEndByte = newBoundaries[insertEndIndex]
        val insertSlice = nextText.substring(insertStartByte, insertEndByte)
        val insertBoundaries = newBoundaries.subList(commonPrefix, insertEndIndex + 1).map { it - insertStartByte }
        if (insertBoundaries.zipWithNext().any { (start, end) ->
                insertSlice.substring(start, end).toByteArray(Charsets.UTF_8).size > maxCommitBytes
            }) return PhoneInputTextResult.GraphemeTooLarge

        val actions = buildList {
            if (cursorDelta != 0) add(PhoneInputTextAction.MoveCursor(cursorDelta))
            if (backspaces > 0) add(PhoneInputTextAction.Backspace(backspaces))
            appendCommitChunks(insertSlice, insertBoundaries, maxCommitBytes, this)
        }
        val plan = PhoneInputTextPlan(actions)
        sentText = nextText
        sentCaret = insertEndIndex
        return if (actions.isEmpty()) PhoneInputTextResult.Unchanged else PhoneInputTextResult.Ready(plan)
    }

    private fun appendCommitChunks(
        suffix: String,
        suffixBoundaries: List<Int>,
        maxCommitBytes: Int,
        actions: MutableList<PhoneInputTextAction>,
    ) {
        if (suffix.isEmpty()) return
        var chunkStart = suffixBoundaries.first()
        var chunkBytes = 0
        for (index in 0 until suffixBoundaries.lastIndex) {
            val start = suffixBoundaries[index]
            val end = suffixBoundaries[index + 1]
            val cluster = suffix.substring(start, end)
            val bytes = cluster.toByteArray(Charsets.UTF_8).size
            require(bytes in 1..maxCommitBytes) { "Phone input grapheme exceeds the negotiated limit" }
            if (chunkBytes + bytes > maxCommitBytes) {
                actions += PhoneInputTextAction.Commit(suffix.substring(chunkStart, start))
                chunkStart = start
                chunkBytes = 0
            }
            chunkBytes += bytes
        }
        if (chunkBytes > 0) actions += PhoneInputTextAction.Commit(suffix.substring(chunkStart))
    }

    private fun validBoundaries(value: String, boundaries: List<Int>): Boolean =
        boundaries.isNotEmpty() && boundaries.first() == 0 && boundaries.last() == value.length &&
            (value.isEmpty() || boundaries.size >= 2) &&
            boundaries.zipWithNext().all { (start, end) -> start < end }

    private fun encodedUtf8(value: String): ByteArray? = try {
        val encoded = Charsets.UTF_8.newEncoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
            .encode(CharBuffer.wrap(value))
        ByteArray(encoded.remaining()).also(encoded::get)
    } catch (_: java.nio.charset.CharacterCodingException) {
        null
    }

    companion object {
        const val MAX_COMMIT_BYTES = 1024
        const val MAX_EDITOR_BYTES = 65_536
        const val MAX_CORRECTION_GRAPHEMES = 256

        /** Returns null while the IME is editing a composing range; only committed snapshots travel. */
        fun committedSnapshot(value: String, composingStart: Int, composingEnd: Int): String? =
            if (composingStart >= 0 && composingEnd >= composingStart && composingEnd <= value.length)
                null
            else value
    }
}
