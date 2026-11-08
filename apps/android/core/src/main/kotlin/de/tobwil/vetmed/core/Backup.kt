package de.tobwil.vetmed.core

import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import java.io.DataInputStream
import java.io.EOFException
import java.io.InputStream
import java.io.OutputStream
import java.nio.ByteBuffer
import java.security.GeneralSecurityException
import java.security.SecureRandom
import java.text.Normalizer
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Password-protected backup of all cases (ADR 0019). The same file format on Android and iOS, so a backup can also
 * move cases to the other platform.
 *
 * File: header, then AES-256-GCM chunks. The key comes from the password with PBKDF2-HMAC-SHA256 and a random salt.
 * Each chunk authenticates the header, its index and whether it is the last one, so chunks cannot be reordered,
 * dropped or cut off unnoticed. Chunks keep memory small for long recordings.
 *
 *     header  "VMBK" | version u8 | iterations u32 | salt 16 | chunk size u32          (29 bytes, big endian)
 *     chunk   length u32 | ciphertext with tag                                      nonce = 0000 | index u64
 *
 * Inside: a simple archive of named entries (manifest, cases, vocabulary, attachments, recordings).
 */
object BackupFormat {
    private val MAGIC = "VMBK".encodeToByteArray()
    const val VERSION: Byte = 1
    const val HEADER_BYTES = 29
    const val DEFAULT_ITERATIONS = 600_000
    const val CHUNK_BYTES = 1 shl 20
    private const val TAG_BYTES = 16
    const val MIN_PASSWORD = 10
    const val FILE_EXTENSION = "vetmedbackup"

    /** Unicode-normalized UTF-8, so "ü" typed on iOS and on Android gives the same key. */
    fun passwordBytes(password: String): ByteArray = Normalizer.normalize(password, Normalizer.Form.NFC).encodeToByteArray()

    fun checkNewPassword(password: String, repeated: String) {
        if (password.length < MIN_PASSWORD) throw AppFailure("Das Passwort braucht mindestens $MIN_PASSWORD Zeichen.")
        if (password.isBlank()) throw AppFailure("Das Passwort darf nicht nur aus Leerzeichen bestehen.")
        if (password != repeated) throw AppFailure("Die beiden Passwörter stimmen nicht überein.")
    }

    /** PBKDF2-HMAC-SHA256 (RFC 8018) on raw bytes. Written out so both platforms encode the password the same way. */
    fun pbkdf2(password: ByteArray, salt: ByteArray, iterations: Int, length: Int = 32): ByteArray {
        require(iterations >= 1 && length > 0 && password.isNotEmpty())
        val mac = Mac.getInstance("HmacSHA256").apply { init(SecretKeySpec(password, "HmacSHA256")) }
        val out = ByteArray(length)
        var block = 1
        var offset = 0
        while (offset < length) {
            mac.update(salt); mac.update(ByteBuffer.allocate(4).putInt(block).array())
            var u = mac.doFinal()
            val t = u.copyOf()
            repeat(iterations - 1) {
                u = mac.doFinal(u)
                for (i in t.indices) t[i] = (t[i].toInt() xor u[i].toInt()).toByte()
            }
            val take = minOf(t.size, length - offset)
            System.arraycopy(t, 0, out, offset, take)
            offset += take; block += 1
        }
        return out
    }

    internal fun header(iterations: Int, salt: ByteArray, chunkBytes: Int): ByteArray =
        ByteBuffer.allocate(HEADER_BYTES).put(MAGIC).put(VERSION).putInt(iterations).put(salt).putInt(chunkBytes).array()

    internal fun nonce(index: Long): ByteArray = ByteBuffer.allocate(12).putInt(0).putLong(index).array()
    internal fun aad(header: ByteArray, index: Long, last: Boolean): ByteArray =
        ByteBuffer.allocate(header.size + 9).put(header).putLong(index).put(if (last) 1 else 0).array()

