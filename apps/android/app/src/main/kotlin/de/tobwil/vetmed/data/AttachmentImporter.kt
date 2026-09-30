package de.tobwil.vetmed.data

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.ImageDecoder
import android.graphics.pdf.PdfRenderer
import android.net.Uri
import android.os.Build
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import de.tobwil.vetmed.core.AppFailure
import de.tobwil.vetmed.core.AttachmentKind
import de.tobwil.vetmed.core.AttachmentLimits
import de.tobwil.vetmed.core.ChatAttachment
import de.tobwil.vetmed.core.newId
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

class PreparedAttachment(val attachment: ChatAttachment, val original: ByteArray, val upload: ByteArray?)

/**
 * Android counterpart of `ChatAttachmentImporter`: the original stays local and encrypted; images are re-encoded
 * from pixels (orientation applied, EXIF/GPS and filename dropped); documents are read locally and must be reviewed.
 */
class AttachmentImporter(private val context: Context, private val scratch: File) {

    suspend fun read(uri: Uri): PreparedAttachment = withContext(Dispatchers.IO) {
        val resolver = context.contentResolver
        var name = "Anhang"; var size = -1L
        resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                cursor.getString(0)?.let { name = it }
                if (!cursor.isNull(1)) size = cursor.getLong(1)
            }
        }
        if (size > AttachmentLimits.MAXIMUM_ORIGINAL_BYTES) throw AppFailure("Bitte eine einzelne Datei bis 20 MB auswählen.")
        val data = resolver.openInputStream(uri)?.use { input ->
            val output = ByteArrayOutputStream()
            val buffer = ByteArray(262_144)
            while (true) {
                currentCoroutineContext().ensureActive()
                val read = input.read(buffer)
                if (read < 0) break
                if (output.size() + read > AttachmentLimits.MAXIMUM_ORIGINAL_BYTES) throw AppFailure("Die Datei überschreitet 20 MB.")
                output.write(buffer, 0, read)
            }
            output.toByteArray()
        } ?: throw AppFailure("Die Datei konnte nicht geöffnet werden.")
        val extension = name.substringAfterLast('.', "").lowercase().ifEmpty {
            when (resolver.getType(uri)) { "image/jpeg" -> "jpg"; "image/png" -> "png"; "image/heic", "image/heif" -> "heic"; "application/pdf" -> "pdf"; "text/plain" -> "txt"; else -> "" }
        }
        prepare(data, if (name.contains('.')) name else "$name.$extension")
    }

    suspend fun prepare(data: ByteArray, name: String): PreparedAttachment = withContext(Dispatchers.Default) {
        if (data.isEmpty() || data.size > AttachmentLimits.MAXIMUM_ORIGINAL_BYTES) throw AppFailure("Die Datei ist leer oder größer als 20 MB.")
        val extension = name.substringAfterLast('.', "").lowercase()
        val hash = AttachmentLimits.sha256(data)
        val id = newId()
        when (extension) {
            "jpg", "jpeg", "png", "heic", "heif", "webp" -> {
                val upload = uploadImage(data)
                PreparedAttachment(
                    ChatAttachment(
                        id = id, kind = AttachmentKind.IMAGE, originalName = name, originalExtension = extension, originalByteCount = data.size,
                        originalSHA256 = hash, uploadSHA256 = AttachmentLimits.sha256(upload.bytes), uploadByteCount = upload.bytes.size,
                        width = upload.width, height = upload.height,
                    ),
                    data, upload.bytes,
                )
            }
            "pdf", "txt", "text", "md" -> {
                val (text, ocr) = if (extension == "pdf") pdfText(data) else utf8(data) to false
                if (text.isBlank()) throw AppFailure("Im Dokument wurde kein Text gefunden.")
                PreparedAttachment(
                    ChatAttachment(
                        id = id, kind = AttachmentKind.DOCUMENT, originalName = name, originalExtension = extension, originalByteCount = data.size,
                        originalSHA256 = hash, extractedText = text, usedOCR = ocr,
                    ),
                    data, null,
                )
            }
            else -> throw AppFailure("Bitte ein Bild, PDF oder eine UTF-8-Textdatei auswählen.")
        }
    }

    private class Upload(val bytes: ByteArray, val width: Int, val height: Int)

    private fun uploadImage(data: ByteArray): Upload {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(data, 0, data.size, bounds)
        val width = bounds.outWidth; val height = bounds.outHeight
        if (width <= 0 || height <= 0 || width > 50_000 || height > 50_000 || width.toLong() * height > AttachmentLimits.MAXIMUM_SOURCE_PIXELS) {
            throw AppFailure("Das Bild konnte nicht geöffnet werden. Bitte ein einzelnes JPG, PNG oder HEIC mit höchstens 64 Megapixeln wählen.")
        }
        // ImageDecoder applies the EXIF orientation; only pixels are re-encoded, so metadata and names are not copied.
        val bitmap = try {
            ImageDecoder.decodeBitmap(ImageDecoder.createSource(ByteBuffer.wrap(data))) { decoder, info, _ ->
                val longest = maxOf(info.size.width, info.size.height)
                if (longest > AttachmentLimits.MAXIMUM_IMAGE_EDGE) {
                    val scale = AttachmentLimits.MAXIMUM_IMAGE_EDGE.toFloat() / longest
                    decoder.setTargetSize(maxOf(1, (info.size.width * scale).toInt()), maxOf(1, (info.size.height * scale).toInt()))
                }
                decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
            }
        } catch (error: Exception) {
            throw AppFailure("Das Bild konnte nicht geöffnet werden. Bitte ein einzelnes JPG, PNG oder HEIC mit höchstens 64 Megapixeln wählen.")
        }
        val opaque = if (bitmap.hasAlpha()) Bitmap.createBitmap(bitmap.width, bitmap.height, Bitmap.Config.ARGB_8888).also {
            android.graphics.Canvas(it).apply { drawColor(Color.WHITE); drawBitmap(bitmap, 0f, 0f, null) }
        } else bitmap
        val output = ByteArrayOutputStream()
        opaque.compress(Bitmap.CompressFormat.JPEG, 88, output)
        val bytes = output.toByteArray()
        if (bytes.size > AttachmentLimits.MAXIMUM_IMAGE_BYTES) {
            throw AppFailure("Das vorbereitete Bild ist zu groß. Bitte einen passenden Ausschnitt als eigenes Bild wählen. Das Original wird nicht still weiter verkleinert.")
        }
        return Upload(bytes, opaque.width, opaque.height)
    }

    private fun utf8(data: ByteArray): String = try {
        Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT)
            .decode(ByteBuffer.wrap(data)).toString().removePrefix("\uFEFF").let {
                if (it.length > MAX_CHARACTERS) it.take(MAX_CHARACTERS) + "\n\n[Text nach $MAX_CHARACTERS Zeichen abgeschnitten. Bitte das Original prüfen.]" else it
            }
    } catch (error: CharacterCodingException) {
        throw AppFailure("Die Textdatei ist nicht als UTF-8 lesbar.")
    }

    /** Text layer where Android can read it (Android 15+), otherwise on-device OCR of the rendered page. */
    private suspend fun pdfText(data: ByteArray): Pair<String, Boolean> {
        scratch.mkdirs()
        val file = File(scratch, "pdf-import-" + newId() + ".pdf")
        try {
            file.writeBytes(data)
            val renderer = try { PdfRenderer(ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)) }
            catch (error: Exception) { throw AppFailure("Das PDF konnte nicht geöffnet werden. Passwortgeschützte PDFs werden nicht unterstützt.") }
            renderer.use {
                var usedOCR = false
                val sections = StringBuilder()
                val pages = minOf(renderer.pageCount, MAX_PAGES)
                for (index in 0 until pages) {
                    currentCoroutineContext().ensureActive()
                    var text = renderer.openPage(index).use { page ->
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.VANILLA_ICE_CREAM) page.textContents.joinToString("\n") { it.text }.trim() else ""
                    }
                    if (text.isEmpty()) { text = ocr(renderer, index); if (text.isNotEmpty()) usedOCR = true }
                    if (text.isNotEmpty()) {
                        if (sections.isNotEmpty()) sections.append("\n\n")
                        sections.append("Seite ${index + 1}\n").append(text)
                    }
                    if (sections.length > MAX_CHARACTERS) break
                }
                var text = sections.toString()
                if (text.length > MAX_CHARACTERS) text = text.take(MAX_CHARACTERS) + "\n\n[Text nach $MAX_CHARACTERS Zeichen abgeschnitten. Bitte das Original prüfen.]"
                if (renderer.pageCount > MAX_PAGES) text += "\n\n[Nur die ersten $MAX_PAGES von ${renderer.pageCount} Seiten wurden gelesen. Bitte das Original prüfen.]"
                return text to usedOCR
            }
        } finally {
            file.delete()
        }
    }

    private suspend fun ocr(renderer: PdfRenderer, index: Int): String {
        val bitmap = renderer.openPage(index).use { page ->
            val scale = 2f
            Bitmap.createBitmap((page.width * scale).toInt().coerceIn(1, 3000), (page.height * scale).toInt().coerceIn(1, 4200), Bitmap.Config.ARGB_8888).also {
                it.eraseColor(Color.WHITE)
                page.render(it, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
            }
        }
        val recognizer = TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS)
        return try {
            suspendCancellableCoroutine { continuation ->
                recognizer.process(InputImage.fromBitmap(bitmap, 0))
                    .addOnSuccessListener { continuation.resume(it.text.trim()) }
                    .addOnFailureListener { continuation.resumeWithException(AppFailure("Die lokale Texterkennung ist fehlgeschlagen.")) }
            }
        } finally {
            recognizer.close(); bitmap.recycle()
        }
    }

    companion object {
        const val MAX_PAGES = 50
        const val MAX_CHARACTERS = 100_000
    }
}
