package de.tobwil.vetmed.core

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import java.io.Closeable
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URI
import java.security.MessageDigest

/**
 * The one offline model this build accepts. Everything that reaches the disk derives from these pinned values,
 * never from names or sizes supplied by the network (same rule as the iOS `ModelManifest`).
 */
@Serializable
data class ModelManifest(
    val id: String,
    val revision: String,
    val file: String,
    val bytes: Long,
    val sha256: String,
    val title: String,
    val license: String,
) {
    val url: String get() = "https://huggingface.co/$id/resolve/$revision/$file"

    fun validate() {
        val hex = Regex("^[0-9a-f]+$")
        val repository = Regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
        if (!repository.matches(id) || id.contains("..") || revision.length != 40 || !hex.matches(revision) ||
            file.isEmpty() || file.contains('/') || file.contains('\\') || file.startsWith(".") || !file.endsWith(".litertlm") ||
            bytes <= 0 || sha256.length != 64 || !hex.matches(sha256)
        ) throw AppFailure("Ungültiges Modellverzeichnis. Kein Download gestartet.")
    }

    companion object {
        /** Gemma 4 E2B for LiteRT-LM, Apache-2.0, not gated. Size and hash as published by Hugging Face for this commit. */
        val GEMMA_4_E2B = ModelManifest(
            id = "litert-community/gemma-4-E2B-it-litert-lm",
            revision = "b3ca0d2f076785a8f4b2219ddbd2bdb99954eae1",
            file = "gemma-4-E2B-it.litertlm",
            bytes = 2_588_147_712,
            sha256 = "181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c",
            title = "Gemma 4 E2B · LiteRT-LM",
            license = "Apache-2.0",
        )
    }
}

class ModelResponse(val status: Int, val start: Long?, val stream: InputStream, private val onClose: () -> Unit = {}) : Closeable {
    override fun close() { runCatching { stream.close() }; onClose() }
}

/** Opens `url` from byte [offset]. Tests replace it; production uses [HttpsModelTransport]. */
fun interface ModelTransport { fun open(url: String, offset: Long): ModelResponse }

/** Plain HTTPS without cookies or credentials. Redirects are followed manually and only to HTTPS. */
object HttpsModelTransport : ModelTransport {
    override fun open(url: String, offset: Long): ModelResponse {
        var target = url
        repeat(6) {
            val uri = URI(target)
            if (uri.scheme != "https") throw AppFailure("Modelldownload nur über HTTPS erlaubt.")
            val connection = uri.toURL().openConnection() as HttpURLConnection
            connection.instanceFollowRedirects = false
            connection.connectTimeout = 30_000; connection.readTimeout = 60_000
            connection.useCaches = false
            connection.setRequestProperty("Accept-Encoding", "identity")
            if (offset > 0) connection.setRequestProperty("Range", "bytes=$offset-")
            val status = connection.responseCode
            if (status in 300..399) {
                val location = connection.getHeaderField("Location") ?: throw AppFailure("Modelldownload: Weiterleitung ohne Ziel.")
                connection.disconnect()
                target = uri.resolve(location).toString()
                return@repeat
            }
            if (status != 200 && status != 206) {
                connection.disconnect()
                throw AppFailure("Modelldownload fehlgeschlagen (HTTP $status). Bereits geladene Teile bleiben für einen neuen Versuch erhalten.")
            }
            val start = connection.getHeaderField("Content-Range")?.let { Regex("""bytes (\d+)-""").find(it)?.groupValues?.get(1)?.toLongOrNull() }
            return ModelResponse(status, if (status == 206) start else 0L, connection.inputStream) { connection.disconnect() }
        }
        throw AppFailure("Modelldownload: zu viele Weiterleitungen.")
    }
}

@Serializable
private data class ModelReceipt(val manifest: ModelManifest, val size: Long, val modified: Long)

/**
 * Resumable, verified installation into the app's no-backup storage. The file only moves to its final place after
 * the pinned SHA-256 matched; a receipt allows a fast readiness check, and every load re-hashes the file.
 */
