package de.tobwil.vetmed.core

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.time.Instant

/** Encrypted backup (ADR 0019). Synthetic data only; the fixture is also read by the iOS tests. */
class BackupTests {
    private val password = "Grüne Wiese 2026"
    private val shared = File(System.getProperty("vetmed.shared") ?: "../../../shared")
    private val fixture = shared.resolve("fixtures/backup-v1-synthetic.vetmedbackup")

    private fun hex(bytes: ByteArray) = bytes.joinToString("") { "%02x".format(it) }
    private fun date(seconds: Long) = Instant.ofEpochSecond(seconds)

    /** One case with a dictation (audio), a chat with a photo (original and upload) and a quick check with a PDF. */
    private val caseID = "6B1E3C2A-0D51-4E0B-9F1A-1C2D3E4F5A60"
    private val encounterID = "0C7E5B1D-2A3F-4B6C-8D9E-0F1A2B3C4D5E"
    private val audioID = "9A8B7C6D-5E4F-4A3B-2C1D-0E9F8A7B6C5D"
    private val photoID = "1F2E3D4C-5B6A-4978-8695-A4B3C2D1E0F9"
    private val checkID = "2E3F4A5B-6C7D-4E8F-9A0B-1C2D3E4F5A6B"
    private val pdfID = "3F4A5B6C-7D8E-4F9A-0B1C-2D3E4F5A6B7C"
    private val document = VaultDocument(
        cases = listOf(VetCase(id = caseID, label = "Synthetischer Testfall", species = "Hund", animalName = "Testhund", createdAt = date(1_794_132_000),
            encounters = listOf(Encounter(id = encounterID, date = date(1_794_132_060), reason = "Lahmheit hinten links",
                audio = listOf(AudioSegment(audioID, 12.5, date(1_794_132_070))),
                transcripts = listOf(TranscriptVersion(id = "4A5B6C7D-8E9F-4A0B-1C2D-3E4F5A6B7C8D", createdAt = date(1_794_132_100), rawText = "Kein Fieber.", editedText = "Kein Fieber.",
                    segments = listOf(TranscriptSegment("s1", "Kein Fieber.", audioID)), engine = "Synthetisch")),
                chatAttachments = listOf(ChatAttachment(id = photoID, createdAt = date(1_794_132_200), kind = AttachmentKind.IMAGE, originalName = "pfote.jpg", originalExtension = "jpg",
                    originalByteCount = 5, originalSHA256 = "a", uploadSHA256 = "b", uploadByteCount = 3)))))),
        quickChecks = listOf(QuickCheck(id = checkID, createdAt = date(1_794_132_300), chatAttachments = listOf(ChatAttachment(id = pdfID, createdAt = date(1_794_132_310),
            kind = AttachmentKind.DOCUMENT, originalName = "befund.pdf", originalExtension = "pdf", originalByteCount = 4, originalSHA256 = "c")))),
    )
    private val vocabulary = listOf(VocabularyEntry("5B6C7D8E-9F0A-4B1C-2D3E-4F5A6B7C8D9E", "Meloxikam", "Meloxicam"))
    private val files = mapOf(
        "attachment/$caseID/$encounterID/$photoID/original" to "PHOTO".encodeToByteArray(),
        "attachment/$caseID/$encounterID/$photoID/upload" to "JPG".encodeToByteArray(),
        "attachment/quick/$checkID/$pdfID/original" to "%PDF".encodeToByteArray(),
        "audio/$caseID/$encounterID/$audioID" to ByteArray(3000) { (it % 251).toByte() },
    )

    private fun backup(includeAudio: Boolean = true, chunk: Int? = null, iterations: Int = 1_000, source: VaultDocument = document): ByteArray {
        val out = ByteArrayOutputStream()
        if (chunk == null) {
            BackupContent.write(out, password, source, vocabulary, includeAudio, "android", iterations, ByteArray(16) { it.toByte() }, date(1_794_133_000)) { files.getValue(it.name) }
        } else {
            // Small chunks: many chunks for few bytes, to test order and cut-off detection.
            val stream = BackupFormat.Writer(out, password, iterations, ByteArray(16), chunk)
            val archive = BackupArchive.Writer(stream)
            archive.entry(BackupContent.MANIFEST, VetJson.encodeToString(BackupManifest.serializer(), BackupContent.manifest(source, includeAudio, "android")).encodeToByteArray())
            archive.entry(BackupContent.DOCUMENT, VetJson.encodeToString(VaultDocument.serializer(), source).encodeToByteArray())
            archive.entry(BackupContent.VOCABULARY, "[]".encodeToByteArray())
            BackupContent.files(source, includeAudio).forEach { archive.entry(it.name, files.getValue(it.name)) }
            archive.finish()
        }
        return out.toByteArray()
    }

