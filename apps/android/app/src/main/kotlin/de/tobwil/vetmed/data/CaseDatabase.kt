package de.tobwil.vetmed.data

import androidx.room.Dao
import androidx.room.Database
import androidx.room.Entity
import androidx.room.ForeignKey
import androidx.room.Index
import androidx.room.Insert
import androidx.room.PrimaryKey
import androidx.room.Query
import androidx.room.RoomDatabase
import androidx.room.Transaction
import androidx.room.Update
import androidx.room.migration.Migration
import androidx.sqlite.db.SupportSQLiteDatabase

/*
 * Same layout as the iOS SQLCipher schema: one row per case, encounter and version, each with a JSON
 * payload. Positions keep the user's order. Everything clinical is inside the SQLCipher-encrypted file.
 */

@Entity(tableName = "clinical_case")
class CaseRow(@PrimaryKey val id: String, val position: Int, val payload: ByteArray)

@Entity(
    tableName = "encounter",
    foreignKeys = [ForeignKey(CaseRow::class, ["id"], ["caseID"], onDelete = ForeignKey.CASCADE)],
    indices = [Index("caseID")],
)
class EncounterRow(@PrimaryKey val id: String, val caseID: String, val position: Int, val payload: ByteArray)

@Entity(
    tableName = "transcript_version",
    foreignKeys = [ForeignKey(EncounterRow::class, ["id"], ["encounterID"], onDelete = ForeignKey.CASCADE)],
    indices = [Index("encounterID")],
)
class TranscriptRow(@PrimaryKey val id: String, val encounterID: String, val position: Int, val payload: ByteArray)

@Entity(
    tableName = "report_version",
    foreignKeys = [ForeignKey(EncounterRow::class, ["id"], ["encounterID"], onDelete = ForeignKey.CASCADE)],
    indices = [Index("encounterID")],
)
class ReportRow(@PrimaryKey val id: String, val encounterID: String, val position: Int, val payload: ByteArray)

@Entity(
    tableName = "share_event",
    foreignKeys = [ForeignKey(EncounterRow::class, ["id"], ["encounterID"], onDelete = ForeignKey.CASCADE)],
    indices = [Index("encounterID")],
)
class ShareRow(@PrimaryKey val id: String, val encounterID: String, val position: Int, val payload: ByteArray)

@Entity(tableName = "vocabulary")
class VocabularyRow(@PrimaryKey val id: String, val position: Int, val payload: ByteArray)

/** Standalone chats without a clinical case, stored apart from cases like on iOS. */
@Entity(tableName = "quick_check")
class QuickCheckRow(@PrimaryKey val id: String, val position: Int, val payload: ByteArray)

class CaseRows(
    val cases: List<CaseRow>,
    val encounters: List<EncounterRow>,
    val transcripts: List<TranscriptRow>,
    val reports: List<ReportRow>,
    val shares: List<ShareRow>,
    val quickChecks: List<QuickCheckRow> = emptyList(),
) {
    val size: Int get() = cases.size + encounters.size + transcripts.size + reports.size + shares.size + quickChecks.size
}

/** The tables of the case store, children after their parents. */
enum class CaseTable { CASE, ENCOUNTER, TRANSCRIPT, REPORT, SHARE, QUICK_CHECK }

/** What is stored for one row, without its content: parent, position and a SHA-256 of the payload. */
data class RowState(val parent: String?, val position: Int, val digest: String)

typealias RowSnapshot = Map<CaseTable, Map<String, RowState>>

/**
 * The difference between what the database holds and the next document: only these rows are written. A save
 * during a streaming chat answer then touches one encounter row instead of every case, version and share.
 */
class RowChanges(val inserts: CaseRows, val updates: CaseRows, val deletions: Map<CaseTable, List<String>>) {
    val isEmpty: Boolean get() = inserts.size == 0 && updates.size == 0 && deletions.values.all { it.isEmpty() }

