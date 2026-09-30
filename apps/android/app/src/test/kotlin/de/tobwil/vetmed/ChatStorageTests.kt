package de.tobwil.vetmed

import android.app.Application
import android.graphics.Bitmap
import android.graphics.Color
import androidx.sqlite.db.SupportSQLiteOpenHelper
import androidx.sqlite.db.framework.FrameworkSQLiteOpenHelperFactory
import androidx.test.core.app.ApplicationProvider
import de.tobwil.vetmed.core.AppFailure
import de.tobwil.vetmed.core.AttachmentKind
import de.tobwil.vetmed.core.AttachmentLimits
import de.tobwil.vetmed.core.ChatOperations
import de.tobwil.vetmed.core.SparringDraft
import de.tobwil.vetmed.core.VaultDocument
import de.tobwil.vetmed.core.VetCase
import de.tobwil.vetmed.core.VetJson
import de.tobwil.vetmed.data.AttachmentImporter
import de.tobwil.vetmed.data.SealedFile
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import java.io.ByteArrayOutputStream
import java.io.File

@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [36])
class ChatStorageTests {
    @get:Rule val folder = TemporaryFolder()
    private val context: Application = ApplicationProvider.getApplicationContext()
    private val data = MemoryKeys(); private val secrets = MemoryKeys()
    private fun repository() = testRepository(context, folder.root, data, secrets)
    private suspend inline fun assertFails(message: String, block: () -> Unit) {
        try { block(); fail("Expected: $message") } catch (error: AppFailure) { assertTrue(error.message, error.message!!.contains(message)) }
    }

    @Test fun quickChecksAndCaseChatsRoundTrip() = runTest {
        val document = SyntheticCases.seed().document
        repository().apply { save(document); close() }
        val reopened = repository().load()
        assertEquals(document, reopened)
        assertEquals("Allgemeine Frage zur Impfung", reopened.quickChecks!!.single().draft.question)
        assertTrue(reopened.cases.any { item -> item.encounters.any { !it.analysisRuns.isNullOrEmpty() } })
    }

    @Test fun databaseVersionOneIsMigratedWithoutLosingCases() = runTest {
        val schema = Json.parseToJsonElement(File("schemas/de.tobwil.vetmed.data.CaseDatabase/1.json").readText()).jsonObject.getValue("database").jsonObject
        val item = VetCase(label = "Aus Version 1", species = "Hund")
        val helper = FrameworkSQLiteOpenHelperFactory().create(
            SupportSQLiteOpenHelper.Configuration.builder(context).name(File(folder.root, "cases.db").absolutePath).callback(object : SupportSQLiteOpenHelper.Callback(1) {
                override fun onCreate(db: androidx.sqlite.db.SupportSQLiteDatabase) {
                    schema.getValue("entities").jsonArray.forEach { entity ->
                        val table = entity.jsonObject.getValue("tableName").jsonPrimitive.content
                        db.execSQL(entity.jsonObject.getValue("createSql").jsonPrimitive.content.replace("\${TABLE_NAME}", table))
                        entity.jsonObject["indices"]?.jsonArray?.forEach { index -> db.execSQL(index.jsonObject.getValue("createSql").jsonPrimitive.content.replace("\${TABLE_NAME}", table)) }
                    }
                    schema.getValue("setupQueries").jsonArray.forEach { db.execSQL(it.jsonPrimitive.content) }
                    db.execSQL("INSERT INTO clinical_case VALUES (?, 0, ?)", arrayOf(item.id, VetJson.encodeToString(VetCase.serializer(), item).encodeToByteArray()))
                }
                override fun onUpgrade(db: androidx.sqlite.db.SupportSQLiteDatabase, oldVersion: Int, newVersion: Int) {}
            }).build(),
        )
        helper.writableDatabase.close(); helper.close()
        // A version 1 installation already has its sealed passphrase next to the database.
        SealedFile(File(folder.root, "database-key.v1.sealed"), data, "vetmed/database-key/v1").write(ByteArray(32) { 7 })
        val repository = repository()
        assertEquals(listOf(item), repository.load().cases)
        val (withCheck, _) = ChatOperations.newQuickCheck(repository.load())
        repository.save(withCheck)
        assertEquals(1, repository().load().quickChecks!!.size)
    }