    private fun restore(bytes: ByteArray, local: VaultDocument = VaultDocument(), secret: String = password, localVocabulary: List<VocabularyEntry> = emptyList()): Pair<BackupContent.Restored, Map<String, ByteArray>> {
        val stored = linkedMapOf<String, ByteArray>()
        val result = BackupContent.restore(ByteArrayInputStream(bytes), secret, local, localVocabulary) { file, data -> stored[file.name] = data }
        return result to stored
    }

    private fun failsWith(text: String, block: () -> Unit) {
        try { block(); fail("must fail: $text") } catch (error: AppFailure) { assertTrue(error.message, error.message!!.contains(text)) }
    }

    @Test fun keyDerivationMatchesTheStandardAndNormalizesUnicode() {
        // RFC 7914, section 11, and a German password checked with Python's hashlib.
        assertEquals("55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc49ca9cccf179b645991664b39d77ef317c71b845b1e30bd509112041d3a19783",
            hex(BackupFormat.pbkdf2("passwd".encodeToByteArray(), "salt".encodeToByteArray(), 1, 64)))
        assertEquals("f8310ac2f5c7c9515b3ed66b866de3ae3e164528c50ae1512ab9e74cea385687",
            hex(BackupFormat.pbkdf2(BackupFormat.passwordBytes(password), "vetmed-salt-0001".encodeToByteArray(), 1000)))
        // "ü" as one character and as "u" plus combining diaeresis give the same key.
        assertArrayEquals(BackupFormat.passwordBytes("Grüne"), BackupFormat.passwordBytes("Grüne"))
    }

    @Test fun passwordRules() {
        failsWith("mindestens 10 Zeichen") { BackupFormat.checkNewPassword("kurz", "kurz") }
        failsWith("Leerzeichen") { BackupFormat.checkNewPassword("            ", "            ") }
        failsWith("stimmen nicht überein") { BackupFormat.checkNewPassword(password, "$password!") }
        BackupFormat.checkNewPassword(password, password)
    }

    @Test fun everythingComesBackOnAnEmptyDevice() {
        val bytes = backup()
        // Nothing readable: no case text, no file content, no vocabulary in the clear.
        val clear = bytes.decodeToString()
        for (secret in listOf("Testhund", "Kein Fieber", "PHOTO", "Meloxikam", "%PDF", "pfote")) assertTrue(secret, !clear.contains(secret))
        val (result, stored) = restore(bytes)
        assertEquals(document, result.document)
        assertEquals(vocabulary, result.vocabulary)
        assertEquals(files.keys, stored.keys)
        files.forEach { (name, data) -> assertArrayEquals(name, data, stored.getValue(name)) }
        assertEquals(1, result.addedCases); assertEquals(1, result.addedQuickChecks); assertEquals(0, result.missingFiles)
        assertEquals(BackupManifest(createdAt = date(1_794_133_000), platform = "android", cases = 1, quickChecks = 1, attachments = 2, recordings = 1, includesAudio = true), result.manifest)
        assertEquals("1 Fall und 1 Schnellcheck wiederhergestellt.", result.summary)
    }

    @Test fun existingCasesAreNeverOverwritten() {
        val changedLocally = document.cases[0].copy(label = "Lokal geändert")
        val other = VetCase(label = "Anderer Fall", species = "Katze")
        val (result, stored) = restore(backup(), VaultDocument(cases = listOf(other, changedLocally)),
            localVocabulary = listOf(VocabularyEntry(recognized = "meloxikam", preferred = "Meloxicam")))
        assertEquals(listOf(other, changedLocally), result.document.cases)
        assertEquals(document.quickChecks, result.document.quickChecks)
        // Only the new quick check's file is written; the existing case keeps its own files.
        assertEquals(setOf("attachment/quick/$checkID/$pdfID/original"), stored.keys)
        assertEquals(1, result.vocabulary.size)
        assertEquals("0 Fälle und 1 Schnellcheck wiederhergestellt. 1 schon vorhanden, unverändert gelassen.", result.summary)
    }

