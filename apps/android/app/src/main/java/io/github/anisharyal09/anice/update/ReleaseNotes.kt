// SPDX-License-Identifier: GPL-3.0-or-later
// Renders bounded release-note headings, lists and inline Markdown without interpreting HTML.
package io.github.anisharyal09.anice.update

import androidx.compose.foundation.layout.*
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
)

internal object ReleaseNotes {
    private val source = Regex("""<!--\s*anice-source:[\s\S]*?(?:-->|$)""")
    private val heading = Regex("""^(#{1,6})\s+(.+?)(?:\s+#+)?$""")
    private val bullet = Regex("""^(\s*)([-*+]|\d+[.)])\s+(.+)$""")
    private val inline = Regex("""\*\*([^\n]+?)\*\*|__([^\n]+?)__|`([^`\n]+)`|\[([^\[\]\n]+)]\((https://[^\s)]+)\)""")

    fun blocks(raw: String): List<ReleaseNoteBlock> {
        val clean = source.replace(raw.take(32_768), "").replace("\r\n", "\n").replace('\r', '\n')
        val result = mutableListOf<ReleaseNoteBlock>()
        val paragraph = mutableListOf<String>()
        var fence: String? = null
        fun flush(literal: Boolean = false) {
            if (paragraph.isNotEmpty()) {
                result.add(ReleaseNoteBlock(paragraph.joinToString("\n"), literal = literal))
                paragraph.clear()
            }
        }
        for (line in clean.lines()) {
            val trimmed = line.trim()
            val activeFence = fence
            if (activeFence != null) {
                paragraph.add(line)
                if (trimmed.startsWith(activeFence)) { flush(literal = true); fence = null }
                continue
            }
            if (trimmed.startsWith("```") || trimmed.startsWith("~~~")) {
                flush()
                fence = trimmed.take(3)
                paragraph.add(line)
                continue
            }
            val title = heading.matchEntire(line.trim())
            val item = bullet.matchEntire(line)
            when {
                line.isBlank() -> flush()
                title != null -> {
                    flush()
                    result.add(ReleaseNoteBlock(title.groupValues[2], heading = title.groupValues[1].length))
                }
                item != null -> {
                    flush()
                    val prefix = item.groupValues[2]
                    val indent = item.groupValues[1].replace("\t", "    ").length / 2
                    result.add(ReleaseNoteBlock(item.groupValues[3],
                        marker = if (prefix.first().isDigit()) prefix else "•", indent = indent.coerceAtMost(3)))
                }
                else -> paragraph.add(line)
            }
        }
        flush(literal = fence != null)
        return result.ifEmpty { listOf(ReleaseNoteBlock("No release notes provided.")) }
    }

    fun annotated(text: String, linkColor: Color): AnnotatedString = buildAnnotatedString {
        var end = 0
        for (match in inline.findAll(text)) {
            append(text.substring(end, match.range.first))
            val groups = match.groupValues
            when {
                groups[1].isNotEmpty() || groups[2].isNotEmpty() ->
                    withStyle(SpanStyle(fontWeight = FontWeight.SemiBold)) { append(groups[1].ifEmpty { groups[2] }) }
                groups[3].isNotEmpty() ->
                    withStyle(SpanStyle(fontFamily = FontFamily.Monospace)) { append(groups[3]) }
                else -> withLink(LinkAnnotation.Url(groups[5],
                    TextLinkStyles(style = SpanStyle(color = linkColor, textDecoration = TextDecoration.Underline)))) {
                    append(groups[4])
                }
            }
            end = match.range.last + 1
        }
        append(text.substring(end))
    }
}

@Composable
internal fun ReleaseNotesBody(notes: String) {
    val blocks = remember(notes) { ReleaseNotes.blocks(notes) }
    val linkColor = MaterialTheme.colorScheme.primary
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        for (block in blocks) {
            val content = remember(block, linkColor) {
                if (block.literal) AnnotatedString(block.text) else ReleaseNotes.annotated(block.text, linkColor)
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
                    Text(content, Modifier.weight(1f), style = style)
                }
            } else {
                Text(content, Modifier.fillMaxWidth().then(
                    if (block.heading > 0) Modifier.padding(top = 8.dp).semantics { heading() } else Modifier),
                    style = style)
            }
        }
    }
}
