package de.tobwil.vetmed.core

import de.tobwil.vetmed.core.CaseOperations.mapEncounter

/** A chat is either a case encounter or a standalone quick check (caseID == null). */
data class ChatLocation(val caseID: String?, val encounterID: String)

/** Pure chat changes mirroring `VetAppModel` on iOS; quick checks share the encounter code path. */
object ChatOperations {
    const val MAX_ATTACHMENTS_PER_CHAT = 30
    const val MAX_ATTACHMENTS_TOTAL = 200
    const val MAX_RUNS_PER_CHAT = 100
    const val MAX_RUNS_TOTAL = 250

    fun context(document: VaultDocument, location: ChatLocation): Encounter? =
        if (location.caseID != null) CaseOperations.encounter(document, EncounterLocation(location.caseID, location.encounterID))
        else document.quickChecks.orEmpty().firstOrNull { it.id == location.encounterID }?.analysisContext

    fun mapChat(document: VaultDocument, location: ChatLocation, change: (Encounter) -> Encounter): VaultDocument {
        if (location.caseID != null) return document.mapEncounter(EncounterLocation(location.caseID, location.encounterID), change)
        return document.copy(quickChecks = document.quickChecks?.map { check ->
            if (check.id != location.encounterID) check else {
                val changed = change(check.analysisContext)
                check.copy(draft = changed.sparringDraft ?: SparringDraft(), runs = changed.analysisRuns.orEmpty(), chatAttachments = changed.chatAttachments)
            }
        })
    }

    fun newQuickCheck(document: VaultDocument): Pair<VaultDocument, ChatLocation> {
        val check = QuickCheck()
        return document.copy(quickChecks = listOf(check) + document.quickChecks.orEmpty()) to ChatLocation(null, check.id)
    }

    fun deleteQuickCheck(document: VaultDocument, id: String): VaultDocument =
        document.copy(quickChecks = document.quickChecks?.filter { it.id != id }?.ifEmpty { null })

    fun saveDraft(document: VaultDocument, location: ChatLocation, draft: SparringDraft): VaultDocument {
        draft.validate()
        if (context(document, location) == null) throw AppFailure("Dieser Chat ist nicht mehr vorhanden.")
        return mapChat(document, location) { it.copy(sparringDraft = draft) }
    }

    fun addAttachment(document: VaultDocument, location: ChatLocation, attachment: ChatAttachment): VaultDocument {
        val chat = context(document, location) ?: throw AppFailure("Dieser Chat ist nicht mehr vorhanden.")
        val total = document.cases.flatMap { it.encounters }.sumOf { it.chatAttachments.orEmpty().size } + document.quickChecks.orEmpty().sumOf { it.chatAttachments.orEmpty().size }
        if (chat.chatAttachments.orEmpty().size >= MAX_ATTACHMENTS_PER_CHAT || total >= MAX_ATTACHMENTS_TOTAL) {
            throw AppFailure("Das lokale Anhangslimit ist erreicht. Bitte nicht mehr benötigte Chats oder Fälle löschen.")
        }
        return mapChat(document, location) { it.copy(chatAttachments = it.chatAttachments.orEmpty() + attachment) }
    }

    fun reviewDocument(document: VaultDocument, location: ChatLocation, id: String, text: String): VaultDocument {
        if (text.encodeToByteArray().size > 400_000) throw AppFailure("Der geprüfte Text ist zu lang.")
        val chat = context(document, location) ?: throw AppFailure("Dieser Chat ist nicht mehr vorhanden.")
        if (chat.chatAttachments.orEmpty().none { it.id == id && it.kind == AttachmentKind.DOCUMENT }) throw AppFailure("Dieses Dokument ist nicht mehr vorhanden.")
        return mapChat(document, location) { encounter ->
            encounter.copy(chatAttachments = encounter.chatAttachments?.map { if (it.id == id) it.copy(reviewedText = text, reviewedAt = now()) else it })
        }
    }

    fun checkAnalysisBudget(document: VaultDocument, location: ChatLocation) {
        val total = document.cases.flatMap { it.encounters }.sumOf { it.analysisRuns.orEmpty().size } + document.quickChecks.orEmpty().sumOf { it.runs.size }
        if (total >= MAX_RUNS_TOTAL || (context(document, location)?.analysisRuns?.size ?: 0) >= MAX_RUNS_PER_CHAT) {
            throw AppFailure("Das lokale Analysebudget ist erreicht. Bitte nicht mehr benötigte Fälle exportieren und löschen oder einen neuen Vorgang verwenden.")
        }
    }

    fun updateRun(document: VaultDocument, location: ChatLocation, runID: String, change: (AnalysisRun) -> AnalysisRun): VaultDocument =
        mapChat(document, location) { encounter -> encounter.copy(analysisRuns = encounter.analysisRuns?.map { if (it.id == runID) change(it) else it }) }

    /** After a crash or kill, running answers stay visible but are marked incomplete; nothing is resent. */
    fun recoverInterrupted(document: VaultDocument): VaultDocument = document.copy(
        cases = document.cases.map { item -> item.copy(encounters = item.encounters.map { it.recoverInterruptedAnalysis() }) },
        quickChecks = document.quickChecks?.map { check ->
            val recovered = check.analysisContext.recoverInterruptedAnalysis()
            check.copy(runs = recovered.analysisRuns.orEmpty())
        },
    )

    /** All attachment IDs still referenced, per chat scope, used to clean up orphaned encrypted files. */
    fun chats(document: VaultDocument): List<Pair<ChatLocation, Encounter>> =
        document.cases.flatMap { item -> item.encounters.map { ChatLocation(item.id, it.id) to it } } +
            document.quickChecks.orEmpty().map { ChatLocation(null, it.id) to it.analysisContext }
}