    companion object {
        private fun digest(payload: ByteArray): String =
            java.util.Base64.getEncoder().encodeToString(java.security.MessageDigest.getInstance("SHA-256").digest(payload))

        fun snapshot(rows: CaseRows): RowSnapshot = mapOf(
            CaseTable.CASE to rows.cases.associate { it.id to RowState(null, it.position, digest(it.payload)) },
            CaseTable.ENCOUNTER to rows.encounters.associate { it.id to RowState(it.caseID, it.position, digest(it.payload)) },
            CaseTable.TRANSCRIPT to rows.transcripts.associate { it.id to RowState(it.encounterID, it.position, digest(it.payload)) },
            CaseTable.REPORT to rows.reports.associate { it.id to RowState(it.encounterID, it.position, digest(it.payload)) },
            CaseTable.SHARE to rows.shares.associate { it.id to RowState(it.encounterID, it.position, digest(it.payload)) },
            CaseTable.QUICK_CHECK to rows.quickChecks.associate { it.id to RowState(null, it.position, digest(it.payload)) },
        )

        fun between(previous: RowSnapshot, rows: CaseRows, next: RowSnapshot): RowChanges {
            fun <R> split(table: CaseTable, list: List<R>, id: (R) -> String): Pair<List<R>, List<R>> {
                val before = previous[table].orEmpty(); val after = next.getValue(table)
                val changed = list.filter { before[id(it)] != after[id(it)] }
                return changed.partition { id(it) !in before }
            }
            val cases = split(CaseTable.CASE, rows.cases) { it.id }
            val encounters = split(CaseTable.ENCOUNTER, rows.encounters) { it.id }
            val transcripts = split(CaseTable.TRANSCRIPT, rows.transcripts) { it.id }
            val reports = split(CaseTable.REPORT, rows.reports) { it.id }
            val shares = split(CaseTable.SHARE, rows.shares) { it.id }
            val quickChecks = split(CaseTable.QUICK_CHECK, rows.quickChecks) { it.id }
            return RowChanges(
                inserts = CaseRows(cases.first, encounters.first, transcripts.first, reports.first, shares.first, quickChecks.first),
                updates = CaseRows(cases.second, encounters.second, transcripts.second, reports.second, shares.second, quickChecks.second),
                deletions = CaseTable.entries.associateWith { table -> (previous[table].orEmpty().keys - next.getValue(table).keys).toList() },
            )
        }
    }
}

@Dao
abstract class CaseDao {
    @Query("SELECT * FROM clinical_case ORDER BY position") abstract fun cases(): List<CaseRow>
    @Query("SELECT * FROM encounter ORDER BY caseID, position") abstract fun encounters(): List<EncounterRow>
    @Query("SELECT * FROM transcript_version ORDER BY encounterID, position") abstract fun transcripts(): List<TranscriptRow>
    @Query("SELECT * FROM report_version ORDER BY encounterID, position") abstract fun reports(): List<ReportRow>
    @Query("SELECT * FROM share_event ORDER BY encounterID, position") abstract fun shares(): List<ShareRow>
    @Query("SELECT * FROM vocabulary ORDER BY position") abstract fun vocabulary(): List<VocabularyRow>
    @Query("SELECT * FROM quick_check ORDER BY position") abstract fun quickChecks(): List<QuickCheckRow>
    @Query("SELECT COUNT(*) FROM clinical_case") abstract fun caseCount(): Int

    @Query("DELETE FROM share_event") protected abstract fun clearShares()
    @Query("DELETE FROM report_version") protected abstract fun clearReports()
    @Query("DELETE FROM transcript_version") protected abstract fun clearTranscripts()
    @Query("DELETE FROM encounter") protected abstract fun clearEncounters()
    @Query("DELETE FROM clinical_case") protected abstract fun clearCases()
    @Query("DELETE FROM vocabulary") protected abstract fun clearVocabulary()
    @Query("DELETE FROM quick_check") protected abstract fun clearQuickChecks()
    @Insert protected abstract fun insertCases(rows: List<CaseRow>)
    @Insert protected abstract fun insertEncounters(rows: List<EncounterRow>)
    @Insert protected abstract fun insertTranscripts(rows: List<TranscriptRow>)
    @Insert protected abstract fun insertReports(rows: List<ReportRow>)
    @Insert protected abstract fun insertShares(rows: List<ShareRow>)
    @Insert protected abstract fun insertVocabulary(rows: List<VocabularyRow>)
    @Insert protected abstract fun insertQuickChecks(rows: List<QuickCheckRow>)
    @Update protected abstract fun updateCases(rows: List<CaseRow>): Int
    @Update protected abstract fun updateEncounters(rows: List<EncounterRow>): Int
    @Update protected abstract fun updateTranscripts(rows: List<TranscriptRow>): Int
    @Update protected abstract fun updateReports(rows: List<ReportRow>): Int
    @Update protected abstract fun updateShares(rows: List<ShareRow>): Int
    @Update protected abstract fun updateQuickChecks(rows: List<QuickCheckRow>): Int
    @Query("DELETE FROM clinical_case WHERE id IN (:ids)") protected abstract fun deleteCases(ids: List<String>)
    @Query("DELETE FROM encounter WHERE id IN (:ids)") protected abstract fun deleteEncounters(ids: List<String>)
    @Query("DELETE FROM transcript_version WHERE id IN (:ids)") protected abstract fun deleteTranscripts(ids: List<String>)
    @Query("DELETE FROM report_version WHERE id IN (:ids)") protected abstract fun deleteReports(ids: List<String>)
    @Query("DELETE FROM share_event WHERE id IN (:ids)") protected abstract fun deleteShares(ids: List<String>)
    @Query("DELETE FROM quick_check WHERE id IN (:ids)") protected abstract fun deleteQuickChecks(ids: List<String>)

