package de.tobwil.vetmed

import de.tobwil.vetmed.core.AnalysisRun
import de.tobwil.vetmed.core.AnalysisStatus
import de.tobwil.vetmed.core.Audience
import de.tobwil.vetmed.core.ChatOperations
import de.tobwil.vetmed.core.SparringDraft
import de.tobwil.vetmed.core.SparringRequestBuilder
import de.tobwil.vetmed.core.CaseOperations
import de.tobwil.vetmed.core.CaseOperations.mapCase
import de.tobwil.vetmed.core.CaseOperations.mapEncounter
import de.tobwil.vetmed.core.EncounterLocation
import de.tobwil.vetmed.core.EncounterState
import de.tobwil.vetmed.core.ModelReportDraft
import de.tobwil.vetmed.core.ReportLength
import de.tobwil.vetmed.core.ReportTemplate
import de.tobwil.vetmed.core.ReportValidator
import de.tobwil.vetmed.core.ReportVersion
import de.tobwil.vetmed.core.VaultDocument
import android.content.Context
import androidx.room.Room
import androidx.sqlite.db.framework.FrameworkSQLiteOpenHelperFactory
import de.tobwil.vetmed.data.CaseDatabase
import de.tobwil.vetmed.data.DatabaseOpener
import de.tobwil.vetmed.data.KeySource
import de.tobwil.vetmed.data.SecureDeleteCallback
import de.tobwil.vetmed.data.VaultRepository
import java.io.File
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey

/** Software AES key in place of the Android Keystore, which Robolectric and the JVM do not provide. */
class MemoryKeys(var key: SecretKey? = null) : KeySource {
    var created = 0
    override fun existing() = key
    override fun create(): SecretKey = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey().also { key = it; created += 1 }
}

/**
 * Same Room schema on Robolectric's plain SQLite. SQLCipher is an Android native library and cannot load
 * on the JVM; its encryption is covered by the instrumented test in androidTest.
 */
val PlainSqliteOpener = DatabaseOpener { context, file, _ ->
    Room.databaseBuilder(context, CaseDatabase::class.java, file.absolutePath)
        .openHelperFactory(FrameworkSQLiteOpenHelperFactory())
        .addMigrations(*CaseDatabase.MIGRATIONS)
        .addCallback(SecureDeleteCallback)
        .build()
}

fun testRepository(context: Context, root: File, data: KeySource, secrets: KeySource) =
    VaultRepository(context, root, data, secrets, PlainSqliteOpener, requireCipher = false)

/** Synthetic cases only. No real animals, owners or findings. */
object SyntheticCases {
    data class Seeded(val document: VaultDocument, val withReport: EncounterLocation, val reportID: String)

    private fun verbatimReport(document: VaultDocument, location: EncounterLocation, section: String): ReportVersion {
        val transcript = CaseOperations.encounter(document, location)!!.transcripts.last()
        val content = ModelReportDraft(transcript.segments.map { ModelReportDraft.Item(section, it.text.trim(), it.id, it.text.trim()) })
            .report(transcript.id, ReportTemplate.TREATMENT_REPORT, ReportLength.MEDIUM, Audience.VETERINARIAN)
        return ReportVersion(content = content, modelID = "openai/synthetic-model", modelRevision = "synthetic-snapshot-1", warnings = ReportValidator.validate(content, transcript))
    }

    fun seed(): Seeded {
        var document = VaultDocument()
        val (d1, luna) = CaseOperations.newEncounter(document)!!
        document = CaseOperations.updateCase(d1, luna.caseID, "K-2026-011", "Kaninchen", "Luna")
        document = CaseOperations.saveTranscript(document, luna, "Kaninchen 1,8 kg. Kein Durchfall. Kontrolle in 7 Tagen.")
        val lunaReport = verbatimReport(document, luna, "Befunde")
        document = document.mapEncounter(luna) { it.copy(reports = listOf(lunaReport), state = EncounterState.REVIEW_REQUIRED) }
        document = CaseOperations.approve(document, luna, lunaReport.id)

        val (d2, mia) = CaseOperations.newEncounter(document)!!
        document = CaseOperations.updateCase(d2, mia.caseID, "K-2026-013", "Katze", "Mia")
        document = CaseOperations.saveTranscript(document, mia, "Katze. Temperatur nicht gemessen. Appetit unverändert.")

        val (d3, bello) = CaseOperations.newEncounter(document)!!
        document = CaseOperations.updateCase(d3, bello.caseID, "K-2026-014", "Hund", "Bello")
        document = CaseOperations.saveTranscript(document, bello, "Hund 12,5 kg. Kein Fieber. Lahmheit hinten links. Kontrolle in 3 Tagen.")
        val belloReport = verbatimReport(document, bello, "Befunde")
        document = document.mapEncounter(bello) { it.copy(reports = listOf(belloReport), state = EncounterState.REVIEW_REQUIRED) }
        // A completed case chat with a formatted answer, and a standalone quick check.
        val encounter = CaseOperations.encounter(document, bello)!!
        val caseItem = document.cases.first { it.id == bello.caseID }
        val snapshot = SparringRequestBuilder.prepare(
            bello.caseID, encounter, SparringDraft(question = "Welche Differenzialdiagnosen bei Lahmheit hinten links?", reportIDs = listOf(belloReport.id)),
            "synthetic-model", caseItem, instructions = "test",
        )
        val answer = "## Mögliche Ursachen\n\n- **Kreuzbandriss** – häufig bei plötzlicher Lahmheit\n- **Patellaluxation** – eher bei kleinen Rassen\n- *Pfotenverletzung* – Ballen prüfen\n\nSinnvoll sind Palpation und ggf. Röntgen."
        document = document.mapEncounter(bello) { it.copy(analysisRuns = listOf(AnalysisRun(snapshot = snapshot, status = AnalysisStatus.COMPLETED, text = answer, actualModelID = "synthetic-model-snapshot"))) }
        val (withCheck, chat) = ChatOperations.newQuickCheck(document)
        document = ChatOperations.saveDraft(withCheck, chat, SparringDraft(question = "Allgemeine Frage zur Impfung"))
        return Seeded(document, bello, belloReport.id)
    }
}