    /** Encrypting stream. [close] writes the last chunk; without it the file is incomplete and will not open. */
    class Writer(
        private val out: OutputStream,
        password: String,
        iterations: Int = DEFAULT_ITERATIONS,
        salt: ByteArray = ByteArray(16).also { SecureRandom().nextBytes(it) },
        private val chunkBytes: Int = CHUNK_BYTES,
    ) : OutputStream() {
        private val header = header(iterations, salt, chunkBytes)
        private val key = SecretKeySpec(pbkdf2(passwordBytes(password), salt, iterations), "AES")
        private val buffer = ByteArray(chunkBytes)
        private var filled = 0
        private var index = 0L
        private var closed = false

        init { require(salt.size == 16 && chunkBytes in 1..8 * CHUNK_BYTES); out.write(header) }

        override fun write(b: Int) = write(byteArrayOf(b.toByte()), 0, 1)
        override fun write(b: ByteArray, off: Int, len: Int) {
            check(!closed)
            var position = off
            val end = off + len
            while (position < end) {
                if (filled == chunkBytes) emit(last = false)
                val take = minOf(chunkBytes - filled, end - position)
                System.arraycopy(b, position, buffer, filled, take)
                filled += take; position += take
            }
        }

        private fun emit(last: Boolean) {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, key, GCMParameterSpec(TAG_BYTES * 8, nonce(index)))
            cipher.updateAAD(aad(header, index, last))
            val sealed = cipher.doFinal(buffer, 0, filled)
            out.write(ByteBuffer.allocate(4).putInt(sealed.size).array()); out.write(sealed)
            index += 1; filled = 0
        }

        override fun flush() = out.flush()
        override fun close() {
            if (closed) return
            emit(last = true); closed = true
            out.flush(); out.close()
        }
    }

    /** Decrypting stream. Fails on a wrong password, a changed byte, reordered chunks or a cut-off file. */
    class Reader(input: InputStream, password: String) : InputStream() {
        private val data = DataInputStream(input)
        private val header = ByteArray(HEADER_BYTES)
        private val key: SecretKeySpec
        private val chunkBytes: Int
        private var index = 0L
        private var pending: ByteArray? = null
        private var plain = ByteArray(0)
        private var position = 0
        private var finished = false

        init {
            try { data.readFully(header) } catch (_: EOFException) { throw AppFailure("Das ist keine VetMed-Sicherung.") }
            val view = ByteBuffer.wrap(header)
            val magic = ByteArray(4).also { view.get(it) }
            if (!magic.contentEquals(MAGIC)) throw AppFailure("Das ist keine VetMed-Sicherung.")
            if (view.get() != VERSION) throw AppFailure("Diese Sicherung stammt aus einer neueren App-Version. Bitte die App aktualisieren.")
            val iterations = view.getInt()
            val salt = ByteArray(16).also { view.get(it) }
            chunkBytes = view.getInt()
            if (iterations !in 1_000..5_000_000 || chunkBytes !in 1..8 * CHUNK_BYTES) throw AppFailure("Die Sicherung ist beschädigt.")
            key = SecretKeySpec(pbkdf2(passwordBytes(password), salt, iterations), "AES")
            pending = readSealed() ?: throw AppFailure("Die Sicherung ist unvollständig.")
        }

        private fun readSealed(): ByteArray? {
            val length = try { data.readInt() } catch (_: EOFException) { return null }
            if (length !in TAG_BYTES..chunkBytes + TAG_BYTES) throw AppFailure("Die Sicherung ist beschädigt.")
            return ByteArray(length).also {
                try { data.readFully(it) } catch (_: EOFException) { throw AppFailure("Die Sicherung ist unvollständig.") }
            }
        }

        /** Decrypts the next chunk. Looking one chunk ahead tells whether this one must be the last. */
        private fun advance(): Boolean {
            val current = pending ?: return false
            val next = readSealed()
            val last = next == null
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(TAG_BYTES * 8, nonce(index)))
            cipher.updateAAD(aad(header, index, last))
            plain = try { cipher.doFinal(current) } catch (_: GeneralSecurityException) {
                throw AppFailure(
                    when {
                        index == 0L && !last -> "Das Passwort ist falsch oder die Sicherung ist beschädigt."
                        index == 0L -> "Das Passwort ist falsch, oder die Sicherung ist beschädigt oder unvollständig."
                        last -> "Die Sicherung ist unvollständig."
                        else -> "Die Sicherung ist beschädigt."
                    },
                )
            }
            position = 0; index += 1; pending = next
            if (last) finished = true
            return true
        }

        override fun read(): Int {
            val one = ByteArray(1)
            return if (read(one, 0, 1) == -1) -1 else one[0].toInt() and 0xff
        }

        override fun read(b: ByteArray, off: Int, len: Int): Int {
            if (len == 0) return 0
            while (position == plain.size) { if (!advance()) return -1 }
            val take = minOf(len, plain.size - position)
            System.arraycopy(plain, position, b, off, take)
            position += take
            return take
        }

        /** True once the authenticated last chunk was read completely. */
        val complete: Boolean get() = finished && position == plain.size && pending == null
    }
}