    /** All reads in one transaction, so a concurrent save can never produce a mixed document. */
    @Transaction
    open fun snapshot(): CaseRows = CaseRows(cases(), encounters(), transcripts(), reports(), shares(), quickChecks())

    /** All-or-nothing replacement, including every version and share event (iOS does the same). */
    @Transaction
    open fun replaceAll(rows: CaseRows) {
        clearShares(); clearReports(); clearTranscripts(); clearEncounters(); clearCases(); clearQuickChecks()
        insertCases(rows.cases); insertEncounters(rows.encounters)
        insertTranscripts(rows.transcripts); insertReports(rows.reports); insertShares(rows.shares)
        insertQuickChecks(rows.quickChecks)
    }

    /**
     * Writes only the difference, still all-or-nothing. Updates never delete a row first, so ON DELETE CASCADE
     * cannot remove versions of an unchanged encounter. Children are deleted before and inserted after parents.
     */
    @Transaction
    open fun applyChanges(changes: RowChanges) {
        fun delete(table: CaseTable, action: (List<String>) -> Unit) = changes.deletions[table].orEmpty().chunked(500).forEach(action)
        delete(CaseTable.SHARE, ::deleteShares); delete(CaseTable.REPORT, ::deleteReports); delete(CaseTable.TRANSCRIPT, ::deleteTranscripts)
        delete(CaseTable.ENCOUNTER, ::deleteEncounters); delete(CaseTable.CASE, ::deleteCases); delete(CaseTable.QUICK_CHECK, ::deleteQuickChecks)
        with(changes.inserts) { insertCases(cases); insertEncounters(encounters); insertTranscripts(transcripts); insertReports(reports); insertShares(shares); insertQuickChecks(quickChecks) }
        val updated = with(changes.updates) {
            updateCases(cases) + updateEncounters(encounters) + updateTranscripts(transcripts) + updateReports(reports) + updateShares(shares) + updateQuickChecks(quickChecks)
        }
        // A row that should exist but does not means the known state is wrong: roll back and let the caller write everything.
        if (updated != changes.updates.size) throw android.database.sqlite.SQLiteException("Gespeicherter Stand weicht ab ($updated von ${changes.updates.size}).")
    }

    @Transaction
    open fun replaceVocabulary(rows: List<VocabularyRow>) { clearVocabulary(); insertVocabulary(rows) }
}

@Database(
    entities = [CaseRow::class, EncounterRow::class, TranscriptRow::class, ReportRow::class, ShareRow::class, VocabularyRow::class, QuickCheckRow::class],
    version = 2,
    exportSchema = true,
)
abstract class CaseDatabase : RoomDatabase() {
    abstract fun cases(): CaseDao

    companion object {
        /** Version 2 adds standalone chats. Existing cases are untouched. */
        val MIGRATION_1_2 = object : Migration(1, 2) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("CREATE TABLE IF NOT EXISTS `quick_check` (`id` TEXT NOT NULL, `position` INTEGER NOT NULL, `payload` BLOB NOT NULL, PRIMARY KEY(`id`))")
            }
        }
        val MIGRATIONS = arrayOf(MIGRATION_1_2)
    }
}
