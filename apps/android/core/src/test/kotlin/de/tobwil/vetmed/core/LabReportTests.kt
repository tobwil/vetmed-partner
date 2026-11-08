package de.tobwil.vetmed.core

import de.tobwil.vetmed.core.CaseOperations.mapEncounter
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/** Lab results as a checked table (ADR 0015). Synthetic values only. */
class LabReportTests {
    private val key = "synthetic-lab-key-for-contract-tests"
    private val page = ByteArray(1000) { (it % 251).toByte() }

    private fun fails(block: () -> Unit) { try { block(); fail("expected failure") } catch (_: AppFailure) {} }

    @Test fun germanNumbersAreReadWithoutGuessingThousands() {
        assertEquals(12.5, LabMath.number("12,5")!!, 0.0)
        assertEquals(0.8, LabMath.number("0.8")!!, 0.0)
        assertEquals(1234.5, LabMath.number("1.234,5")!!, 0.0)
        assertEquals(1234.5, LabMath.number("1,234.5")!!, 0.0)
        assertEquals(250.0, LabMath.number(" 250 ")!!, 0.0)
        listOf("", "abc", "1.2.3", "<5", "5-6", ",5", "negativ").forEach { assertNull(it, LabMath.number(it)) }
        assertEquals(listOf(3.5, 5.5, 85.0), LabMath.numbers("3,5 - 5,5 und 85 U/l"))
        assertEquals(emptyList<Double>(), LabMath.numbers("Datum 12.10.2026"))
    }

    @Test fun onlyUnambiguousPrintedReferencesBecomeRanges() {
        assertEquals(LabMath.Range(3.5, 5.5), LabMath.reference("3,5 - 5,5"))
        assertEquals(LabMath.Range(3.5, 5.5), LabMath.reference("3,5–5,5"))
        assertEquals(LabMath.Range(3.5, 5.5), LabMath.reference("3,5 bis 5,5"))
        assertEquals(LabMath.Range(3.5, 5.5), LabMath.reference("(3.5-5.5)"))
        assertEquals(LabMath.Range(null, 5.0, highInclusive = false), LabMath.reference("< 5"))
        assertEquals(LabMath.Range(null, 5.0), LabMath.reference("≤5,0"))
        assertEquals(LabMath.Range(null, 5.0), LabMath.reference("bis 5"))
        assertEquals(LabMath.Range(10.0, null, lowInclusive = false), LabMath.reference("> 10"))
        listOf("", "negativ", "m: 3-5 w: 2-4", "5 - 3", "siehe Kommentar").forEach { assertNull(it, LabMath.reference(it)) }
    }

    @Test fun theAppAssessesOnlyPlainNumbersAgainstThePrintedRange() {
        assertEquals(LabAssessment.HIGH, LabMath.assess("6,0", "3,5 - 5,5"))
        assertEquals(LabAssessment.NORMAL, LabMath.assess("3,5", "3,5 - 5,5"))
        assertEquals(LabAssessment.NORMAL, LabMath.assess("5,5", "3,5 - 5,5"))
        assertEquals(LabAssessment.LOW, LabMath.assess("3,4", "3,5 - 5,5"))
        assertEquals(LabAssessment.HIGH, LabMath.assess("5", "< 5"))
        assertEquals(LabAssessment.NORMAL, LabMath.assess("5", "≤ 5"))
        assertEquals(LabAssessment.LOW, LabMath.assess("10", "> 10"))
        assertEquals(LabAssessment.UNKNOWN, LabMath.assess("< 0,1", "< 0,5"))
        assertEquals(LabAssessment.UNKNOWN, LabMath.assess("negativ", "negativ"))
        assertEquals(LabAssessment.UNKNOWN, LabMath.assess("4,0", ""))
    }

    @Test fun aLabFlagThatContradictsThePrintedRangeIsMarked() {
        assertTrue(LabValue(parameter = "Kreatinin", value = "1,6", reference = "0,5 - 1,8", flag = "H").let { it.flagConflict && it.needsCheck })
        assertTrue(LabValue(parameter = "K", value = "5,0", reference = "3,5 - 5,5", flag = "↓").flagConflict)
        assertFalse(LabValue(parameter = "Kreatinin", value = "1,9", reference = "0,5 - 1,8", flag = "H").flagConflict)
        assertFalse(LabValue(parameter = "Parvo", value = "positiv", reference = "negativ", flag = "+").flagConflict)
        assertFalse(LabValue(parameter = "X", value = "1", reference = "", flag = "H").flagConflict)
    }

