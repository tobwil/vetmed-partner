package de.tobwil.vetmed

import android.app.Application
import androidx.test.core.app.ApplicationProvider
import de.tobwil.vetmed.core.AppFailure
import de.tobwil.vetmed.core.CaseOperations
import de.tobwil.vetmed.core.OnlineReportConfiguration
import de.tobwil.vetmed.core.VaultDocument
import de.tobwil.vetmed.core.VetJson
import de.tobwil.vetmed.core.VocabularyEntry
import de.tobwil.vetmed.data.SealedFile
import de.tobwil.vetmed.data.VaultRepository
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.builtins.ListSerializer
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.File
import java.time.Instant

/** Room schema, transactions, key handling and migration, mirroring the iOS repository tests. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [36])
class CaseDatabaseTests {
    @get:Rule val folder = TemporaryFolder()
    private val context: Application = ApplicationProvider.getApplicationContext()
    private val data = MemoryKeys()
    private val secrets = MemoryKeys()
    private fun repository() = testRepository(context, folder.root, data, secrets)

    private suspend inline fun assertFails(message: String, block: () -> Unit) {
        try { block(); fail("Expected: $message") } catch (error: AppFailure) { assertTrue(error.message, error.message!!.contains(message)) }
    }

    @Test fun roundTripKeepsOrderVersionsSharesAndApproval() = runTest {
        val seeded = SyntheticCases.seed()
        val document = CaseOperations.recordShare(seeded.document, seeded.withReport, seeded.reportID, "Text")
        val repository = repository()
        repository.save(document)
        repository.close()
        val reopened = repository()
        assertEquals(document, reopened.load())
        reopened.verifyIntegrity()
    }

    @Test fun replacingTheDocumentRemovesDeletedCasesWithAllVersions() = runTest {
        val seeded = SyntheticCases.seed()
        val repository = repository()
        repository.save(seeded.document)
        val remaining = CaseOperations.deleteCase(seeded.document, seeded.withReport.caseID)
        repository.save(remaining)
        assertEquals(remaining, repository.load())
        assertEquals(2, repository.load().cases.size)
    }

    @Test fun failedTransactionKeepsPreviousVersion() = runTest {
        val seeded = SyntheticCases.seed()
        val repository = repository()
        repository.save(seeded.document)
        // Two cases with one ID violate the primary key halfway through the replacement.
        val broken = seeded.document.copy(cases = seeded.document.cases + seeded.document.cases.first())
        assertFails("letzte gespeicherte Fassung bleibt erhalten") { repository.save(broken) }
        assertEquals(seeded.document, repository.load())
    }

    @Test fun missingDatabaseKeyNeverOverwritesExistingCases() = runTest {
        val repository = repository()
        repository.save(SyntheticCases.seed().document)
        repository.close()
        val database = File(folder.root, "cases.db")
        val before = database.readBytes()
        val lost = testRepository(context, folder.root, MemoryKeys(), secrets)
        assertFails("Schlüssel zu vorhandenen Daten fehlt") { lost.load() }
        assertArrayEquals(before, database.readBytes())
    }

    @Test fun unencryptedDatabaseIsRefusedWhenCipherIsRequired() = runTest {
        val strict = VaultRepository(context, folder.root, data, secrets, PlainSqliteOpener, requireCipher = true)
        assertFails("SQLCipher ist nicht aktiv") { strict.load() }
    }

    @Test fun firstAndroidVersionIsMigratedVerifiedAndRemoved() = runTest {
        val seeded = SyntheticCases.seed()
        val legacyCases = SealedFile(File(folder.root, "cases.v1.sealed"), data, "vetmed/cases/v1")
        val legacyVocabulary = SealedFile(File(folder.root, "vocabulary.v1.sealed"), data, "vetmed/vocabulary/v1")
        val vocabulary = listOf(VocabularyEntry(recognized = "Otitis ex terna", preferred = "Otitis externa"))
        legacyCases.write(VetJson.encodeToString(VaultDocument.serializer(), seeded.document).encodeToByteArray())
        legacyVocabulary.write(VetJson.encodeToString(ListSerializer(VocabularyEntry.serializer()), vocabulary).encodeToByteArray())
        val repository = repository()
        assertEquals(seeded.document, repository.load())
        assertEquals(vocabulary, repository.vocabulary())
        assertFalse(legacyCases.exists); assertFalse(legacyVocabulary.exists)
    }

    @Test fun vocabularyAndSecretsStaySeparateFromCases() = runTest {
        val repository = repository()
        val (document, _) = CaseOperations.newEncounter(VaultDocument())!!
        repository.save(document)
        repository.saveVocabulary(listOf(VocabularyEntry(recognized = "a", preferred = "b")))
        repository.saveOnline(OnlineReportConfiguration("synthetic-model", Instant.parse("2026-09-30T08:00:00Z")), "synthetic-api-key-for-contract-tests")
        repository.close()
        val reopened = repository()
        assertEquals(document, reopened.load())
        assertEquals("b", reopened.vocabulary().single().preferred)
        assertEquals("synthetic-api-key-for-contract-tests", reopened.apiKey())
        assertTrue(reopened.onlineConfiguration().isEnabled)
        reopened.removeApiKey(OnlineReportConfiguration("synthetic-model"))
        assertNull(reopened.apiKey())
        assertFalse(reopened.onlineConfiguration().isEnabled)
        assertEquals(document, reopened.load())
        // The API key is sealed with the secret key, not the case key.
        assertFails("Schlüssel zu vorhandenen Daten fehlt") {
            reopened.saveOnline(OnlineReportConfiguration("m"), "synthetic-api-key-for-contract-tests")
            testRepository(context, folder.root, data, MemoryKeys()).apiKey()
        }
    }

    @Test fun invalidApiKeyIsNotStored() = runTest {
        val repository = repository()
        assertFails("gültigen API-Key") { repository.saveOnline(OnlineReportConfiguration("m"), "kurz") }
        assertNull(repository.apiKey())
    }
}
