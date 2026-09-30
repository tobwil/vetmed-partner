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

class CaseRows(
    val cases: List<CaseRow>,
    val encounters: List<EncounterRow>,
    val transcripts: List<TranscriptRow>,
    val reports: List<ReportRow>,
    val shares: List<ShareRow>,
)

@Dao
abstract class CaseDao {
    @Query("SELECT * FROM clinical_case ORDER BY position") abstract fun cases(): List<CaseRow>
    @Query("SELECT * FROM encounter ORDER BY caseID, position") abstract fun encounters(): List<EncounterRow>
    @Query("SELECT * FROM transcript_version ORDER BY encounterID, position") abstract fun transcripts(): List<TranscriptRow>
    @Query("SELECT * FROM report_version ORDER BY encounterID, position") abstract fun reports(): List<ReportRow>
    @Query("SELECT * FROM share_event ORDER BY encounterID, position") abstract fun shares(): List<ShareRow>
    @Query("SELECT * FROM vocabulary ORDER BY position") abstract fun vocabulary(): List<VocabularyRow>
    @Query("SELECT COUNT(*) FROM clinical_case") abstract fun caseCount(): Int

    @Query("DELETE FROM share_event") protected abstract fun clearShares()
    @Query("DELETE FROM report_version") protected abstract fun clearReports()
    @Query("DELETE FROM transcript_version") protected abstract fun clearTranscripts()
    @Query("DELETE FROM encounter") protected abstract fun clearEncounters()
    @Query("DELETE FROM clinical_case") protected abstract fun clearCases()
    @Query("DELETE FROM vocabulary") protected abstract fun clearVocabulary()
    @Insert protected abstract fun insertCases(rows: List<CaseRow>)
    @Insert protected abstract fun insertEncounters(rows: List<EncounterRow>)
    @Insert protected abstract fun insertTranscripts(rows: List<TranscriptRow>)
    @Insert protected abstract fun insertReports(rows: List<ReportRow>)
    @Insert protected abstract fun insertShares(rows: List<ShareRow>)
    @Insert protected abstract fun insertVocabulary(rows: List<VocabularyRow>)

    /** All reads in one transaction, so a concurrent save can never produce a mixed document. */
    @Transaction
    open fun snapshot(): CaseRows = CaseRows(cases(), encounters(), transcripts(), reports(), shares())

    /** All-or-nothing replacement, including every version and share event (iOS does the same). */
    @Transaction
    open fun replaceAll(rows: CaseRows) {
        clearShares(); clearReports(); clearTranscripts(); clearEncounters(); clearCases()
        insertCases(rows.cases); insertEncounters(rows.encounters)
        insertTranscripts(rows.transcripts); insertReports(rows.reports); insertShares(rows.shares)
    }

    @Transaction
    open fun replaceVocabulary(rows: List<VocabularyRow>) { clearVocabulary(); insertVocabulary(rows) }
}

@Database(
    entities = [CaseRow::class, EncounterRow::class, TranscriptRow::class, ReportRow::class, ShareRow::class, VocabularyRow::class],
    version = 1,
    exportSchema = true,
)
abstract class CaseDatabase : RoomDatabase() {
    abstract fun cases(): CaseDao
}