    @Test fun openAIRequestSendsPageImagesWithAStrictTranscriptionSchema() {
        val request = LabExtraction.openAIRequest("synthetic-model", key, listOf(page, page))
        assertEquals(OpenAIReportApi.RESPONSES_URL, request.url)
        assertEquals("Bearer $key", request.headers["Authorization"])
        val text = request.body!!.decodeToString()
        assertFalse(text.contains(key))
        val body = Json.parseToJsonElement(text).jsonObject
        assertEquals("false", body.getValue("store").jsonPrimitive.content)
        assertTrue(body.getValue("instructions").jsonPrimitive.content.contains("Erfinde niemals einen Referenzbereich"))
        val content = body.getValue("input").jsonArray[0].jsonObject.getValue("content").jsonArray.map { it.jsonObject }
        assertEquals(2, content.count { it["type"]?.jsonPrimitive?.content == "input_image" && it.getValue("image_url").jsonPrimitive.content.startsWith("data:image/jpeg;base64,") })
        val format = body.getValue("text").jsonObject.getValue("format").jsonObject
        assertEquals("true", format.getValue("strict").jsonPrimitive.content)
        val row = format.getValue("schema").jsonObject.getValue("properties").jsonObject.getValue("values").jsonObject.getValue("items").jsonObject
        assertEquals(listOf("parameter", "value", "unit", "reference", "flag", "page", "uncertain"), row.getValue("required").jsonArray.map { it.jsonPrimitive.content })
        fails { LabExtraction.openAIRequest("synthetic-model", key, List(LabExtraction.MAX_PAGES + 1) { page }) }
        val schema = format.getValue("schema").jsonObject
        assertEquals(listOf("kind", "title", "issuer", "date", "text", "values"), schema.getValue("required").jsonArray.map { it.jsonPrimitive.content })
        assertEquals(listOf("lab", "letter", "imaging", "other"), schema.getValue("properties").jsonObject.getValue("kind").jsonObject.getValue("enum").jsonArray.map { it.jsonPrimitive.content })
        fails { LabExtraction.openAIRequest("synthetic-model", key, listOf(ByteArray(LabExtraction.MAX_PAGE_BYTES + 1))) }
        fails { LabExtraction.openAIRequest("synthetic-model", key, emptyList()) }
    }

    @Test fun geminiRequestKeepsTheKeyInTheHeader() {
        val request = LabExtraction.geminiRequest("gemini-3.6-flash", key, listOf(page))
        assertEquals("https://generativelanguage.googleapis.com/v1beta/models/gemini-3.6-flash:generateContent", request.url)
        assertEquals(key, request.headers["x-goog-api-key"])
        val body = Json.parseToJsonElement(request.body!!.decodeToString()).jsonObject
        val parts = body.getValue("contents").jsonArray[0].jsonObject.getValue("parts").jsonArray.map { it.jsonObject }
        assertEquals(1, parts.count { it["inlineData"] != null })
        assertTrue((body.getValue("generationConfig").jsonObject.getValue("responseSchema") as JsonObject).toString().contains("propertyOrdering"))
        fails { LabExtraction.geminiRequest("../x", key, listOf(page)) }
    }

    private val table = """{"laboratory":"Synthetisches Labor","sampleDate":"12.10.2026","values":[
        {"parameter":" ALT (GPT) ","value":"85","unit":"U/l","reference":"10 - 100","flag":"","page":1,"uncertain":false},
        {"parameter":"Kreatinin","value":"1,6","unit":"mg/dl","reference":"0,5 - 1,8","flag":"","page":9,"uncertain":false},
        {"parameter":"Glukose","value":"5,1","unit":"mmol/l","reference":"3,9 - 6,1","flag":"","page":1,"uncertain":true}]}"""

