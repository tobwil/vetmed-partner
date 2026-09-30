package de.tobwil.vetmed

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import de.tobwil.vetmed.core.AppFailure
import de.tobwil.vetmed.core.CaseOperations
import de.tobwil.vetmed.core.VaultDocument
import de.tobwil.vetmed.data.AndroidKeystoreKeySource
import de.tobwil.vetmed.data.VaultRepository
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.security.KeyStore
import java.util.UUID

/**
 * Runs only on an emulator or device (`./gradlew :app:connectedDebugAndroidTest`): real SQLCipher,
 * real Android Keystore. Synthetic data only.
 */
@RunWith(AndroidJUnit4::class)
class SqlCipherDeviceTests {
    private val context: Context = ApplicationProvider.getApplicationContext()
    private val suffix = UUID.randomUUID().toString()
    private val root = File(context.cacheDir, "sqlcipher-test-$suffix")
    private val aliases = listOf("test.vault.$suffix", "test.secrets.$suffix")
    private fun repository(dataAlias: String = aliases[0]) =
        VaultRepository(context, root, AndroidKeystoreKeySource(dataAlias), AndroidKeystoreKeySource(aliases[1]))

    @After fun cleanUp() {
        root.deleteRecursively()
        KeyStore.getInstance("AndroidKeyStore").apply { load(null) }.let { store -> (aliases + "test.other.$suffix").forEach { store.deleteEntry(it) } }
    }

    @Test fun databaseIsEncryptedAndRoundTrips() = runTest {
        val (document, location) = CaseOperations.newEncounter(VaultDocument())!!
        val marker = "Synthetischer Klartextmarker 12,5 kg"
        val withText = CaseOperations.saveTranscript(document, location, marker)
        val repository = repository()
        repository.save(withText)
        repository.verifyIntegrity()
        repository.close()
        val bytes = File(root, "cases.db").readBytes()
        assertFalse("database header must not be plain SQLite", bytes.copyOfRange(0, 15).decodeToString() == "SQLite format 3")
        assertFalse("clinical text must not appear in the file", bytes.decodeToString(throwOnInvalidSequence = false).contains("Klartextmarker"))
        assertEquals(withText, repository().load())
    }

    @Test fun otherKeystoreKeyCannotOpenTheDatabase() = runTest {
        repository().apply { save(CaseOperations.newEncounter(VaultDocument())!!.first); close() }
        try { repository("test.other.$suffix").load(); fail("Other key must not open the database") } catch (_: AppFailure) {}
    }
}
