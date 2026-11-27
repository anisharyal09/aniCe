// SPDX-License-Identifier: GPL-3.0-or-later
// Renders bounded release-note headings, dividers, lists and inline Markdown without interpreting HTML.
package io.github.anisharyal09.anice.update

import androidx.compose.foundation.layout.*
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.*
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp

internal data class ReleaseNoteBlock(
    val text: String,
    val heading: Int = 0,
    val marker: String? = null,
    val indent: Int = 0,
    val literal: Boolean = false,
    val divider: Boolean = false,
)

internal object ReleaseNotes {
    const val MAX_RAW_CHARS = 32_768
    const val MAX_LINES = 256
    const val MAX_BLOCKS = 128
    const val MAX_INLINE_CHARS = 8_192
    const val MAX_INLINE_SPANS_PER_BLOCK = 64
    const val MAX_TOTAL_INLINE_SPANS = 256

    fun blocks(raw: String, version: String? = null): List<ReleaseNoteBlock> {
        val result = parse(raw).toMutableList()
        if (!version.isNullOrBlank()) {
            val first = result.firstOrNull()
            if (first != null && first.heading == 1 && first.text.contains(version, ignoreCase = true)) {
                result.removeAt(0)
            }
        }
        return result.ifEmpty { listOf(ReleaseNoteBlock("No release notes provided.")) }
    }

    private fun stripSourceMarkers(raw: String): String {
        val output = StringBuilder(raw.length)
        var cursor = 0
        while (cursor < raw.length) {
            val open = raw.indexOf("<!--", cursor)
            if (open < 0) {
                output.append(raw, cursor, raw.length)
                break
            }
            output.append(raw, cursor, open)
            var scan = open + 4
            while (scan < raw.length && raw[scan].isWhitespace()) scan++
            if (raw.startsWith("anice-source:", scan)) {
                val close = raw.indexOf("-->", scan + "anice-source:".length)
                if (close < 0) break
                cursor = close + 3
            } else {
                output.append("<!--")
                cursor = open + 4
            }
        }
        return output.toString()
    }

    private fun isHorizontalRule(line: String): Boolean {
        var index = 0
        var leading = 0
        while (index < line.length && line[index] == ' ' && leading < 3) {
            leading++
            index++
        }
        if (index >= line.length) return false
        val marker = line[index]
        if (marker != '-' && marker != '*' && marker != '_') return false
        var count = 0
        while (index < line.length) {
            when (line[index]) {
                marker -> count++
                ' ' -> Unit
                else -> return false
            }
            index++
        }
        return count >= 3
    }

    private fun parseHeading(trimmed: String): Pair<Int, String>? {
        var level = 0
        while (level < trimmed.length && trimmed[level] == '#') {
            level++
            if (level > 6) return null
        }
        if (level !in 1..6 || level >= trimmed.length || !trimmed[level].isWhitespace()) return null
        var start = level
        while (start < trimmed.length && trimmed[start].isWhitespace()) start++
        var text = trimmed.substring(start).trim()
        if (text.isEmpty()) return null
        if (text.last() == '#') {
            var cut = text.length
            while (cut > 0 && text[cut - 1] == '#') cut--
            if (cut > 0 && text[cut - 1].isWhitespace()) {
                val stripped = text.substring(0, cut).trim()
                if (stripped.isNotEmpty()) text = stripped
            }
        }
        return level to text
    }

    private fun parseListItem(line: String): Triple<String, Int, String>? {
        var index = 0
        var spaces = 0
        while (index < line.length && (line[index] == ' ' || line[index] == '\t')) {
            spaces += if (line[index] == '\t') 4 else 1
            index++
        }
        if (index >= line.length) return null
        val marker: String
        val afterMarker: Int
        val first = line[index]
        if (first == '-' || first == '*' || first == '+') {
            marker = "•"
            afterMarker = index + 1
        } else if (first.isDigit()) {
            var end = index
            while (end < line.length && line[end].isDigit()) end++
            if (end >= line.length || (line[end] != '.' && line[end] != ')')) return null
            afterMarker = end + 1
            marker = line.substring(index, afterMarker)
        } else {
            return null
        }
        if (afterMarker >= line.length || (line[afterMarker] != ' ' && line[afterMarker] != '\t')) return null
        var bodyStart = afterMarker
        while (bodyStart < line.length && (line[bodyStart] == ' ' || line[bodyStart] == '\t')) bodyStart++
        if (bodyStart >= line.length) return null
        return Triple(marker, (spaces / 2).coerceAtMost(3), line.substring(bodyStart))
    }