    @Test fun theModelTableIsParsedStrictly() {
        val report = LabExtraction.parse(table, "OpenAI synthetic · Seitenbilder", pages = 2)
        assertEquals("Synthetisches Labor", report.laboratory)
        assertEquals(listOf("ALT (GPT)", "Kreatinin", "Glukose"), report.values.map { it.parameter })
        assertEquals(2, report.values[1].page) // clamped to the pages sent
        assertTrue(report.values[2].uncertain)
        assertNull(report.confirmedAt)
        fails { LabExtraction.parse("kein JSON", "m", 1) }
        fails { LabExtraction.parse("""{"laboratory":"","sampleDate":"","values":[]}""", "m", 1) }
        fails { LabExtraction.parse("""{"values":"x"}""", "m", 1) }
        val many = (1..301).joinToString(",") { """{"parameter":"P$it","value":"1","unit":"","reference":"","flag":"","page":1,"uncertain":false}""" }
        fails { LabExtraction.parse("""{"laboratory":"","sampleDate":"","values":[$many]}""", "m", 1) }
    }

    @Test fun everyNumberMustBeFoundAgainInTheLocalOriginal() {
        val local = "Synthetisches Labor\nALT (GPT) 85 U/l 10 - 100\nKreatinin 1,9 mg/dl 0,5 - 1,8 H\nGlukose 5.1 mmol/l 3,9 - 6,1"
        val verified = LabExtraction.verify(LabExtraction.parse(table, "m", 1), local)
        assertEquals(listOf(LabEvidence.FOUND, LabEvidence.NOT_FOUND, LabEvidence.FOUND), verified.values.map { it.evidence })
        assertEquals(2, verified.openChecks) // misread value plus the line marked uncertain
        assertTrue(LabExtraction.verify(LabExtraction.parse(table, "m", 1), "").values.all { it.evidence == LabEvidence.UNCHECKED })
        val edited = verified.copy(values = verified.values.map { it.copy(evidence = LabEvidence.EDITED) })
        assertTrue(LabExtraction.verify(edited, local).values.all { it.evidence == LabEvidence.EDITED })
    }

    @Test fun theDeviceOnlyParserReadsLinesButMarksEveryRow() {
        val report = LabExtraction.parseLocal("Seite 1\nKlinik Muster\nALT 85 U/l 10 - 100\nSeite 2\nKreatinin 1,9 mg/dl 0,5-1,8 H\nKommentar: unauffällig", pages = 2)
        assertEquals(listOf("ALT", "Kreatinin"), report.values.map { it.parameter })
        assertEquals(listOf("85", "1,9"), report.values.map { it.value })
        assertEquals(listOf("U/l", "mg/dl"), report.values.map { it.unit })
        assertEquals(listOf("10 - 100", "0,5-1,8"), report.values.map { it.reference })
        assertEquals(listOf("", "H"), report.values.map { it.flag })
        assertEquals(listOf(1, 2), report.values.map { it.page })
        assertTrue(report.values.all { it.evidence == LabEvidence.LOCAL && it.needsCheck })
        assertEquals(DocumentKind.LAB, report.kind)
        // Without value lines the local text itself is the reading.
        val letter = LabExtraction.parseLocal("Seite 1\nBefund: Lahmheit hinten links.\nKontrolle in 7 Tagen.", 1)
        assertEquals(DocumentKind.OTHER, letter.kind)
        assertEquals("Befund: Lahmheit hinten links.\nKontrolle in 7 Tagen.", letter.text)
        fails { LabExtraction.parseLocal("  ", 1) }
    }

    @Test fun theChatReceivesTheConfirmedTableWithTheAppsOwnAssessment() {
        val report = LabExtraction.parse(table.replace("\"1,6\"", "\"1,9\"").replace("ALT (GPT)", "ALT | GPT").replace("{\"laboratory\"", "{\"kind\":\"lab\",\"laboratory\""), "m", 1)
        val text = LabExtraction.render(report)
        assertTrue(text, text.startsWith("Laborbefund · Synthetisches Labor · vom 12.10.2026\nAm Original geprüft und bestätigt."))
        assertTrue(text.contains("| Parameter | Wert | Einheit | Referenz (Labor) | Kennz. (Labor) | Bewertung (App) |"))
        assertTrue(text.contains("| Kreatinin | 1,9 | mg/dl | 0,5 - 1,8 | – | ↑ hoch |"))
        assertTrue(text.contains("| ALT / GPT | 85 | U/l | 10 - 100 | – | im Bereich |"))
    }

