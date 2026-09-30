package de.tobwil.vetmed.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class ChatOperationsTests {
    private fun document(text: String) = ChatAttachment(id = newId(), kind = AttachmentKind.DOCUMENT, originalName = "Befund.txt", originalExtension = "txt",
        originalByteCount = text.length, originalSHA256 = "x", extractedText = text)

    @Test fun quickCheckNeverCreatesClinicalCaseAndDeletingOneKeepsTheOther() {
        val (withCase, encounter) = CaseOperations.newEncounter(VaultDocument())!!
        val (document, chat) = ChatOperations.newQuickCheck(withCase)
        assertEquals(1, document.cases.size); assertEquals(1, document.quickChecks!!.size)
        assertNull(chat.caseID)
        val saved = ChatOperations.saveDraft(document, chat, SparringDraft(question = "Allgemein"))
        assertEquals("Allgemein", ChatOperations.context(saved, chat)!!.sparringDraft!!.question)
        assertEquals(1, CaseOperations.deleteCase(saved, encounter.caseID).quickChecks!!.size)
        val withoutCheck = ChatOperations.deleteQuickCheck(saved, chat.encounterID)
        assertNull(withoutCheck.quickChecks); assertEquals(1, withoutCheck.cases.size)
    }

    @Test fun caseChatStaysInItsEncounter() {
        val (document, location) = CaseOperations.newEncounter(VaultDocument())!!
        val chat = ChatLocation(location.caseID, location.encounterID)
        val saved = ChatOperations.saveDraft(document, chat, SparringDraft(question = "Zum Fall"))
        assertEquals("Zum Fall", CaseOperations.encounter(saved, location)!!.sparringDraft!!.question)
        assertTrue(CaseOperations.encounter(saved, location)!!.hasChat)
        try { ChatOperations.saveDraft(saved, ChatLocation(location.caseID, "missing"), SparringDraft()); fail() } catch (_: AppFailure) {}
    }

    @Test fun documentsMustBeReviewedAndAttachmentLimitIsEnforced() {
        var (document, chat) = ChatOperations.newQuickCheck(VaultDocument())
        val attachment = document("Kein Befund. 5 mmol/l")
        document = ChatOperations.addAttachment(document, chat, attachment)
        assertNull(ChatOperations.context(document, chat)!!.chatAttachments!!.single().reviewedAt)
        document = ChatOperations.reviewDocument(document, chat, attachment.id, "Kein Befund. 5 mmol/l geprüft")
        val reviewed = ChatOperations.context(document, chat)!!.chatAttachments!!.single()
        assertNotNull(reviewed.reviewedAt); assertEquals("Kein Befund. 5 mmol/l", reviewed.extractedText)
        repeat(ChatOperations.MAX_ATTACHMENTS_PER_CHAT - 1) { document = ChatOperations.addAttachment(document, chat, document("x")) }
        try { ChatOperations.addAttachment(document, chat, document("zu viel")); fail() } catch (error: AppFailure) { assertTrue(error.message!!.contains("Anhangslimit")) }
    }

    @Test fun interruptedRunsInCasesAndQuickChecksBecomeIncomplete() {
        val (withCase, location) = CaseOperations.newEncounter(VaultDocument())!!
        var (document, chat) = ChatOperations.newQuickCheck(withCase)
        val snapshot = SparringRequestBuilder.prepare(null, ChatOperations.context(document, chat)!!, SparringDraft(question = "?"), "m", instructions = "t")
        val run = AnalysisRun(snapshot = snapshot, status = AnalysisStatus.STREAMING, text = "Teil")
        document = ChatOperations.mapChat(document, chat) { it.copy(analysisRuns = listOf(run)) }
        document = ChatOperations.mapChat(document, ChatLocation(location.caseID, location.encounterID)) { it.copy(analysisRuns = listOf(run.copy(id = newId()))) }
        val recovered = ChatOperations.recoverInterrupted(document)
        assertEquals(AnalysisStatus.INCOMPLETE, recovered.quickChecks!!.single().runs.single().status)
        assertEquals(AnalysisStatus.INCOMPLETE, recovered.cases.single().encounters.single().analysisRuns!!.single().status)
        assertEquals("Teil", recovered.quickChecks!!.single().runs.single().text)
        assertEquals(2, ChatOperations.chats(recovered).size)
    }
}
