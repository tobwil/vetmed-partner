package de.tobwil.vetmed.data

import android.content.Context
import android.database.sqlite.SQLiteException
import android.database.sqlite.SQLiteFullException
import androidx.room.Room
import androidx.room.RoomDatabase
import androidx.sqlite.db.SupportSQLiteDatabase
import de.tobwil.vetmed.core.AppFailure
import de.tobwil.vetmed.core.Encounter
import de.tobwil.vetmed.core.OnlineReportConfiguration
import de.tobwil.vetmed.core.ReportVersion
import de.tobwil.vetmed.core.ShareEvent
import de.tobwil.vetmed.core.TranscriptVersion
import de.tobwil.vetmed.core.VaultDocument
import de.tobwil.vetmed.core.VetCase
import de.tobwil.vetmed.core.VetJson
import de.tobwil.vetmed.core.VocabularyEntry
import de.tobwil.vetmed.core.validateApiKey
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.KSerializer
import kotlinx.serialization.builtins.ListSerializer
import net.zetetic.database.sqlcipher.SupportOpenHelperFactory
import java.io.File
import java.security.SecureRandom

/** Opens the case database. Production uses SQLCipher; JVM tests substitute plain SQLite on Robolectric. */
fun interface DatabaseOpener {
    fun open(context: Context, file: File, passphrase: ByteArray): CaseDatabase
}

object SqlCipherOpener : DatabaseOpener {
    override fun open(context: Context, file: File, passphrase: ByteArray): CaseDatabase {
        System.loadLibrary("sqlcipher")
        return Room.databaseBuilder(context, CaseDatabase::class.java, file.absolutePath)
            .openHelperFactory(SupportOpenHelperFactory(passphrase))
            .addCallback(SecureDeleteCallback)
            .build()
    }
}

/** Overwrite deleted content instead of leaving it in free pages. */
object SecureDeleteCallback : RoomDatabase.Callback() {
    override fun onOpen(db: SupportSQLiteDatabase) { db.query("PRAGMA secure_delete = ON").use { it.moveToFirst() } }
}

/**
 * Cases and vocabulary live in a Room database encrypted with SQLCipher (same tables as iOS). Its random
 * passphrase is sealed with a Keystore key. The API key and online settings stay in separately sealed files
 * under another Keystore key, like the iOS Keychain entries. All access runs off the main thread.
 */
