package de.tobwil.vetmed.ui

import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextLinkStyles
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.withLink
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import de.tobwil.vetmed.core.ChatMarkdown
import de.tobwil.vetmed.core.InlineSpan
import de.tobwil.vetmed.core.MarkdownBlock

/** Native rendering of the safe Markdown subset: no web view, no remote images, only http(s) links. */
@Composable
fun MarkdownText(text: String, modifier: Modifier = Modifier) {
    val blocks = remember(text) { ChatMarkdown.blocks(text) }
    val link = LocalVetColors.current.primary
    SelectionContainer(modifier) {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            blocks.forEach { block ->
                when (block) {
                    is MarkdownBlock.Heading -> Text(
                        annotated(block.spans, link), fontWeight = FontWeight.Bold,
                        style = if (block.level <= 2) MaterialTheme.typography.titleMedium else MaterialTheme.typography.titleSmall,
                        modifier = Modifier.padding(top = 4.dp),
                    )
                    is MarkdownBlock.Paragraph -> Text(annotated(block.spans, link), style = MaterialTheme.typography.bodyLarge)
                    is MarkdownBlock.ListItem -> Row(Modifier.padding(start = (block.indent * 12).dp)) {
                        Text(block.marker, style = MaterialTheme.typography.bodyLarge, modifier = Modifier.width(22.dp))
                        Text(annotated(block.spans, link), style = MaterialTheme.typography.bodyLarge, modifier = Modifier.weight(1f))
                    }
                    is MarkdownBlock.Quote -> Row(Modifier.height(IntrinsicSize.Min)) {
                        Box(Modifier.width(3.dp).fillMaxHeight().clip(CircleShape).background(link.copy(alpha = 0.5f)))
                        Text(annotated(block.spans, link), color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(start = 10.dp))
                    }
                    is MarkdownBlock.Code -> Box(
                        Modifier.fillMaxWidth().clip(RoundedCornerShape(10.dp)).background(MaterialTheme.colorScheme.onSurface.copy(alpha = 0.06f))
                            .horizontalScroll(rememberScrollState()).padding(12.dp),
                    ) { Text(block.text, fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodySmall) }
                    MarkdownBlock.Divider -> HorizontalDivider()
                }
            }
        }
    }
}

private fun annotated(spans: List<InlineSpan>, link: androidx.compose.ui.graphics.Color): AnnotatedString = buildAnnotatedString {
    spans.forEach { span ->
        val style = SpanStyle(
            fontWeight = if (span.bold) FontWeight.Bold else null,
            fontStyle = if (span.italic) FontStyle.Italic else null,
            fontFamily = if (span.code) FontFamily.Monospace else null,
            background = if (span.code) link.copy(alpha = 0.10f) else androidx.compose.ui.graphics.Color.Unspecified,
        )
        val url = span.link
        if (url != null) withLink(LinkAnnotation.Url(url, TextLinkStyles(SpanStyle(color = link, textDecoration = TextDecoration.Underline)))) { withStyle(style) { append(span.text) } }
        else withStyle(style) { append(span.text) }
    }
}

/** Three bouncing dots while an answer is on its way. */
@Composable
fun TypingIndicator() {
    val colors = LocalVetColors.current
    val transition = rememberInfiniteTransition(label = "typing")
    Row(horizontalArrangement = Arrangement.spacedBy(5.dp)) {
        repeat(3) { index ->
            val phase by transition.animateFloat(0f, 1f, infiniteRepeatable(tween(550, delayMillis = index * 180), RepeatMode.Reverse), label = "dot$index")
            Box(
                Modifier.size(7.dp).graphicsLayer { scaleX = 0.55f + 0.45f * phase; scaleY = scaleX; alpha = 0.35f + 0.65f * phase; translationY = (1f - phase) * 4f }
                    .clip(CircleShape).background(colors.primary),
            )
        }
    }
}