/** Named entries inside the encrypted stream: 'E' | name length u16 | name | size u64 | bytes, ended by 'Z'. */
object BackupArchive {
    const val MAX_ENTRY_BYTES = 512L * 1024 * 1024

    class Writer(private val out: OutputStream) {
        fun entry(name: String, bytes: ByteArray) {
            val encoded = name.encodeToByteArray()
            require(encoded.size in 1..1024)
            out.write('E'.code); out.write(ByteBuffer.allocate(2).putShort(encoded.size.toShort()).array()); out.write(encoded)
            out.write(ByteBuffer.allocate(8).putLong(bytes.size.toLong()).array()); out.write(bytes)
        }
        fun finish() { out.write('Z'.code); out.close() }
    }

    class Reader(private val input: BackupFormat.Reader) {
        private val data = DataInputStream(input)
        /** Next entry, or null after the end marker. A missing end marker means the archive was cut off. */
        fun next(): Pair<String, ByteArray>? {
            val tag = data.read()
            return when (tag) {
                'Z'.code -> { if (data.read() != -1 || !input.complete) throw AppFailure("Die Sicherung ist beschädigt."); null }
                'E'.code -> try {
                    val nameLength = data.readUnsignedShort()
                    if (nameLength !in 1..1024) throw AppFailure("Die Sicherung ist beschädigt.")
                    val name = ByteArray(nameLength).also { data.readFully(it) }.decodeToString()
                    val size = data.readLong()
                    if (size !in 0..MAX_ENTRY_BYTES) throw AppFailure("Die Sicherung ist beschädigt.")
                    name to ByteArray(size.toInt()).also { data.readFully(it) }
                } catch (_: EOFException) { throw AppFailure("Die Sicherung ist unvollständig.") }
                -1 -> throw AppFailure("Die Sicherung ist unvollständig.")
                else -> throw AppFailure("Die Sicherung ist beschädigt.")
            }
        }
    }
}

@Serializable
data class BackupManifest(
    val format: String = "vetmed-backup",
    val version: Int = 1,
    val createdAt: AppleDate = now(),
    val platform: String,
    val cases: Int,
    val quickChecks: Int,
    val attachments: Int,
    val recordings: Int,
    val includesAudio: Boolean,
)

/** An encrypted file of the case store, named the same way on both platforms. */
sealed interface BackupFile {
    val name: String
    data class Attachment(val caseID: String?, val encounterID: String, val id: String, val upload: Boolean) : BackupFile {
        override val name get() = "attachment/${caseID ?: "quick"}/$encounterID/$id/${if (upload) "upload" else "original"}"
    }
    data class Audio(val caseID: String, val encounterID: String, val segmentID: String) : BackupFile {
        override val name get() = "audio/$caseID/$encounterID/$segmentID"
    }

    companion object {
        private val id = Regex("[A-Za-z0-9-]{1,64}")
        /** Only well-formed names; anything else (paths, dots) is never turned into a file. */
        fun parse(name: String): BackupFile? {
            val parts = name.split('/')
            if (parts.drop(1).any { !id.matches(it) && it !in setOf("original", "upload") }) return null
            return when {
                parts.size == 5 && parts[0] == "attachment" && parts[4] in setOf("original", "upload") && id.matches(parts[1]) && id.matches(parts[2]) && id.matches(parts[3]) ->
                    Attachment(parts[1].takeUnless { it == "quick" }, parts[2], parts[3], parts[4] == "upload")
                parts.size == 4 && parts[0] == "audio" && parts.drop(1).all { id.matches(it) } -> Audio(parts[1], parts[2], parts[3])
                else -> null
            }
        }
    }
}

