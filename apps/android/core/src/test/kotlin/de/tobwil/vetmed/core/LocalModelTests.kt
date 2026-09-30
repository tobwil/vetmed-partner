package de.tobwil.vetmed.core

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.ByteArrayInputStream
import java.io.IOException
import java.io.InputStream
import java.security.MessageDigest

class LocalModelTests {
    @get:Rule val folder = TemporaryFolder()

    private val payload = ByteArray(5_000_000) { (it * 31 % 251).toByte() }
    private val manifest = ModelManifest(
        id = "synthetic/test-model", revision = "0".repeat(40), file = "model.litertlm", bytes = payload.size.toLong(),
        sha256 = MessageDigest.getInstance("SHA-256").digest(payload).joinToString("") { "%02x".format(it) },
        title = "Synthetisch", license = "Test",
    )

    /** Serves [data]; optionally breaks the connection after [cutAfter] bytes or ignores range requests. */
    private class Server(val data: ByteArray, var cutAfter: Int? = null, val honorRange: Boolean = true) : ModelTransport {
        val offsets = mutableListOf<Long>()
        override fun open(url: String, offset: Long): ModelResponse {
            offsets += offset
            val start = if (honorRange) offset.toInt() else 0
            val body = data.copyOfRange(start, data.size)
            val limit = cutAfter
            cutAfter = null
            val stream: InputStream = if (limit == null) ByteArrayInputStream(body) else object : InputStream() {
                var served = 0
                override fun read(): Int = throw UnsupportedOperationException()
                override fun read(b: ByteArray, off: Int, len: Int): Int {
                    if (served >= limit) throw IOException("Verbindung verloren")
                    val count = minOf(len, limit - served, body.size - served)
                    if (count <= 0) return -1
                    System.arraycopy(body, served, b, off, count); served += count; return count
                }
            }
            return ModelResponse(if (honorRange && offset > 0) 206 else 200, if (honorRange) offset else 0L, stream)
        }
    }

    @Test fun pinnedManifestIsValidAndPointsAtTheCommitNotABranch() {
        ModelManifest.GEMMA_4_E2B.validate()
        assertEquals(
            "https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/b3ca0d2f076785a8f4b2219ddbd2bdb99954eae1/gemma-4-E2B-it.litertlm",
            ModelManifest.GEMMA_4_E2B.url,
        )
        for (bad in listOf(manifest.copy(revision = "main"), manifest.copy(file = "../x.litertlm"), manifest.copy(id = "a/../b"), manifest.copy(sha256 = "abc"))) {
            try { bad.validate(); fail("Ungültiges Manifest akzeptiert: $bad") } catch (_: AppFailure) {}
        }
    }

    @Test fun anInterruptedDownloadResumesAtTheSameByteAndIsVerified() = runBlocking {
        val server = Server(payload, cutAfter = 2_000_000)
        val store = ModelStore(folder.root, manifest, server, freeSpace = { Long.MAX_VALUE })
        var verified = false
        val file = store.install(verifying = { verified = true })
        assertEquals(listOf(0L, 2_000_000L), server.offsets)
        assertTrue(verified)
        assertArrayEquals(payload, file.readBytes())
        assertTrue(store.isInstalled())
        store.verify()
        // A second install is a no-op.
        store.install()
        assertEquals(2, server.offsets.size)
    }

    @Test fun aServerIgnoringRangesRestartsInsteadOfCorruptingTheFile() = runBlocking {
        val store = ModelStore(folder.root, manifest, Server(payload, cutAfter = 1_000_000, honorRange = false), freeSpace = { Long.MAX_VALUE })
        assertArrayEquals(payload, store.install().readBytes())
    }

    @Test fun aWrongHashIsDiscardedAndNeverInstalled() = runBlocking {
        val tampered = payload.copyOf().also { it[123] = (it[123] + 1).toByte() }
        val store = ModelStore(folder.root, manifest, Server(tampered), freeSpace = { Long.MAX_VALUE })
        try { store.install(); fail("Manipulierte Datei installiert") } catch (error: AppFailure) { assertTrue(error.message!!.contains("Integritätsprüfung")) }
        assertFalse(store.isInstalled())
        assertEquals(0L, store.storedBytes())
    }

    @Test fun aChangedFileAfterInstallationIsRejectedOnLoad() = runBlocking {
        val store = ModelStore(folder.root, manifest, Server(payload), freeSpace = { Long.MAX_VALUE })
        val file = store.install()
        file.writeBytes(payload.copyOf().also { it[0] = 9 })
        assertFalse(store.isInstalled())
        try { store.verify(); fail("Beschädigte Datei geladen") } catch (error: AppFailure) { assertTrue(error.message!!.contains("beschädigt")) }
        store.remove()
        assertEquals(0L, store.storedBytes())
    }

    @Test fun theFileIsHashedOncePerProcessNotBeforeEveryLoad() = runBlocking {
        val server = Server(payload)
        val store = ModelStore(folder.root, manifest, server, freeSpace = { Long.MAX_VALUE })
        store.install()
        assertEquals("Prüfung nach dem Download", 1, store.fullChecks)
        repeat(5) { store.verify() }
        assertEquals("Wiederholtes Laden prüft nicht erneut", 1, store.fullChecks)
        // A new app start (new store instance) checks the whole file once.
        val restarted = ModelStore(folder.root, manifest, server, freeSpace = { Long.MAX_VALUE })
        restarted.verify(); restarted.verify()
        assertEquals(1, restarted.fullChecks)
        // Any change to the file is noticed and rejected, even within the same process.
        store.modelFile.writeBytes(payload.copyOf().also { it[42] = (it[42] + 1).toByte() })
        try { restarted.verify(); fail("Veränderte Datei geladen") } catch (_: AppFailure) {}
    }

    @Test fun missingSpaceStopsBeforeAnyDownload() = runBlocking {
        val server = Server(payload)
        try { ModelStore(folder.root, manifest, server, freeSpace = { 1_000 }).install(); fail() }
        catch (error: AppFailure) { assertTrue(error.message!!.contains("freier Speicher")) }
        assertTrue(server.offsets.isEmpty())
    }

    @Test fun repetitionLoopsAreDetectedButNormalReportsPass() {
        val phrase = "der hund zeigt eine deutliche lahmheit hinten links mit schwellung am sprunggelenk und schmerzen bei beugung heute "
        assertTrue(OutputRepetition.containsLoop(phrase.repeat(4)))
        val normal = (1..60).joinToString(" ") { "Befund$it" }
        assertFalse(OutputRepetition.containsLoop(normal))
    }
}

class DeviceReadinessTests {
    @Test fun smallThirtyTwoBitOrHotDevicesAreBlocked() {
        assertEquals(null, DeviceReadiness.blockingReason(7_600_000_000, false, listOf("arm64-v8a")))
        assertTrue(DeviceReadiness.blockingReason(5_800_000_000, false, listOf("arm64-v8a"))!!.contains("8 GB"))
        assertTrue(DeviceReadiness.blockingReason(12_000_000_000, true, listOf("arm64-v8a"))!!.contains("zu warm"))
        assertTrue(DeviceReadiness.blockingReason(12_000_000_000, false, listOf("armeabi-v7a"))!!.contains("64-Bit"))
    }
}