class VaultRepository(
    private val context: Context,
    private val root: File,
    private val dataKeys: KeySource,
    secretKeys: KeySource,
    private val opener: DatabaseOpener = SqlCipherOpener,
    /** Refuse to run on a database that is not actually encrypted. Only JVM tests turn this off. */
    private val requireCipher: Boolean = true,
) {
    private val databaseFile = File(root, "cases.db")
    private val databaseKey = SealedFile(File(root, "database-key.v1.sealed"), dataKeys, "vetmed/database-key/v1")
    private val legacyCases = SealedFile(File(root, "cases.v1.sealed"), dataKeys, "vetmed/cases/v1")
    private val legacyVocabulary = SealedFile(File(root, "vocabulary.v1.sealed"), dataKeys, "vetmed/vocabulary/v1")
    private val apiKey = SealedFile(File(root, "secrets/provider.openai.api-key.sealed"), secretKeys, "vetmed/provider.openai.api-key")
    private val onlineConfiguration = SealedFile(File(root, "secrets/online-report-configuration.v1.sealed"), secretKeys, "vetmed/online-report-configuration/v1")
    private val mutex = Mutex()
    private var database: CaseDatabase? = null

    suspend fun load(): VaultDocument = io {
        try { read(dao()) } catch (error: kotlinx.serialization.SerializationException) {
            throw AppFailure("Gespeicherte Falldaten konnten nicht gelesen werden. Sie werden nicht überschrieben.")
        }
    }

    suspend fun save(document: VaultDocument) = io {
        if (document.schemaVersion != 1) throw AppFailure("Unbekannte Speicherversion.")
        write(dao(), document)
    }

    suspend fun vocabulary(): List<VocabularyEntry> = io {
        dao().vocabulary().map { decode(VocabularyEntry.serializer(), it.payload) }
    }

    suspend fun saveVocabulary(entries: List<VocabularyEntry>) = io {
        val rows = entries.mapIndexed { position, entry -> VocabularyRow(entry.id, position, encode(VocabularyEntry.serializer(), entry)) }
        guarded { dao().replaceVocabulary(rows) }
    }

    suspend fun verifyIntegrity() = io {
        dao()
        val db = database!!.openHelper.writableDatabase
        if (requireCipher) db.query("PRAGMA cipher_integrity_check").use { if (it.moveToFirst()) throw AppFailure("Die verschlüsselte Datenbank ist beschädigt.") }
        db.query("PRAGMA integrity_check").use { if (!it.moveToFirst() || it.getString(0) != "ok") throw AppFailure("Die verschlüsselte Datenbank ist beschädigt.") }
    }

    suspend fun onlineConfiguration(): OnlineReportConfiguration = io {
        onlineConfiguration.read()?.let { decode(OnlineReportConfiguration.serializer(), it) } ?: OnlineReportConfiguration()
    }

    suspend fun saveOnline(configuration: OnlineReportConfiguration, key: String? = null) = io {
        key?.let { validateApiKey(it); apiKey.write(it.encodeToByteArray()) }
        onlineConfiguration.write(encode(OnlineReportConfiguration.serializer(), configuration))
    }

    suspend fun apiKey(): String? = io { apiKey.read()?.decodeToString() }

    suspend fun removeApiKey(configuration: OnlineReportConfiguration) = io {
        onlineConfiguration.write(encode(OnlineReportConfiguration.serializer(), configuration))
        apiKey.delete()
    }

    suspend fun close() = io { database?.close(); database = null }

    // Opening ---------------------------------------------------------------------------------------

    private fun dao(): CaseDao = (database ?: open().also { database = it }).cases()

    private fun open(): CaseDatabase {
        root.mkdirs()
        val passphrase = databaseKey.read() ?: run {
            if (databaseFile.exists()) throw AppFailure("Der Schlüssel zu vorhandenen Daten fehlt. Daten werden nicht überschrieben.")
            ByteArray(32).also { SecureRandom().nextBytes(it); databaseKey.write(it) }
        }
        val opened = opener.open(context, databaseFile, passphrase)
        try {
            val db = opened.openHelper.writableDatabase
            if (requireCipher) {
                val version = db.query("PRAGMA cipher_version").use { if (it.moveToFirst()) it.getString(0) else null }
                if (version.isNullOrEmpty()) throw AppFailure("SQLCipher ist nicht aktiv. Kein unverschlüsselter Fallspeicher wird angelegt.")
            }
            migrateLegacy(opened.cases())
            return opened
        } catch (error: AppFailure) {
            opened.close()
            throw error
        } catch (error: RuntimeException) {
            // Wrong passphrase, foreign or damaged file: SQLCipher refuses to open it and nothing is overwritten.
            opened.close()
            throw AppFailure("Die verschlüsselte Datenbank konnte nicht geöffnet werden. Sie wird nicht überschrieben.")
        }
    }

    /** Moves data from the first Android version (one sealed file) into the database, verified before deletion. */
    private fun migrateLegacy(dao: CaseDao) {
        legacyCases.read()?.let { bytes ->
            val document = decode(VaultDocument.serializer(), bytes)
            if (dao.caseCount() == 0) write(dao, document)
            if (read(dao) != document) throw AppFailure("Migration konnte nicht vollständig bestätigt werden. Die alte verschlüsselte Datei bleibt erhalten.")
            legacyCases.delete()
        }
        legacyVocabulary.read()?.let { bytes ->
            val entries = decode(ListSerializer(VocabularyEntry.serializer()), bytes)
            if (dao.vocabulary().isEmpty()) {
                dao.replaceVocabulary(entries.mapIndexed { position, entry -> VocabularyRow(entry.id, position, encode(VocabularyEntry.serializer(), entry)) })
            }
            legacyVocabulary.delete()
        }
    }

    // Mapping ---------------------------------------------------------------------------------------

    private fun read(dao: CaseDao): VaultDocument {
        val rows = dao.snapshot()
        val transcripts = rows.transcripts.groupBy { it.encounterID }
        val reports = rows.reports.groupBy { it.encounterID }
        val shares = rows.shares.groupBy { it.encounterID }
        val encounters = rows.encounters.groupBy { it.caseID }
        return VaultDocument(cases = rows.cases.map { caseRow ->
            decode(VetCase.serializer(), caseRow.payload).copy(encounters = encounters[caseRow.id].orEmpty().map { row ->
                decode(Encounter.serializer(), row.payload).copy(
                    transcripts = transcripts[row.id].orEmpty().map { decode(TranscriptVersion.serializer(), it.payload) },
                    reports = reports[row.id].orEmpty().map { decode(ReportVersion.serializer(), it.payload) },
                    shares = shares[row.id].orEmpty().map { decode(ShareEvent.serializer(), it.payload) },
                )
            })
        })
    }

    private fun write(dao: CaseDao, document: VaultDocument) {
        val encounters = mutableListOf<EncounterRow>()
        val transcripts = mutableListOf<TranscriptRow>()
        val reports = mutableListOf<ReportRow>()
        val shares = mutableListOf<ShareRow>()
        val cases = document.cases.mapIndexed { position, item ->
            item.encounters.forEachIndexed { index, encounter ->
                val stripped = encounter.copy(transcripts = emptyList(), reports = emptyList(), shares = emptyList())
                encounters += EncounterRow(encounter.id, item.id, index, encode(Encounter.serializer(), stripped))
                encounter.transcripts.forEachIndexed { n, value -> transcripts += TranscriptRow(value.id, encounter.id, n, encode(TranscriptVersion.serializer(), value)) }
                encounter.reports.forEachIndexed { n, value -> reports += ReportRow(value.id, encounter.id, n, encode(ReportVersion.serializer(), value)) }
                encounter.shares.forEachIndexed { n, value -> shares += ShareRow(value.id, encounter.id, n, encode(ShareEvent.serializer(), value)) }
            }
            CaseRow(item.id, position, encode(VetCase.serializer(), item.copy(encounters = emptyList())))
        }
        guarded { dao.replaceAll(CaseRows(cases, encounters, transcripts, reports, shares)) }
    }

    private fun guarded(block: () -> Unit) {
        try { block() } catch (error: SQLiteFullException) {
            throw AppFailure("Der Gerätespeicher ist voll. Die letzte gespeicherte Fassung bleibt erhalten. Bitte Speicher freigeben und erneut speichern.")
        } catch (error: SQLiteException) {
            throw AppFailure("Speichern fehlgeschlagen. Die letzte gespeicherte Fassung bleibt erhalten.")
        }
    }

    private fun <T> encode(serializer: KSerializer<T>, value: T) = VetJson.encodeToString(serializer, value).encodeToByteArray()
    private fun <T> decode(serializer: KSerializer<T>, bytes: ByteArray) = VetJson.decodeFromString(serializer, bytes.decodeToString())

    private suspend fun <T> io(block: () -> T): T = mutex.withLock { withContext(Dispatchers.IO) { block() } }
}