    @Test fun attachmentsAreEncryptedBoundToTheirChatAndRemovedWithTheCase() = runTest {
        val repository = repository()
        repository.save(VaultDocument())
        val original = "Kein Befund. 5 mmol/l".encodeToByteArray()
        repository.storeAttachment("case-a", "enc-1", "att-1", original, null)
        assertArrayEquals(original, repository.attachmentData("case-a", "enc-1", "att-1", false))
        val sealed = File(folder.root, "attachments/case-a/enc-1/att-1-original.sealed")
        assertFalse(sealed.readBytes().decodeToString(throwOnInvalidSequence = false).contains("Befund"))
        // Moving ciphertext to another case must not decrypt there.
        File(folder.root, "attachments/case-b/enc-1").mkdirs()
        sealed.copyTo(File(folder.root, "attachments/case-b/enc-1/att-1-original.sealed"))
        assertFails("nicht geprüft") { repository.attachmentData("case-b", "enc-1", "att-1", false) }
        repository.removeCaseFiles("case-a")
        assertFalse(sealed.exists())
        assertFails("nicht verfügbar") { repository.attachmentData("case-a", "enc-1", "att-1", false) }
    }

    @Test fun imagesAreReencodedWithoutMetadataAndDocumentsNeedValidUtf8() = runTest {
        val importer = AttachmentImporter(context, File(folder.root, "scratch"))
        val bitmap = Bitmap.createBitmap(5000, 2500, Bitmap.Config.ARGB_8888).apply { eraseColor(Color.rgb(120, 60, 30)) }
        val png = ByteArrayOutputStream().also { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }.toByteArray()
        val image = importer.prepare(png, "IMG_4711.png")
        assertEquals(AttachmentKind.IMAGE, image.attachment.kind)
        assertEquals(4096, image.attachment.width); assertEquals(2048, image.attachment.height)
        val upload = image.upload!!
        assertEquals(0xFF.toByte(), upload[0]); assertEquals(0xD8.toByte(), upload[1])
        assertFalse(upload.decodeToString(throwOnInvalidSequence = false).contains("Exif"))
        assertFalse(upload.decodeToString(throwOnInvalidSequence = false).contains("IMG_4711"))
        assertEquals(AttachmentLimits.sha256(upload), image.attachment.uploadSHA256)
        assertArrayEquals(png, image.original)

        val text = importer.prepare("Kein Fieber. 12,5 kg.".encodeToByteArray(), "Befund.txt")
        assertEquals(AttachmentKind.DOCUMENT, text.attachment.kind)
        assertEquals("Kein Fieber. 12,5 kg.", text.attachment.extractedText)
        assertEquals(null, text.attachment.reviewedAt)
        assertFails("UTF-8") { importer.prepare(byteArrayOf(0xC3.toByte(), 0x28), "kaputt.txt") }
        assertFails("Bild, PDF") { importer.prepare(byteArrayOf(1, 2, 3), "programm.exe") }
        assertFails("leer") { importer.prepare(ByteArray(0), "leer.txt") }
    }

    @Test fun draftsSurviveReopeningAndStayWithTheirChat() = runTest {
        val repository = repository()
        val (document, chat) = ChatOperations.newQuickCheck(VaultDocument())
        repository.save(ChatOperations.saveDraft(document, chat, SparringDraft(question = "Nur hier gespeichert")))
        repository.close()
        val reopened = repository().load()
        assertEquals("Nur hier gespeichert", ChatOperations.context(reopened, chat)!!.sparringDraft!!.question)
    }

    @Test fun orphanedEncryptedFilesAreRemovedAndReferencedOnesStay() = runTest {
        val repository = repository()
        val (withCheck, chat) = ChatOperations.newQuickCheck(VaultDocument())
        val kept = de.tobwil.vetmed.core.ChatAttachment(id = "kept", kind = AttachmentKind.DOCUMENT, originalName = "Befund.txt", originalExtension = "txt", originalByteCount = 6, originalSHA256 = "0".repeat(64))
        val document = withCheck.copy(quickChecks = withCheck.quickChecks!!.map { it.copy(chatAttachments = listOf(kept)) })
        repository.save(document)
        repository.storeAttachment(null, chat.encounterID, "kept", "bleibt".encodeToByteArray(), null)
        repository.storeAttachment(null, chat.encounterID, "orphan", "weg".encodeToByteArray(), "weg".encodeToByteArray())
        repository.storeAudio("gone-case", "gone-enc", "seg", ByteArray(64))
        assertEquals(3, repository.cleanUnreferencedFiles(document))
        assertArrayEquals("bleibt".encodeToByteArray(), repository.attachmentData(null, chat.encounterID, "kept", false))
        assertFails("nicht verfügbar") { repository.attachmentData(null, chat.encounterID, "orphan", false) }
        assertFails("nicht verfügbar") { repository.audio("gone-case", "gone-enc", "seg") }
    }
}
