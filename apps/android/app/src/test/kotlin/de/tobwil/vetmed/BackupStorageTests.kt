package de.tobwil.vetmed

import android.app.Application
import androidx.test.core.app.ApplicationProvider
import de.tobwil.vetmed.core.AppFailure
import de.tobwil.vetmed.core.AttachmentKind
import de.tobwil.vetmed.core.AudioSegment
import de.tobwil.vetmed.core.ChatAttachment
import de.tobwil.vetmed.core.VocabularyEntry
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File

/** Backup between two devices with different keys (ADR 0019). Synthetic data only. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [36])
class BackupStorageTests {
    @get:Rule val folder = TemporaryFolder()
    private val context: Application = ApplicationProvider.getApplicationContext()
    private val password = "Synthetisches Passwort 1"

    @Test fun aBackupMovesCasesFilesAndVocabularyToANewDevice() = runTest {
        val seeded = SyntheticCases.seed().document
        val case = seeded.cases.first()
        val encounter = case.encounters.first()
        val photo = ChatAttachment(id = "7D8E9F0A-1B2C-4D3E-8F4A-5B6C7D8E9F0A", kind = AttachmentKind.IMAGE, originalName = "pfote.jpg", originalExtension = "jpg",
            originalByteCount = 6, originalSHA256 = "x", uploadSHA256 = "y", uploadByteCount = 4)
        val audio = AudioSegment("8E9F0A1B-2C3D-4E4F-9A5B-6C7D8E9F0A1B", 1.0)
        val document = seeded.copy(cases = listOf(case.copy(encounters = listOf(encounter.copy(chatAttachments = listOf(photo), audio = encounter.audio + audio)))) + seeded.cases.drop(1))
        val wav = ByteArray(32_000) { (it % 97).toByte() }

        val phone = testRepository(context, File(folder.root, "phone"), MemoryKeys(), MemoryKeys())
        phone.save(document)
        phone.saveVocabulary(listOf(VocabularyEntry(recognized = "Meloxikam", preferred = "Meloxicam")))
        phone.storeAttachment(case.id, encounter.id, photo.id, "ORIGIN".encodeToByteArray(), "JPEG".encodeToByteArray())
        phone.storeAudio(case.id, encounter.id, audio.id, wav)
        val out = ByteArrayOutputStream()
        val written = phone.writeBackup(out, password, document, includeAudio = true) { _, _ -> }
        // The seeded recordings have no files: they are counted as missing, the backup still completes.
        assertEquals(document.cases.flatMap { it.encounters }.sumOf { it.audio.size } - 1, written.missing)

        val newPhone = testRepository(context, File(folder.root, "new-phone"), MemoryKeys(), MemoryKeys())
        try { newPhone.readBackup(ByteArrayInputStream(out.toByteArray()), "Falsches Passwort", newPhone.load()); fail("wrong password") }
        catch (error: AppFailure) { assertTrue(error.message!!.contains("Passwort ist falsch")) }
        val restored = newPhone.readBackup(ByteArrayInputStream(out.toByteArray()), password, newPhone.load())
        newPhone.save(restored.document); newPhone.saveVocabulary(restored.vocabulary)
        newPhone.close()

        // Closed and opened again from the database and the sealed files of the new device.
        assertEquals(document, newPhone.load())
        assertEquals("Meloxicam", newPhone.vocabulary().single().preferred)
        assertArrayEquals("ORIGIN".encodeToByteArray(), newPhone.attachmentData(case.id, encounter.id, photo.id, upload = false))
        assertArrayEquals("JPEG".encodeToByteArray(), newPhone.attachmentData(case.id, encounter.id, photo.id, upload = true))
        assertArrayEquals(wav, newPhone.audio(case.id, encounter.id, audio.id))
        assertEquals(document.cases.size, restored.addedCases)
    }
}
