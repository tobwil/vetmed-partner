package de.tobwil.vetmed.core

/** One styled run of text. Links are only kept for http(s); nothing is fetched or executed. */
data class InlineSpan(val text: String, val bold: Boolean = false, val italic: Boolean = false, val code: Boolean = false, val link: String? = null)

sealed interface MarkdownBlock {
    data class Paragraph(val spans: List<InlineSpan>) : MarkdownBlock
    data class Heading(val level: Int, val spans: List<InlineSpan>) : MarkdownBlock
    data class ListItem(val marker: String, val indent: Int, val spans: List<InlineSpan>) : MarkdownBlock
    data class Quote(val spans: List<InlineSpan>) : MarkdownBlock
    data class Code(val text: String) : MarkdownBlock
    data object Divider : MarkdownBlock
}

/** Port of the iOS `ChatMarkdown`: native rendering of a safe Markdown subset and a readable plain-text export. */
object ChatMarkdown {
    private val heading = Regex("^#{1,6} +")
    private val listMarker = Regex("^(?:[-+*]|[0-9]{1,9}[.)]) +")

    fun blocks(text: String): List<MarkdownBlock> {
        val output = mutableListOf<MarkdownBlock>()
        val paragraph = mutableListOf<String>()
        val code = mutableListOf<String>()
        var fence: String? = null
        fun flush() { if (paragraph.isNotEmpty()) { output += MarkdownBlock.Paragraph(inline(paragraph.joinToString("\n"))); paragraph.clear() } }
        for (line in text.split("\r\n", "\n", "\r")) {
            val trimmed = line.trim(' ', '\t')
            val open = fence
            if (open != null) {
                if (trimmed.startsWith(open)) { output += MarkdownBlock.Code(code.joinToString("\n")); code.clear(); fence = null } else code += line
                continue
            }
            if (trimmed.startsWith("```") || trimmed.startsWith("~~~")) { flush(); fence = trimmed.take(3); continue }
            if (trimmed.isEmpty()) { flush(); continue }
            heading.find(trimmed)?.let { match ->
                flush(); output += MarkdownBlock.Heading(match.value.count { it == '#' }, inline(trimmed.substring(match.range.last + 1))); return@let
            }?.let { continue }
            if (trimmed == "---" || trimmed == "***" || trimmed == "___") { flush(); output += MarkdownBlock.Divider; continue }
            listMarker.find(trimmed)?.let { match ->
                flush()
                val marker = match.value.trim()
                val indent = minOf(6, line.takeWhile { it == ' ' || it == '\t' }.length / 2)
                output += MarkdownBlock.ListItem(if (marker in setOf("-", "+", "*")) "•" else marker, indent, inline(trimmed.substring(match.range.last + 1)))
            }?.let { continue }
            if (trimmed.startsWith("> ")) { flush(); output += MarkdownBlock.Quote(inline(trimmed.drop(2))); continue }
            paragraph += line
        }
        flush()
        if (fence != null) output += MarkdownBlock.Code(code.joinToString("\n"))
        return output
    }

    /** Bold, italic, inline code and http(s) links. Unmatched markers stay literal text. */
    fun inline(source: String): List<InlineSpan> {
        val spans = mutableListOf<InlineSpan>()
        val plain = StringBuilder()
        var bold = false; var italic = false
        fun emit(span: InlineSpan) { if (span.text.isNotEmpty()) spans += span }
        fun flushPlain() { emit(InlineSpan(plain.toString(), bold, italic)); plain.clear() }
        var i = 0
        while (i < source.length) {
            val c = source[i]
            when {
                c == '\\' && i + 1 < source.length && source[i + 1] in "\\`*_[]()#+-.!>" -> { plain.append(source[i + 1]); i += 2 }
                c == '`' -> {
                    val end = source.indexOf('`', i + 1)
                    if (end > i) { flushPlain(); emit(InlineSpan(source.substring(i + 1, end), bold, italic, code = true)); i = end + 1 } else { plain.append(c); i++ }
                }
                (c == '*' || c == '_') && source.startsWith("$c$c", i) && source.indexOf("$c$c", i + 2).let { it > i + 2 || bold } -> {
                    flushPlain(); bold = !bold; i += 2
                }
                (c == '*' || c == '_') && (italic || source.indexOf(c, i + 1) > i + 1) && !(c == '_' && i > 0 && source[i - 1].isLetterOrDigit()) -> {
                    flushPlain(); italic = !italic; i++
                }
                c == '[' -> {
                    val close = source.indexOf("](", i)
                    val end = if (close > i) source.indexOf(')', close + 2) else -1
                    if (close > i && end > close) {
                        val label = source.substring(i + 1, close); val target = source.substring(close + 2, end).trim()
                        flushPlain()
                        val safe = target.takeIf { it.startsWith("https://", true) || it.startsWith("http://", true) }
                        emit(InlineSpan(label, bold, italic, link = safe))
                        i = end + 1
                    } else { plain.append(c); i++ }
                }
                else -> { plain.append(c); i++ }
            }
        }
        flushPlain()
        return spans
    }

    fun plainText(source: String): String = blocks(source).joinToString("\n\n") { block ->
        when (block) {
            is MarkdownBlock.Paragraph -> plain(block.spans)
            is MarkdownBlock.Heading -> plain(block.spans)
            is MarkdownBlock.ListItem -> "  ".repeat(block.indent) + block.marker + " " + plain(block.spans)
            is MarkdownBlock.Quote -> "> " + plain(block.spans)
            is MarkdownBlock.Code -> block.text
            MarkdownBlock.Divider -> "—"
        }
    }

    private fun plain(spans: List<InlineSpan>) = spans.joinToString("") { span ->
        if (span.link != null && span.text != span.link) span.text + " (" + span.link + ")" else span.text
    }

    fun export(run: AnalysisRun): String {
        val status = if (run.status == AnalysisStatus.COMPLETED) "KI-Antwort · fachlich ungeprüft" else "UNVOLLSTÄNDIGE KI-Antwort · fachlich ungeprüft"
        return "VetMed · $status\n\n" + plainText(run.text)
    }
}