class ModelStore(
    private val root: File,
    val manifest: ModelManifest = ModelManifest.GEMMA_4_E2B,
    private val transport: ModelTransport = HttpsModelTransport,
    private val freeSpace: (File) -> Long = { it.usableSpace },
) {
    val directory: File get() = File(root, manifest.id.replace("/", "--") + "/" + manifest.revision)
    val modelFile: File get() = File(directory, manifest.file)
    private val partial: File get() = File(root, manifest.id.replace("/", "--") + "/" + manifest.revision + ".partial")
    private val receipt: File get() = File(directory, "verified.json")

    /**
     * Size and modification time of the file after its last full SHA-256 check in this process. The check runs
     * after installation and at most once per app start; later loads (after every app switch the model is
     * unloaded) only confirm that the verified file is unchanged, instead of hashing gigabytes again.
     */
    @Volatile private var verifiedStamp: Pair<Long, Long>? = null
    @Volatile var fullChecks = 0
        private set
    private fun stamp() = modelFile.length() to modelFile.lastModified()

    fun isInstalled(): Boolean = runCatching {
        manifest.validate()
        val value = VetJson.decodeFromString(ModelReceipt.serializer(), receipt.readText())
        value.manifest == manifest && modelFile.length() == manifest.bytes && value.size == manifest.bytes && value.modified == modelFile.lastModified()
    }.getOrDefault(false)

    /** Bytes on disk, including an interrupted download. */
    fun storedBytes(): Long = modelFile.takeIf { it.exists() }?.length() ?: partial.takeIf { it.exists() }?.length() ?: 0L

    suspend fun install(progress: (Double) -> Unit = {}, verifying: () -> Unit = {}): File = withContext(Dispatchers.IO) {
        manifest.validate()
        if (isInstalled()) return@withContext modelFile
        root.mkdirs(); partial.parentFile?.mkdirs()
        if (partial.length() > manifest.bytes) partial.delete()
        val needed = manifest.bytes - partial.length() + 512L * 1024 * 1024
        if (freeSpace(root) < needed) throw AppFailure("Für das Offline-Modell werden etwa ${(needed + 999_999_999) / 1_000_000_000} GB freier Speicher benötigt.")
        var failures = 0
        while (partial.length() < manifest.bytes) {
            currentCoroutineContext().ensureActive()
            val before = partial.length()
            val stalled = try { download(progress); partial.length() <= before } catch (error: IOException) { true }
            if (stalled && ++failures >= 3) throw AppFailure("Der Download wurde unterbrochen. Beim nächsten Versuch wird an derselben Stelle fortgesetzt.")
        }
        verifying()
        if (!matches(partial)) {
            partial.delete()
            throw AppFailure("Integritätsprüfung fehlgeschlagen. Die Datei wurde verworfen und wird nicht geladen.")
        }
        directory.mkdirs()
        if (modelFile.exists()) modelFile.delete()
        if (!partial.renameTo(modelFile)) throw AppFailure("Das Modell konnte nicht abgelegt werden.")
        receipt.writeText(VetJson.encodeToString(ModelReceipt.serializer(), ModelReceipt(manifest, modelFile.length(), modelFile.lastModified())))
        verifiedStamp = stamp()
        progress(1.0)
        modelFile
    }

    private suspend fun download(progress: (Double) -> Unit) {
        val offset = partial.length()
        transport.open(manifest.url, offset).use { response ->
            // A server that ignores the range restarts from zero instead of appending at the wrong place.
            val append = response.status == 206 && response.start == offset
            var written = if (append) offset else 0L
            FileOutputStream(partial, append).use { output ->
                val buffer = ByteArray(1 shl 20)
                var lastReport = 0L
                while (true) {
                    currentCoroutineContext().ensureActive()
                    val read = response.stream.read(buffer)
                    if (read < 0) break
                    if (written + read > manifest.bytes) throw AppFailure("Der Server lieferte mehr Daten als erwartet. Download abgebrochen.")
                    output.write(buffer, 0, read); written += read
                    if (written - lastReport >= 8L shl 20) { progress(written.toDouble() / manifest.bytes); lastReport = written }
                }
                output.fd.sync()
            }
            progress(written.toDouble() / manifest.bytes)
        }
    }

    /** Runs before every load: a full SHA-256 check once per process, afterwards only when the file changed. */
    suspend fun verify() = withContext(Dispatchers.IO) {
        val failure = AppFailure("Die Modelldatei fehlt oder ist beschädigt. Bitte das Modell in den Einstellungen löschen und erneut laden; Fälle bleiben erhalten.")
        if (!isInstalled()) { verifiedStamp = null; throw failure }
        val current = stamp()
        if (verifiedStamp == current) return@withContext
        verifiedStamp = null
        fullChecks += 1
        if (!matches(modelFile)) throw failure
        verifiedStamp = current
    }

    private suspend fun matches(file: File): Boolean {
        if (file == partial) fullChecks += 1
        if (!file.exists() || file.length() != manifest.bytes) return false
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(1 shl 20)
            while (true) {
                currentCoroutineContext().ensureActive()
                val read = input.read(buffer)
                if (read < 0) break
                digest.update(buffer, 0, read)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) } == manifest.sha256
    }

    fun remove() {
        verifiedStamp = null
        directory.deleteRecursively(); partial.delete()
    }
}

/** Port of the iOS `OutputRepetition`: stops local generations that loop on the same long phrase. */
object OutputRepetition {
    fun containsLoop(text: String): Boolean {
        val words = text.lowercase().replace(Regex("""\[\d+]"""), "").split(Regex("""[^\p{L}\p{N}]+""")).filter { it.isNotEmpty() }
        // Three occurrences of a long phrase also detect alternating duplicate bullets and loops without punctuation.
        if (words.size < 48) return false
        val occurrences = mutableMapOf<String, MutableList<Int>>()
        for (start in 0..(words.size - 16)) {
            val phrase = words.subList(start, start + 16).joinToString(" ")
            val prior = occurrences[phrase].orEmpty()
            val last = prior.lastOrNull()
            if (last != null && start - last < 16) continue
            if (prior.size >= 2) return true
            occurrences.getOrPut(phrase) { mutableListOf() } += start
        }
        return false
    }

    const val MESSAGE = "Die Antwort wurde wegen einer Wiederholungsschleife gestoppt. Bitte erneut versuchen."
}

/** Runtime protection like iOS `DeviceReadiness`. Not a device qualification claim. */
object DeviceReadiness {
    const val MINIMUM_MEMORY = 7_000_000_000L // 8 GB devices report a little less as total memory.

    fun blockingReason(totalMemory: Long, thermalSevere: Boolean, abis: List<String>): String? = when {
        abis.none { it == "arm64-v8a" || it == "x86_64" } -> "Das Offline-Modell benötigt ein 64-Bit-Gerät (arm64-v8a)."
        thermalSevere -> "Das Gerät ist zu warm. Bitte abkühlen lassen, bevor du das lokale Modell erneut startest."
        totalMemory < MINIMUM_MEMORY -> "Für das Offline-Modell sind mindestens 8 GB Arbeitsspeicher vorgesehen. Es wird nichts heruntergeladen."
        else -> null
    }
}