    @Test fun onlyAConfirmedTableReachesTheChatAndChangesNeedANewConfirmation() {
        var document = VaultDocument()
        val (withCheck, chat) = ChatOperations.newQuickCheck(document)
        val attachment = ChatAttachment(id = "lab-1", kind = AttachmentKind.DOCUMENT, originalName = "Befund.pdf", originalExtension = "pdf", originalByteCount = 10,
            originalSHA256 = "0".repeat(64), extractedText = "x", isLab = true)
        document = ChatOperations.addAttachment(withCheck, chat, attachment)
        val read = LabExtraction.parse(table, "m", 1)
        document = ChatOperations.saveLab(document, chat, "lab-1", read)
        val encounter = { ChatOperations.context(document, chat)!! }
        assertNull(encounter().chatAttachments!!.single().reviewedAt)
        // An unconfirmed table cannot be sent.
        val draft = SparringDraft(question = "Wie einordnen?", attachmentIDs = listOf("lab-1"))
        try { SparringRequestBuilder.prepare(null, encounter(), draft, "m", instructions = "test"); fail("unconfirmed") } catch (_: AppFailure) {}
        fails { ChatOperations.confirmLab(document, chat, "lab-1", read.copy(values = read.values + LabValue(parameter = "", value = "1"))) }
        document = ChatOperations.confirmLab(document, chat, "lab-1", read)
        val confirmed = encounter().chatAttachments!!.single()
        assertTrue(confirmed.lab!!.confirmedAt != null)
        assertEquals(LabExtraction.render(confirmed.lab!!), confirmed.reviewedText)
        val snapshot = SparringRequestBuilder.prepare(null, encounter(), draft, "m", instructions = "test")
        assertTrue(snapshot.payload.decodeToString().contains("Bewertung (App)"))
        // Reading again or editing resets the confirmation.
        document = ChatOperations.saveLab(document, chat, "lab-1", confirmed.lab!!)
        assertNull(encounter().chatAttachments!!.single().lab!!.confirmedAt)
        assertNull(encounter().chatAttachments!!.single().reviewedText)
        fails { ChatOperations.saveLab(document, chat, "missing", read) }
    }

    @Test fun earlierConfirmedValuesOfTheSameCaseFormTheCourse() {
        var document = VaultDocument()
        val (d1, first) = CaseOperations.newEncounter(document)!!
        val (d2, second) = CaseOperations.newEncounter(d1, first.caseID)!!
        fun lab(id: String, date: String, creatinine: String) = ChatAttachment(id = id, kind = AttachmentKind.DOCUMENT, originalName = "$id.pdf", originalExtension = "pdf",
            originalByteCount = 1, originalSHA256 = "0".repeat(64), isLab = true,
            lab = LabReport(sampleDate = date, method = "m", values = listOf(LabValue(parameter = "Kreatinin", value = creatinine, unit = "mg/dl")), confirmedAt = now()))
        document = d2.mapEncounter(first) { it.copy(chatAttachments = listOf(lab("a", "01.10.2026", "1,4"))) }
            .mapEncounter(second) { it.copy(chatAttachments = listOf(lab("b", "12.10.2026", "1,9"))) }
        val history = LabHistory.previous(document, first.caseID, excludeAttachmentID = "b")
        val earlier = history.getValue(LabHistory.key("kreatinin ", "mg/dl"))
        assertEquals(listOf("1,4"), earlier.map { it.value.value })
        assertEquals("01.10.2026", earlier.single().date)
        assertTrue(LabHistory.previous(document, null, "b").isEmpty())
        assertFalse(history.containsKey(LabHistory.key("Kreatinin", "µmol/l")))
    }

    @Test fun photosAreRoutedByTheirContentNotByAMenuChoice() {
        assertTrue(DocumentRouting.looksLikeDocument("Kreatinin 1,9 mg/dl 0,5 - 1,8\nHarnstoff 9,1 mmol/l 3,3 - 8,3\nALT 85 U/l 10 - 100"))
        assertTrue(DocumentRouting.looksLikeDocument("Sehr geehrte Kollegin, vielen Dank für die Überweisung. ".repeat(4)))
        assertFalse(DocumentRouting.looksLikeDocument(""))
        assertFalse(DocumentRouting.looksLikeDocument("OP 3 links"))
    }

    // A referral letter laid out unlike any lab sheet: narrative text, then values with the range in two columns.
    private val letter = """{"kind":"letter","title":"Rücküberweisung","issuer":"Synthetische Tierklinik","date":"01.11.2026",
        "text":"Anamnese: seit 3 Tagen Inappetenz.\nBefunde: Temperatur 39,2 °C.\nTherapie: Meloxicam 0,1 mg/kg einmal täglich.",
        "values":[{"parameter":"Kreatinin","value":"1,9","unit":"mg/dl","reference":"0,5 - 1,8","flag":"","page":2,"uncertain":false},
                  {"parameter":"Harnstoff","value":"9,1","unit":"mmol/l","reference":"3,3 - 8,3","flag":"","page":2,"uncertain":false}]}"""