object BackupContent {
    const val MANIFEST = "manifest.json"
    const val DOCUMENT = "document.json"
    const val VOCABULARY = "vocabulary.json"

    /** Every encrypted file the document refers to. */
    fun files(document: VaultDocument, includeAudio: Boolean): List<BackupFile> = buildList {
        fun attachments(caseID: String?, encounterID: String, list: List<ChatAttachment>?) = list.orEmpty().forEach {
            add(BackupFile.Attachment(caseID, encounterID, it.id, false))
            if (it.uploadSHA256 != null) add(BackupFile.Attachment(caseID, encounterID, it.id, true))
        }
        document.cases.forEach { item ->
            item.encounters.forEach { encounter ->
                attachments(item.id, encounter.id, encounter.chatAttachments)
                if (includeAudio) encounter.audio.forEach { add(BackupFile.Audio(item.id, encounter.id, it.id)) }
            }
        }
        document.quickChecks.orEmpty().forEach { attachments(null, it.id, it.chatAttachments) }
    }

    fun manifest(document: VaultDocument, includeAudio: Boolean, platform: String): BackupManifest {
        val files = files(document, includeAudio)
        return BackupManifest(
            platform = platform, cases = document.cases.size, quickChecks = document.quickChecks.orEmpty().size,
            attachments = files.count { it is BackupFile.Attachment && !it.upload }, recordings = files.count { it is BackupFile.Audio },
            includesAudio = includeAudio,
        )
    }

    data class Written(val manifest: BackupManifest, val files: Int, val missing: Int)

    /**
     * Writes the whole backup. [read] supplies the plaintext of each encrypted file, or null if it is gone (for
     * example a recording lost in a crash); such a file is left out and counted, the backup still completes.
     */
    fun write(
        out: OutputStream, password: String, document: VaultDocument, vocabulary: List<VocabularyEntry>, includeAudio: Boolean, platform: String,
        iterations: Int = BackupFormat.DEFAULT_ITERATIONS, salt: ByteArray? = null, createdAt: java.time.Instant = now(),
        progress: (done: Int, total: Int) -> Unit = { _, _ -> }, read: (BackupFile) -> ByteArray?,
    ): Written {
        val manifest = manifest(document, includeAudio, platform).copy(createdAt = createdAt)
        val stream = if (salt == null) BackupFormat.Writer(out, password, iterations) else BackupFormat.Writer(out, password, iterations, salt)
        val archive = BackupArchive.Writer(stream)
        archive.entry(MANIFEST, VetJson.encodeToString(BackupManifest.serializer(), manifest).encodeToByteArray())
        archive.entry(DOCUMENT, VetJson.encodeToString(VaultDocument.serializer(), document).encodeToByteArray())
        archive.entry(VOCABULARY, VetJson.encodeToString(ListSerializer(VocabularyEntry.serializer()), vocabulary).encodeToByteArray())
        val files = files(document, includeAudio)
        var missing = 0
        files.forEachIndexed { index, file ->
            val bytes = read(file)
            if (bytes == null) missing += 1 else archive.entry(file.name, bytes)
            progress(index + 1, files.size)
        }
        archive.finish()
        return Written(manifest, files.size - missing, missing)
    }

    /** Rough size before writing: files as stored plus 16-bit mono audio at 16 kHz. Shown to choose about audio. */
    fun estimatedBytes(document: VaultDocument, includeAudio: Boolean): Long {
        val attachments = (document.cases.flatMap { it.encounters }.flatMap { it.chatAttachments.orEmpty() } + document.quickChecks.orEmpty().flatMap { it.chatAttachments.orEmpty() })
            .sumOf { it.originalByteCount.toLong() + (it.uploadByteCount ?: 0) }
        val audio = if (includeAudio) document.cases.flatMap { it.encounters }.flatMap { it.audio }.sumOf { (it.duration * 32_000).toLong() } else 0
        return attachments + audio
    }