    @Test fun aMissingFileIsLeftOutAndCountedWithoutBreakingTheBackup() {
        val out = ByteArrayOutputStream()
        val written = BackupContent.write(out, password, document, vocabulary, true, "android", 1_000) { if (it is BackupFile.Audio) null else files.getValue(it.name) }
        assertEquals(1, written.missing); assertEquals(3, written.files)
        val (result, stored) = restore(out.toByteArray())
        assertEquals(document, result.document); assertEquals(3, stored.size); assertEquals(1, result.missingFiles)
        assertEquals(5L + 3 + 4 + 400_000, BackupContent.estimatedBytes(document, includeAudio = true))
    }

    @Test fun recordingsCanBeLeftOutAndThatIsSaid() {
        val (result, stored) = restore(backup(includeAudio = false))
        assertTrue(stored.keys.none { it.startsWith("audio/") })
        assertEquals(1, result.missingFiles)
        assertTrue(result.summary, result.summary.contains("Aufnahmen nicht mitgesichert"))
        assertTrue(!result.manifest.includesAudio)
    }

    @Test fun wrongPasswordAndEveryKindOfDamageAreRefused() {
        val bytes = backup(chunk = 64)
        assertEquals(document, restore(bytes).first.document)
        failsWith("Passwort ist falsch") { restore(bytes, secret = "Falsches Passwort 1") }
        failsWith("keine VetMed-Sicherung") { restore("%PDF-1.7 synthetic".encodeToByteArray()) }
        // One changed byte in the middle.
        failsWith("beschädigt") { restore(bytes.copyOf().also { it[it.size / 2] = (it[it.size / 2].toInt() xor 1).toByte() }) }
        // Changed iteration count in the header: the header is authenticated with every chunk.
        failsWith("Passwort ist falsch") { restore(bytes.copyOf().also { it[8] = (it[8].toInt() xor 1).toByte() }) }
        // Cut off: in the middle of a chunk, and exactly after a chunk (the last chunk is missing).
        failsWith("unvollständig") { restore(bytes.copyOf(bytes.size - 10)) }
        val chunk = 4 + 64 + 16
        failsWith("unvollständig") { restore(bytes.copyOf(BackupFormat.HEADER_BYTES + 3 * chunk)) }
        // Two full chunks swapped.
        val swapped = bytes.copyOf().also {
            val a = BackupFormat.HEADER_BYTES + chunk; val b = a + chunk
            val first = it.copyOfRange(a, b); System.arraycopy(it, b, it, a, chunk); System.arraycopy(first, 0, it, b, chunk)
        }
        failsWith("beschädigt") { restore(swapped) }
        // Extra data after the end.
        failsWith("beschädigt") { restore(bytes + byteArrayOf(0, 0, 0, 20) + ByteArray(20)) }
    }

    @Test fun fileNamesCannotEscapeTheStore() {
        assertEquals(BackupFile.Audio(caseID, encounterID, audioID), BackupFile.parse("audio/$caseID/$encounterID/$audioID"))
        assertEquals(BackupFile.Attachment(null, checkID, pdfID, false), BackupFile.parse("attachment/quick/$checkID/$pdfID/original"))
        for (name in listOf("audio/../x/y", "audio/a/b/c/d", "attachment/a/b/c/thumbnail", "audio/a/b/c.wav", "/etc/passwd", "audio/a/b/", "attachment/a/../c/original")) {
            assertNull(name, BackupFile.parse(name))
        }
    }

    /**
     * The fixture in `shared/fixtures` is the contract with iOS: the iOS tests read it with the same password.
     * Rewrite it only on purpose: `-Dvetmed.writeBackupFixture=true`.
     */
    @Test fun sharedFixtureIsReproducibleAndReadable() {
        val bytes = backup(includeAudio = true, iterations = 1_000)
        if (System.getProperty("vetmed.writeBackupFixture") == "true") fixture.writeBytes(bytes)
        assertArrayEquals("fixture changed: format or JSON encoding differs", fixture.readBytes(), bytes)
        assertEquals(document, restore(fixture.readBytes()).first.document)
    }
}