    private fun parse(raw: String): List<ReleaseNoteBlock> {
        val clean = stripSourceMarkers(raw.take(MAX_RAW_CHARS)).replace("\r\n", "\n").replace('\r', '\n')
        val result = mutableListOf<ReleaseNoteBlock>()
        val paragraph = mutableListOf<String>()
        var fence: String? = null
        var truncated = false

        fun appendBlock(block: ReleaseNoteBlock): Boolean {
            if (result.size >= MAX_BLOCKS - 1) {
                if (result.size == MAX_BLOCKS - 1) {
                    result.add(block)
                    return true
                }
                truncated = true
                return false
            }
            result.add(block)
            return true
        }

        fun flush(literal: Boolean = false): Boolean {
            if (paragraph.isEmpty()) return true
            val block = ReleaseNoteBlock(paragraph.joinToString("\n"), literal = literal)
            paragraph.clear()
            return appendBlock(block)
        }

        val lines = clean.lines()
        for ((lineNumber, line) in lines.withIndex()) {
            if (lineNumber >= MAX_LINES) {
                if (line.isNotBlank() || paragraph.isNotEmpty()) truncated = true
                break
            }
            val trimmed = line.trim()
            val activeFence = fence
            if (activeFence != null) {
                paragraph.add(line)
                if (trimmed.startsWith(activeFence)) {
                    fence = null
                    if (!flush(literal = true)) break
                }
                continue
            }
            if (trimmed.startsWith("```") || trimmed.startsWith("~~~")) {
                if (!flush()) break
                fence = trimmed.take(3)
                paragraph.add(line)
                continue
            }
            if (line.isBlank()) {
                if (!flush()) break
                continue
            }
            val headingMatch = parseHeading(trimmed)
            val listMatch = parseListItem(line)
            when {
                isHorizontalRule(line) -> {
                    if (!flush()) break
                    if (!appendBlock(ReleaseNoteBlock("", divider = true))) break
                }
                headingMatch != null -> {
                    if (!flush()) break
                    if (!appendBlock(ReleaseNoteBlock(headingMatch.second, heading = headingMatch.first))) break
                }
                listMatch != null -> {
                    if (!flush()) break
                    if (!appendBlock(ReleaseNoteBlock(listMatch.third, marker = listMatch.first, indent = listMatch.second))) break
                }
                else -> {
                    if (result.size >= MAX_BLOCKS) {
                        truncated = true
                        break
                    }
                    paragraph.add(line)
                }
            }
        }
        if (paragraph.isNotEmpty()) flush(literal = fence != null)
        if (truncated) {
            if (result.size >= MAX_BLOCKS) result.removeAt(result.lastIndex)
            result.add(ReleaseNoteBlock("Release notes truncated. Open on GitHub for full notes."))
        }
        return result
    }

    fun annotated(text: String, linkColor: Color): AnnotatedString =
        annotated(text, linkColor, intArrayOf(MAX_INLINE_SPANS_PER_BLOCK))