    @Test fun lettersAreReadAsTextAndEmbeddedValuesAndTheirNumbersAreChecked() {
        val reading = LabExtraction.parse(letter, "m", 3)
        assertEquals(DocumentKind.LETTER, reading.kind)
        assertEquals("Rücküberweisung", reading.heading)
        assertEquals("Synthetische Tierklinik", reading.laboratory)
        assertEquals("01.11.2026", reading.sampleDate)
        assertTrue(reading.text.startsWith("Anamnese"))
        // OCR of the pages has every table value and the dose, but not the temperature: the model may have misread it.
        val local = "Rücküberweisung 01.11.2026\nseit 3 Tagen\nTemperatur 38,2 °C\nMeloxicam 0,1 mg/kg\nKreatinin 1,9 0,5 1,8 mg/dl\nHarnstoff 9,1 3,3 8,3 mmol/l"
        val verified = LabExtraction.verify(reading, local)
        assertEquals(listOf("39,2"), verified.unmatchedNumbers)
        assertEquals(listOf(LabEvidence.FOUND, LabEvidence.FOUND), verified.values.map { it.evidence })
        assertEquals(1, verified.openChecks)
        assertEquals(emptyList<String>(), LabExtraction.verify(reading, "").unmatchedNumbers)
        val text = LabExtraction.render(verified)
        assertTrue(text, text.startsWith("Brief oder Bericht · Rücküberweisung · Synthetische Tierklinik · vom 01.11.2026\nAm Original geprüft und bestätigt.\n\nAnamnese: seit 3 Tagen"))
        assertTrue(text.contains("| Kreatinin | 1,9 | mg/dl | 0,5 - 1,8 | – | ↑ hoch |"))
        assertTrue(text.contains("| Harnstoff | 9,1 | mmol/l | 3,3 - 8,3 | – | ↑ hoch |"))
        // A letter without values is a valid reading; a reading with neither text nor values is not.
        val plain = LabExtraction.parse("""{"kind":"imaging","title":"Röntgen Thorax","issuer":"","date":"","text":"Keine Auffälligkeiten.","values":[]}""", "m", 1)
        assertEquals(DocumentKind.IMAGING, plain.kind)
        assertEquals("Bildgebung oder Histologie · Röntgen Thorax\nAm Original geprüft und bestätigt.\n\nKeine Auffälligkeiten.", LabExtraction.render(plain))
        fails { LabExtraction.parse("""{"kind":"other","title":"","issuer":"","date":"","text":" ","values":[]}""", "m", 1) }
    }

    @Test fun aLetterWithoutValuesCanBeConfirmed() {
        var document = VaultDocument()
        val (withCheck, chat) = ChatOperations.newQuickCheck(document)
        val attachment = ChatAttachment(id = "doc-1", kind = AttachmentKind.DOCUMENT, originalName = "Brief.pdf", originalExtension = "pdf", originalByteCount = 10,
            originalSHA256 = "0".repeat(64), extractedText = "Text", checkText = "OCR", isLab = true)
        assertEquals("Text\nOCR", attachment.localText)
        document = ChatOperations.addAttachment(withCheck, chat, attachment)
        val reading = LabReport(method = "m", kind = DocumentKind.LETTER, title = "Rücküberweisung", text = "Kontrolle in 7 Tagen.")
        document = ChatOperations.confirmLab(document, chat, "doc-1", reading)
        val confirmed = ChatOperations.context(document, chat)!!.chatAttachments!!.single()
        assertEquals("Rücküberweisung", confirmed.displayName)
        assertTrue(confirmed.reviewedText!!.endsWith("Kontrolle in 7 Tagen."))
        fails { ChatOperations.confirmLab(document, chat, "doc-1", reading.copy(text = " ")) }
    }

    @Test fun sparringPromptTellsTheModelToUseTheTableAndTheAppAssessment() {
        val prompt = SparringRequestBuilder.instructions
        assertTrue(prompt.contains("# Laborbefunde als Tabelle"))
        assertTrue(prompt.contains("ergänze keinen eigenen Referenzbereich"))
    }
}
