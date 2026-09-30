package de.tobwil.vetmed.core

import de.tobwil.vetmed.core.CaseOperations.mapEncounter
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class CaseOperationsTests {
    private fun report(transcript: TranscriptVersion) = ReportVersion(
        content = ModelReportDraft(listOf(ModelReportDraft.Item("Befunde", transcript.editedText, transcript.segments[0].id, transcript.editedText)))
            .report(transcript.id, ReportTemplate.TREATMENT_REPORT, ReportLength.MEDIUM, Audience.VETERINARIAN),
        modelID = "synthetic", modelRevision = "synthetic", warnings = emptyList(),
    )

    @Test fun newDictationCreatesCaseFirstAndKeepsExistingCases() {
        val (first, a) = CaseOperations.newEncounter(VaultDocument())!!
        val (second, b) = CaseOperations.newEncounter(first)!!
        assertEquals(listOf("Fall 2", "Fall 1"), second.cases.map { it.label })
        assertNotEquals(a.caseID, b.caseID)
        val (third, c) = CaseOperations.newEncounter(second, a.caseID)!!
        assertEquals(a.caseID, c.caseID)
        assertEquals(2, third.cases.first { it.id == a.caseID }.encounters.size)
        assertNull(CaseOperations.newEncounter(third, "missing"))
    }

    @Test fun unchangedTextAddsNoVersionAndEditsKeepRawText() {
        val (document, location) = CaseOperations.newEncounter(VaultDocument())!!
        val once = CaseOperations.saveTranscript(document, location, "Hund 12,5 kg. Kein Fieber.")
        assertSame(once, CaseOperations.saveTranscript(once, location, "Hund 12,5 kg. Kein Fieber."))
        val twice = CaseOperations.saveTranscript(once, location, "Hund 12,5 kg. Kein Fieber. Kontrolle in 3 Tagen.")
        val versions = CaseOperations.encounter(twice, location)!!.transcripts
        assertEquals(2, versions.size)
        assertEquals("Hund 12,5 kg. Kein Fieber.", versions[1].rawText)
        assertEquals(versions[0].id, versions[1].parentID)
        assertEquals(EncounterState.TRANSCRIPT_READY, CaseOperations.encounter(twice, location)!!.state)
    }

    @Test fun editedReportBecomesNewUnapprovedVersionWithWarning() {
        val (base, location) = CaseOperations.newEncounter(VaultDocument())!!
        val withText = CaseOperations.saveTranscript(base, location, "Kein Fieber.")
        val transcript = CaseOperations.encounter(withText, location)!!.transcripts.last()
        val original = report(transcript)
        val withReport = with(CaseOperations) { withText.mapEncounter(location) { it.copy(reports = listOf(original)) } }
        val approved = CaseOperations.approve(withReport, location, original.id)
        assertNotNull(CaseOperations.encounter(approved, location)!!.reports.single().approvedAt)
        val edited = CaseOperations.saveReportEdit(approved, location, original.id, "Kein Fieber. Ergänzt.")
        val reports = CaseOperations.encounter(edited, location)!!.reports
        assertEquals(2, reports.size)
        assertNull(reports[1].approvedAt)
        assertEquals(original.id, reports[1].parentID)
        assertTrue(reports[1].warnings.single().contains("Manuell bearbeitet"))
        assertTrue(reports[1].exportText.startsWith("ENTWURF"))
    }

    @Test fun sharesAreOnlyRecordedForReportsOfThatEncounter() {
        val (document, location) = CaseOperations.newEncounter(VaultDocument())!!
        val unchanged = CaseOperations.recordShare(document, location, "unknown", "Text")
        assertTrue(CaseOperations.encounter(unchanged, location)!!.shares.isEmpty())
    }

    @Test fun deletingOneCaseKeepsOthersAndBlankLabelIsRejected() {
        val (one, a) = CaseOperations.newEncounter(VaultDocument())!!
        val (two, b) = CaseOperations.newEncounter(one)!!
        assertEquals(listOf(b.caseID), CaseOperations.deleteCase(two, a.caseID).cases.map { it.id })
        try { CaseOperations.updateCase(two, a.caseID, "  ", "Hund", ""); throw AssertionError("blank label") } catch (_: AppFailure) {}
        val renamed = CaseOperations.updateCase(two, a.caseID, " Bello-1 ", "Hund", "Bello")
        assertEquals("Bello · Bello-1", renamed.cases.first { it.id == a.caseID }.displayName)
    }

    @Test fun workRunningAtProcessEndIsMarkedInterruptedAndNothingElseChanges() {
        var document = VaultDocument()
        val locations = EncounterState.entries.map { state ->
            val (next, location) = CaseOperations.newEncounter(document)!!
            document = next.mapEncounter(location) { it.copy(state = state) }
            state to location
        }
        val recovered = CaseOperations.recoverInterruptedWork(document)
        for ((state, location) in locations) {
            val expected = if (state in setOf(EncounterState.RECORDING, EncounterState.TRANSCRIBING, EncounterState.GENERATING)) EncounterState.INTERRUPTED else state
            assertEquals(state.name, expected, CaseOperations.encounter(recovered, location)!!.state)
        }
        assertEquals(recovered, CaseOperations.recoverInterruptedWork(recovered))
    }
}