    data class Restored(
        val document: VaultDocument,
        val vocabulary: List<VocabularyEntry>,
        val manifest: BackupManifest,
        val addedCases: Int,
        val skippedCases: Int,
        val addedQuickChecks: Int,
        val skippedQuickChecks: Int,
        val files: Int,
        /** Files the restored cases refer to that were not in the backup, e.g. recordings left out. */
        val missingFiles: Int,
    ) {
        val summary: String get() = buildString {
            append(if (addedCases == 1) "1 Fall" else "$addedCases Fälle"); append(" und ")
            append(if (addedQuickChecks == 1) "1 Schnellcheck" else "$addedQuickChecks Schnellchecks"); append(" wiederhergestellt.")
            val skipped = skippedCases + skippedQuickChecks
            if (skipped > 0) append(" $skipped schon vorhanden, unverändert gelassen.")
            if (missingFiles > 0) append(" $missingFiles Dateien waren nicht in der Sicherung" + (if (!manifest.includesAudio) " (Aufnahmen nicht mitgesichert)." else "."))
        }
    }

    /**
     * Reads a backup and merges it into the local cases. Nothing local is overwritten: a case or quick check whose ID
     * already exists stays as it is. [store] receives each file of a newly added case before the caller saves the
     * returned document, so the document never refers to a file that is not there yet.
     */
    fun restore(
        input: InputStream, password: String, local: VaultDocument, localVocabulary: List<VocabularyEntry>,
        store: (BackupFile, ByteArray) -> Unit,
    ): Restored {
        val archive = BackupArchive.Reader(BackupFormat.Reader(input, password))
        fun expect(name: String): ByteArray {
            val (found, bytes) = archive.next() ?: throw AppFailure("Die Sicherung ist unvollständig.")
            if (found != name) throw AppFailure("Die Sicherung ist beschädigt.")
            return bytes
        }
        val manifest: BackupManifest
        val backup: VaultDocument
        val vocabulary: List<VocabularyEntry>
        try {
            manifest = VetJson.decodeFromString(BackupManifest.serializer(), expect(MANIFEST).decodeToString())
            if (manifest.format != "vetmed-backup" || manifest.version != 1) throw AppFailure("Diese Sicherung stammt aus einer neueren App-Version. Bitte die App aktualisieren.")
            backup = VetJson.decodeFromString(VaultDocument.serializer(), expect(DOCUMENT).decodeToString())
            if (backup.schemaVersion != 1) throw AppFailure("Diese Sicherung stammt aus einer neueren App-Version. Bitte die App aktualisieren.")
            vocabulary = VetJson.decodeFromString(ListSerializer(VocabularyEntry.serializer()), expect(VOCABULARY).decodeToString())
        } catch (error: kotlinx.serialization.SerializationException) {
            throw AppFailure("Die Sicherung ist beschädigt.")
        } catch (error: IllegalArgumentException) {
            throw AppFailure("Die Sicherung ist beschädigt.")
        }
        val localCases = local.cases.map { it.id }.toSet()
        val localChecks = local.quickChecks.orEmpty().map { it.id }.toSet()
        val newCases = backup.cases.filter { it.id !in localCases }
        val newChecks = backup.quickChecks.orEmpty().filter { it.id !in localChecks }
        val added = VaultDocument(cases = newCases, quickChecks = newChecks)
        val wanted = files(added, includeAudio = true).map { it.name }.toSet()
        var stored = 0
        while (true) {
            val (name, bytes) = archive.next() ?: break
            if (name !in wanted) continue
            val file = BackupFile.parse(name) ?: continue
            store(file, bytes); stored += 1
        }
        val knownWords = localVocabulary.map { it.recognized.lowercase() }.toSet()
        val knownIDs = localVocabulary.map { it.id }.toSet()
        val mergedVocabulary = localVocabulary + vocabulary.filter { it.id !in knownIDs && it.recognized.lowercase() !in knownWords }
        val document = local.copy(cases = local.cases + newCases, quickChecks = (local.quickChecks.orEmpty() + newChecks).ifEmpty { null })
        return Restored(
            document, mergedVocabulary, manifest, newCases.size, backup.cases.size - newCases.size,
            newChecks.size, backup.quickChecks.orEmpty().size - newChecks.size, stored, wanted.size - stored,
        )
    }
}
