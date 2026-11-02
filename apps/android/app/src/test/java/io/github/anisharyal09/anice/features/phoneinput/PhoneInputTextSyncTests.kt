// SPDX-License-Identifier: GPL-3.0-or-later
// Covers committed text diffs, IME composing ranges, Unicode boundaries and wire chunk limits.
package io.github.anisharyal09.anice.features.phoneinput

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PhoneInputTextSyncTests {
    private val sync get() = PhoneInputTextSync(testGraphemes)

    @Test fun committedEditsReconcileAutocorrectAsBackspacesAndReplacement() {
        val sender = sync
        val first = sender.plan("teh") as PhoneInputTextResult.Ready
        assertEquals(listOf(PhoneInputTextAction.Commit("teh")), first.plan.actions)

        val correction = sender.plan("the") as PhoneInputTextResult.Ready
        assertEquals(
            listOf(PhoneInputTextAction.Backspace(2), PhoneInputTextAction.Commit("he")),
            correction.plan.actions,
        )
        assertEquals(PhoneInputTextResult.Unchanged, sender.plan("the"))
    }

    @Test fun composingRangeIsHeldBackUntilTheImeCommitsIt() {
        assertNull(PhoneInputTextSync.committedSnapshot("prefixwordSuffix", 6, 10))
        assertEquals("complete", PhoneInputTextSync.committedSnapshot("complete", -1, -1))
        val sender = sync
        assertEquals(listOf(PhoneInputTextAction.Commit("teh")),
            (sender.plan("teh") as PhoneInputTextResult.Ready).plan.actions)
        assertNull(PhoneInputTextSync.committedSnapshot("the", 0, 3))
        assertEquals(PhoneInputTextResult.Unchanged, sender.plan("teh"))
        assertEquals(
            listOf(PhoneInputTextAction.Backspace(2), PhoneInputTextAction.Commit("he")),
            (sender.plan("the") as PhoneInputTextResult.Ready).plan.actions,
        )
    }

    @Test fun unicodeClustersAreNotSplitByCorrectionOrUtf8Chunking() {
        val emoji = "👩🏽‍💻"
        val sender = sync
        sender.plan(emoji + "x")
        assertEquals(
            listOf(PhoneInputTextAction.Backspace(1), PhoneInputTextAction.Commit("y")),
            (sender.plan(emoji + "y") as PhoneInputTextResult.Ready).plan.actions,
        )

        val large = sync.plan("é".repeat(600)) as PhoneInputTextResult.Ready
        val chunks = large.plan.actions.filterIsInstance<PhoneInputTextAction.Commit>().map { it.value }
        assertEquals(listOf(512, 88), chunks.map(String::length))
        assertTrue(chunks.all { it.toByteArray(Charsets.UTF_8).size <= PhoneInputTextSync.MAX_COMMIT_BYTES })
    }

    @Test fun chunksWithinTheMacAdvertisedLimitWithoutSplittingGraphemes() {
        val sender = sync
        val plan = sender.plan("abcdefg", maxCommitBytes = 3) as PhoneInputTextResult.Ready
        assertEquals(
            listOf(PhoneInputTextAction.Commit("abc"), PhoneInputTextAction.Commit("def"), PhoneInputTextAction.Commit("g")),
            plan.plan.actions,
        )
        assertEquals(PhoneInputTextResult.GraphemeTooLarge, sync.plan("👩🏽‍💻", maxCommitBytes = 4))
    }

    @Test fun rejectsUnboundedOrMalformedEditsWithoutChangingTheSentSnapshot() {
        val sender = sync
        assertEquals(PhoneInputTextResult.InvalidUnicode, sender.plan("\uD800"))
        assertEquals(PhoneInputTextResult.TooLarge, sender.plan("a".repeat(PhoneInputTextSync.MAX_EDITOR_BYTES + 1)))
        sender.plan("a".repeat(PhoneInputTextSync.MAX_CORRECTION_GRAPHEMES + 1))
        assertEquals(PhoneInputTextResult.CorrectionTooLarge, sender.plan(""))
    }

    private companion object {
        val testGraphemes = PhoneInputGraphemeSegmenter { value ->
            if (value.isEmpty()) return@PhoneInputGraphemeSegmenter listOf(0)
            val boundaries = mutableListOf(0)
            var index = 0
            var joinedNext = false
            while (index < value.length) {
                val codePoint = Character.codePointAt(value, index)
                val width = Character.charCount(codePoint)
                val extender = Character.getType(codePoint) in setOf(
                    Character.NON_SPACING_MARK.toInt(),
                    Character.COMBINING_SPACING_MARK.toInt(),
                    Character.ENCLOSING_MARK.toInt(),
                ) || codePoint in 0xFE00..0xFE0F || codePoint in 0x1F3FB..0x1F3FF
                if (index > 0 && !extender && !joinedNext && codePoint != 0x200D) boundaries += index
                joinedNext = codePoint == 0x200D
                index += width
            }
            boundaries += value.length
            boundaries
        }
    }
}
