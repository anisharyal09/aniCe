// SPDX-License-Identifier: GPL-3.0-or-later
// Checks display-only source cleanup, native Markdown spans and bounded plain-text fallbacks.
package io.github.anisharyal09.anice.update

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import org.junit.Assert.*
import org.junit.Test
import java.util.Locale

class ReleaseNotesTest {
    @Test fun headingsAndIndentedListsDoNotExposeTheSourceMarker() {
        val raw = "<!-- anice-source:abcdef -->\r\n\r\n# Release\r\n## Changes\r\n- **Fixed** downloads\r\n  * Nested item\r\n1. First step"
        val blocks = ReleaseNotes.blocks(raw)
        assertEquals(5, blocks.size)
        assertEquals(listOf(1, 2, 0, 0, 0), blocks.map { it.heading })
        assertEquals("Release", blocks[0].text)
        assertEquals("•", blocks[2].marker)
        assertEquals(1, blocks[3].indent)
        assertEquals("1.", blocks[4].marker)
        assertFalse(blocks.any { it.text.contains("anice-source") })
        assertTrue(raw.contains("anice-source"))
    }

    @Test fun inlineBoldAndHttpsLinksAreStyledButUnsafeSchemesAreNotInteractive() {
        val text = ReleaseNotes.annotated("A **bold title** and [release](https://github.com/anisharyal09/aniCe).", Color.Red)
        assertEquals("A bold title and release.", text.text)
        assertEquals(1, text.spanStyles.count { it.item.fontWeight == FontWeight.SemiBold })
        assertEquals(1, text.getLinkAnnotations(0, text.length).size)
        val unsafe = ReleaseNotes.annotated("[Bad](javascript:alert(1)) **unfinished", Color.Red)
        assertEquals("[Bad](javascript:alert(1)) **unfinished", unsafe.text)
        assertTrue(unsafe.getLinkAnnotations(0, unsafe.length).isEmpty())
    }

    @Test fun emptyTruncatedAndUnrecognizedNotesRemainBoundedAndReadable() {
        assertEquals("No release notes provided.", ReleaseNotes.blocks("<!-- anice-source:only -->").single().text)
        assertEquals("No release notes provided.", ReleaseNotes.blocks("<!-- anice-source:truncated").single().text)
        assertEquals("<b>Plain HTML</b>", ReleaseNotes.blocks("<b>Plain HTML</b>").single().text)
        assertEquals(32_768, ReleaseNotes.blocks("a".repeat(32_769)).single().text.length)
        assertEquals(3, ReleaseNotes.blocks(" ".repeat(100) + "- Deep item").single().indent)
    }

    @Test fun downloadCountersUseDecimalMegabytesAndNeverInventUnknownTotals() {
        val previous = Locale.getDefault()
        try {
            Locale.setDefault(Locale.US)
            assertEquals("Downloaded 1.5 MB of 3.0 MB", downloadSummary(1_500_000, 3_000_000))
            assertEquals("Downloaded 0.0 MB", downloadSummary(-1, null))
            assertEquals("Downloaded 1.5 MB", downloadSummary(1_500_000, 0))
        } finally {
            Locale.setDefault(previous)
        }
    }

    @Test fun fencedCodeFallsBackToLiteralTextWithoutLosingHeadingsOrCommands() {
        val raw = "```shell\n# not a heading\n- not a list\n**literal**\n```"
        val block = ReleaseNotes.blocks(raw).single()
        assertTrue(block.literal)
        assertEquals(raw, block.text)
        assertEquals(0, block.heading)
        assertNull(block.marker)
        assertTrue(ReleaseNotes.blocks("~~~\n# unfinished").single().literal)
    }

    @Test(timeout = 2000) fun malformedBracketRunsRemainFastPlainText() {
        val notes = "[".repeat(32_768)
        repeat(8) {
            val rendered = ReleaseNotes.annotated(notes, Color.Red)
            assertEquals(notes, rendered.text)
            assertTrue(rendered.getLinkAnnotations(0, rendered.length).isEmpty())
        }
    }

    @Test fun horizontalRulesAndDuplicateVersionHeadingAreNormalized() {
        val raw = "# aniCe v0.9.0-beta.2\n## What's changed\n---\n- **Fixed** rendering\n***\n___"
        val blocks = ReleaseNotes.blocks(raw, version = "v0.9.0-beta.2")
        assertEquals(5, blocks.size)
        assertEquals(2, blocks[0].heading)
        assertEquals("What's changed", blocks[0].text)
        assertTrue(blocks[1].divider)
        assertEquals("•", blocks[2].marker)
        assertTrue(blocks[3].divider)
        assertTrue(blocks[4].divider)
        assertEquals("No release notes provided.", ReleaseNotes.blocks("# aniCe v0.9.0-beta.2", version = "v0.9.0-beta.2").single().text)
    }

    @Test(timeout = 2000) fun blockLineAndInlineSpanCapsBoundAdversarialMarkdown() {
        val manyItems = (1..300).joinToString("\n") { "- Item $it" }
        val blockCapped = ReleaseNotes.blocks(manyItems)
        assertEquals(ReleaseNotes.MAX_BLOCKS, blockCapped.size)
        assertEquals("Release notes truncated. Open on GitHub for full notes.", blockCapped.last().text)

        val manyLines = (1..350).joinToString("\n") { "Line $it" }
        val lineCapped = ReleaseNotes.blocks(manyLines)
        assertTrue(lineCapped.size <= ReleaseNotes.MAX_BLOCKS)
        assertEquals("Release notes truncated. Open on GitHub for full notes.", lineCapped.last().text)

        val sourceFlood = "<!--" + " ".repeat(20_000) + "still visible"
        assertEquals(sourceFlood, ReleaseNotes.blocks(sourceFlood).single().text)

        val manySpans = (1..120).joinToString(" ") { "**Bold$it**" }
        val budget = intArrayOf(500)
        val rendered = ReleaseNotes.annotated(manySpans, Color.Red, budget)
        assertEquals(ReleaseNotes.MAX_INLINE_SPANS_PER_BLOCK, rendered.spanStyles.size)
        assertEquals(500 - ReleaseNotes.MAX_INLINE_SPANS_PER_BLOCK, budget[0])

        val unclosedStars = "**".repeat(4_000) + "tail"
        val plain = ReleaseNotes.annotated(unclosedStars, Color.Red)
        assertEquals(unclosedStars, plain.text)
    }
}