    internal fun annotated(text: String, linkColor: Color, remainingSpans: IntArray): AnnotatedString {
        val budget = remainingSpans[0].coerceAtMost(MAX_INLINE_SPANS_PER_BLOCK)
        if (text.isEmpty() || budget <= 0) return AnnotatedString(text)
        val limit = minOf(text.length, MAX_INLINE_CHARS)
        var spansUsed = 0
        var noBoldBefore = -1
        var noUnderlineBefore = -1
        var noCodeBefore = -1
        fun lineEndFrom(pos: Int): Int {
            val nl = text.indexOf('\n', pos)
            return if (nl in 0 until limit) nl else limit
        }
        return buildAnnotatedString {
            var plainStart = 0
            var i = 0
            while (i < limit && spansUsed < budget) {
                val ch = text[i]
                if ((ch == '*' && i + 1 < limit && text[i + 1] == '*') ||
                    (ch == '_' && i + 1 < limit && text[i + 1] == '_')) {
                    val isBoldStar = ch == '*'
                    val noMatchLimit = if (isBoldStar) noBoldBefore else noUnderlineBefore
                    if (i < noMatchLimit) { i++; continue }
                    val lineEnd = lineEndFrom(i + 2)
                    val delim = if (isBoldStar) "**" else "__"
                    val close = text.indexOf(delim, i + 2)
                    if (close in (i + 3) until lineEnd) {
                        append(text, plainStart, i)
                        withStyle(SpanStyle(fontWeight = FontWeight.SemiBold)) {
                            append(text, i + 2, close)
                        }
                        i = close + 2
                        plainStart = i
                        spansUsed++
                        continue
                    } else if (close !in (i + 2) until lineEnd) {
                        if (isBoldStar) noBoldBefore = lineEnd else noUnderlineBefore = lineEnd
                    }
                    i += 2
                    continue
                }
                if (ch == '`') {
                    if (i < noCodeBefore) { i++; continue }
                    val lineEnd = lineEndFrom(i + 1)
                    val close = text.indexOf('`', i + 1)
                    if (close in (i + 2) until lineEnd) {
                        append(text, plainStart, i)
                        withStyle(SpanStyle(fontFamily = FontFamily.Monospace)) {
                            append(text, i + 1, close)
                        }
                        i = close + 1
                        plainStart = i
                        spansUsed++
                        continue
                    } else if (close !in (i + 1) until lineEnd) {
                        noCodeBefore = lineEnd
                    }
                    i++
                    continue
                }
                if (ch == '[') {
                    var scan = i + 1
                    var nestedOpen = -1
                    var closeBracket = -1
                    while (scan < limit) {
                        val c = text[scan]
                        if (c == '\n') break
                        if (c == '[') { nestedOpen = scan; break }
                        if (c == ']') { closeBracket = scan; break }
                        scan++
                    }
                    if (nestedOpen >= 0) {
                        i = nestedOpen
                        continue
                    }
                    if (closeBracket > i + 1 && closeBracket + 1 < limit && text[closeBracket + 1] == '(') {
                        var urlEnd = closeBracket + 2
                        while (urlEnd < limit) {
                            val c = text[urlEnd]
                            if (c == ')' || c.isWhitespace()) break
                            urlEnd++
                        }
                        if (urlEnd > closeBracket + 2 && urlEnd < limit && text[urlEnd] == ')') {
                            val url = text.substring(closeBracket + 2, urlEnd)
                            if (url.startsWith("https://")) {
                                append(text, plainStart, i)
                                withLink(LinkAnnotation.Url(url,
                                    TextLinkStyles(style = SpanStyle(color = linkColor, textDecoration = TextDecoration.Underline)))) {
                                    append(text, i + 1, closeBracket)
                                }
                                i = urlEnd + 1
                                plainStart = i
                                spansUsed++
                                continue
                            }
                        }
                    }
                    i++
                    continue
                }
                i++
            }
            if (plainStart < text.length) append(text, plainStart, text.length)
            remainingSpans[0] = (remainingSpans[0] - spansUsed).coerceAtLeast(0)
        }
    }
}

private data class RenderedReleaseNoteBlock(
    val block: ReleaseNoteBlock,
    val content: AnnotatedString,
)

@Composable
internal fun ReleaseNotesBody(notes: String, version: String? = null) {
    val linkColor = MaterialTheme.colorScheme.primary
    val rendered = remember(notes, version, linkColor) {
        val remainingSpans = intArrayOf(ReleaseNotes.MAX_TOTAL_INLINE_SPANS)
        ReleaseNotes.blocks(notes, version).map { block ->
            val content = if (block.divider || block.literal) {
                AnnotatedString(block.text)
            } else {
                ReleaseNotes.annotated(block.text, linkColor, remainingSpans)
            }
            RenderedReleaseNoteBlock(block, content)
        }
    }
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        for (item in rendered) {
            val block = item.block
            if (block.divider) {
                HorizontalDivider(Modifier.padding(vertical = 4.dp), color = MaterialTheme.colorScheme.outlineVariant)
                continue
            }
            val style = when (block.heading) {
                1 -> MaterialTheme.typography.titleLarge
                2 -> MaterialTheme.typography.titleMedium
                in 3..6 -> MaterialTheme.typography.titleSmall
                else -> MaterialTheme.typography.bodyMedium
            }
            if (block.marker != null) {
                Row(Modifier.fillMaxWidth().padding(start = (block.indent * 16).dp),
                    verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(block.marker, Modifier.widthIn(min = 12.dp), style = style)
                    Text(item.content, Modifier.weight(1f), style = style)
                }
            } else {
                Text(item.content, Modifier.fillMaxWidth().then(
                    if (block.heading > 0) Modifier.padding(top = 8.dp).semantics { heading() } else Modifier),
                    style = style)
            }
        }
    }
}
