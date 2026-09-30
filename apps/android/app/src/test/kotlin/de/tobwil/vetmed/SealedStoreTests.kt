package de.tobwil.vetmed

import de.tobwil.vetmed.core.AppFailure
import de.tobwil.vetmed.data.SealedFile
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

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
}
