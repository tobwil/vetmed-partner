package de.tobwil.vetmed

import de.tobwil.vetmed.core.AppFailure
import de.tobwil.vetmed.core.CaseOperations
import de.tobwil.vetmed.core.OnlineReportConfiguration
import de.tobwil.vetmed.core.VaultDocument
import de.tobwil.vetmed.data.SealedFile
import de.tobwil.vetmed.data.VaultRepository
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.time.Instant

/** Same guarantees as the iOS encrypted round-trip tests, with a software key in place of the Keystore. */
class SealedStoreTests {
    @get:Rule val folder = TemporaryFolder()

    private inline fun assertFails(message: String, block: () -> Unit) {
        try { block(); fail("Expected: $message") } catch (error: AppFailure) { assertTrue(error.message, error.message!!.contains(message)) }
    }

    @Test fun roundTripDoesNotStorePlaintext() {
        val file = folder.root.resolve("data.sealed")
        val sealed = SealedFile(file, MemoryKeys(), "test/v1")
        sealed.write("Kein Fieber. 12,5 kg".encodeToByteArray())
        assertFalse(file.readBytes().decodeToString(throwOnInvalidSequence = false).contains("Fieber"))
        assertArrayEquals("Kein Fieber. 12,5 kg".encodeToByteArray(), sealed.read())
        assertFalse(folder.root.resolve("data.sealed.tmp").exists())
    }

    @Test fun tamperingWrongKeyAndWrongContextAreRejected() {
        val file = folder.root.resolve("data.sealed")
        val keys = MemoryKeys()
        SealedFile(file, keys, "test/v1").write("Synthetischer Fall".encodeToByteArray())
        assertFails("nicht geprüft") { SealedFile(file, keys, "other/v1").read() }
        assertFails("nicht geprüft") { SealedFile(file, MemoryKeys().apply { create() }, "test/v1").read() }
        val bytes = file.readBytes(); bytes[bytes.size - 1] = (bytes.last() + 1).toByte(); file.writeBytes(bytes)
        assertFails("nicht geprüft") { SealedFile(file, keys, "test/v1").read() }
    }

    @Test fun missingKeyNeverOverwritesExistingData() {
        val file = folder.root.resolve("data.sealed")
        SealedFile(file, MemoryKeys(), "test/v1").write("alt".encodeToByteArray())
        val before = file.readBytes()
        val lost = MemoryKeys()
        assertFails("Schlüssel") { SealedFile(file, lost, "test/v1").read() }
        assertFails("Schlüssel") { SealedFile(file, lost, "test/v1").write("neu".encodeToByteArray()) }
        assertEquals(0, lost.created)
        assertArrayEquals(before, file.readBytes())
    }

    @Test fun repositoryKeepsCasesSecretsAndVocabularySeparate() = runTest {
        val data = MemoryKeys(); val secrets = MemoryKeys()
        val repository = VaultRepository(folder.root, data, secrets)
        assertEquals(VaultDocument(), repository.load())
        val (document, _) = CaseOperations.newEncounter(VaultDocument())!!
        repository.save(document)
        repository.saveOnline(OnlineReportConfiguration("synthetic-model", Instant.parse("2026-09-30T08:00:00Z")), "synthetic-api-key-for-contract-tests")
        val reopened = VaultRepository(folder.root, data, secrets)
        assertEquals(document, reopened.load())
        assertEquals("synthetic-api-key-for-contract-tests", reopened.apiKey())
        assertTrue(reopened.onlineConfiguration().isEnabled)
        reopened.removeApiKey(OnlineReportConfiguration("synthetic-model"))
        assertNull(reopened.apiKey())
        assertFalse(reopened.onlineConfiguration().isEnabled)
        assertEquals(document, reopened.load())
        // Case data never lands in the secret store and vice versa.
        assertFails("nicht geprüft") { VaultRepository(folder.root, secrets, data).load() }
    }

    @Test fun invalidApiKeyIsNotStored() = runTest {
        val repository = VaultRepository(folder.root, MemoryKeys(), MemoryKeys())
        assertFails("gültigen API-Key") { repository.saveOnline(OnlineReportConfiguration("m"), "kurz") }
        assertNull(repository.apiKey())
    }
}
