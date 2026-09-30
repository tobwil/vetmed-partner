package de.tobwil.vetmed.core

import java.time.Instant

data class EncounterLocation(val caseID: String, val encounterID: String)

/**
 * Pure document changes mirroring `VetAppModel` on iOS. The app persists the returned document;
 * a failed save keeps the previous one. Locations carry immutable IDs, never a global selection.
 */
object CaseOperations {
    fun encounter(document: VaultDocument, location: EncounterLocation): Encounter? =
        document.cases.firstOrNull { it.id == location.caseID }?.encounters?.firstOrNull { it.id == location.encounterID }

    fun newEncounter(document: VaultDocument, caseID: String? = null): Pair<VaultDocument, EncounterLocation>? {
        val encounter = Encounter()
        if (caseID == null) {
            val created = VetCase(label = "Fall ${document.cases.size + 1}", species = "Nicht angegeben", encounters = listOf(encounter))
            return document.copy(cases = listOf(created) + document.cases) to EncounterLocation(created.id, encounter.id)
        }
        if (document.cases.none { it.id == caseID }) return null
        return document.mapCase(caseID) { it.copy(encounters = listOf(encounter) + it.encounters) } to EncounterLocation(caseID, encounter.id)
    }

    fun updateCase(document: VaultDocument, caseID: String, label: String, species: String, animalName: String): VaultDocument {
        if (label.isBlank()) throw AppFailure("Bitte eine Fallkennung eingeben.")
        return document.mapCase(caseID) { it.copy(label = label.trim(), species = species.trim(), animalName = animalName.trim()) }
    }

    fun deleteCase(document: VaultDocument, caseID: String): VaultDocument = document.copy(cases = document.cases.filter { it.id != caseID })

    /** Appends a new transcript version only when the text changed. The original stays in `rawText`. */
    fun saveTranscript(document: VaultDocument, location: EncounterLocation, text: String): VaultDocument {
        val current = encounter(document, location) ?: throw AppFailure("Dieses Diktat ist nicht mehr vorhanden.")
        val previous = current.transcripts.lastOrNull()
        if (previous?.editedText == text) return document
        val version = TranscriptBuilder.edited(text, previous)
        return document.mapEncounter(location) { it.copy(transcripts = it.transcripts + version, state = EncounterState.TRANSCRIPT_READY) }
    }

    fun saveReportEdit(document: VaultDocument, location: EncounterLocation, reportID: String, text: String, now: Instant = Instant.now()): VaultDocument {
        val report = encounter(document, location)?.reports?.firstOrNull { it.id == reportID } ?: throw AppFailure("Dieser Bericht ist nicht mehr vorhanden.")
        if (text == report.text) return document
        val revision = report.copy(
            id = newId(), parentID = report.id, createdAt = now, editedText = text, approvedAt = null,
            warnings = listOf("Manuell bearbeitet: Zahlen, Einheiten, Negationen und Quellen erneut prüfen."),
        )
        return document.mapEncounter(location) { it.copy(reports = it.reports + revision, state = EncounterState.REVIEW_REQUIRED) }
    }

    fun approve(document: VaultDocument, location: EncounterLocation, reportID: String, now: Instant = Instant.now()): VaultDocument =
        document.mapEncounter(location) { encounter ->
            if (encounter.reports.none { it.id == reportID && it.approvedAt == null }) encounter
            else encounter.copy(
                reports = encounter.reports.map { if (it.id == reportID) it.copy(approvedAt = now) else it },
                state = EncounterState.APPROVED,
            )
        }

    fun recordShare(document: VaultDocument, location: EncounterLocation, reportID: String, format: String): VaultDocument =
        document.mapEncounter(location) { encounter ->
            if (encounter.reports.none { it.id == reportID }) encounter
            else encounter.copy(shares = encounter.shares + ShareEvent(reportID = reportID, format = format))
        }

    fun VaultDocument.mapCase(caseID: String, change: (VetCase) -> VetCase): VaultDocument =
        copy(cases = cases.map { if (it.id == caseID) change(it) else it })

    fun VaultDocument.mapEncounter(location: EncounterLocation, change: (Encounter) -> Encounter): VaultDocument =
        mapCase(location.caseID) { item -> item.copy(encounters = item.encounters.map { if (it.id == location.encounterID) change(it) else it }) }
}
