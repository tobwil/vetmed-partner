package de.tobwil.vetmed.data

import android.graphics.Typeface
import android.graphics.pdf.PdfDocument
import android.text.Layout
import android.text.StaticLayout
import android.text.TextPaint
import de.tobwil.vetmed.core.AppFailure
import de.tobwil.vetmed.core.ReportVersion
import java.io.File
import java.io.IOException

/**
 * PDF export like iOS: A4 pages, the draft marking stays on the first line, every line of the report is kept.
 * Files live in the cache and are removed after 24 hours or when their case is deleted; a receiving app may
 * still be reading shortly after sharing.
 */
class ReportExports(private val directory: File) {
    companion object {
        private const val PAGE_WIDTH = 595
        private const val PAGE_HEIGHT = 842
        private const val MARGIN = 50
        const val MAX_AGE_MILLIS = 24L * 60 * 60 * 1000
    }

    fun file(reportID: String) = File(directory, "Bericht-$reportID.pdf")

    fun pdf(report: ReportVersion): File {
        cleanExpired()
        directory.mkdirs()
        val target = file(report.id)
        val paint = TextPaint(TextPaint.ANTI_ALIAS_FLAG).apply { textSize = 11f; typeface = Typeface.DEFAULT }
        val width = PAGE_WIDTH - 2 * MARGIN
        val layout = StaticLayout.Builder.obtain(report.exportText, 0, report.exportText.length, paint, width)
            .setAlignment(Layout.Alignment.ALIGN_NORMAL).setLineSpacing(4f, 1f).setIncludePad(false).build()
        val document = PdfDocument()
        try {
            val pages = paginate(IntArray(layout.lineCount) { layout.getLineTop(it) }, IntArray(layout.lineCount) { layout.getLineBottom(it) }, PAGE_HEIGHT - 2 * MARGIN)
            pages.forEachIndexed { index, lines ->
                val top = layout.getLineTop(lines.first)
                val bottom = layout.getLineBottom(lines.last)
                val page = document.startPage(PdfDocument.PageInfo.Builder(PAGE_WIDTH, PAGE_HEIGHT, index + 1).create())
                page.canvas.save()
                page.canvas.clipRect(MARGIN, MARGIN, PAGE_WIDTH - MARGIN, MARGIN + (bottom - top))
                page.canvas.translate(MARGIN.toFloat(), (MARGIN - top).toFloat())
                layout.draw(page.canvas)
                page.canvas.restore()
                document.finishPage(page)
            }
            val temporary = File(directory, target.name + ".tmp")
            temporary.outputStream().use { document.writeTo(it) }
            if (!temporary.renameTo(target)) throw IOException("rename")
            return target
        } catch (error: IOException) {
            throw AppFailure("Das PDF konnte nicht erstellt werden. Der Bericht bleibt unverändert.")
        } finally {
            document.close()
        }
    }

    /** Whole lines per page; no line is split or dropped, a line taller than a page gets its own page. */
    internal fun paginate(tops: IntArray, bottoms: IntArray, usable: Int): List<IntRange> {
        val pages = mutableListOf<IntRange>()
        var line = 0
        while (line < tops.size) {
            var last = line
            while (last + 1 < tops.size && bottoms[last + 1] - tops[line] <= usable) last += 1
            pages += line..last
            line = last + 1
        }
        return pages
    }

    fun cleanExpired(now: Long = System.currentTimeMillis()) {
        directory.listFiles()?.filter { now - it.lastModified() > MAX_AGE_MILLIS }?.forEach { it.delete() }
    }

    fun remove(reportIDs: List<String>) { reportIDs.forEach { file(it).delete() } }
}
