import XCTest
@testable import VetMed

/// Lab results as a checked table (ADR 0015). Same cases as Android's `LabReportTests`; synthetic values only.
final class LabReportTests: XCTestCase {
    private let key = "synthetic-lab-key-for-contract-tests"
    private let page = Data((0..<1000).map { UInt8($0 % 251) })
    private func json(_ data: Data?) -> [String: Any] { (try? JSONSerialization.jsonObject(with: data ?? Data())) as? [String: Any] ?? [:] }

    func testGermanNumbersAreReadWithoutGuessingThousands() {
        XCTAssertEqual(LabMath.number("12,5"), 12.5)
        XCTAssertEqual(LabMath.number("0.8"), 0.8)
        XCTAssertEqual(LabMath.number("1.234,5"), 1234.5)
        XCTAssertEqual(LabMath.number("1,234.5"), 1234.5)
        XCTAssertEqual(LabMath.number(" 250 "), 250)
        for text in ["", "abc", "1.2.3", "<5", "5-6", ",5", "negativ"] { XCTAssertNil(LabMath.number(text), text) }
        XCTAssertEqual(LabMath.numbers("3,5 - 5,5 und 85 U/l"), [3.5, 5.5, 85])
        XCTAssertEqual(LabMath.numbers("Datum 12.10.2026"), [])
    }

    func testOnlyUnambiguousPrintedReferencesBecomeRanges() {
        XCTAssertEqual(LabMath.reference("3,5 - 5,5"), .init(low: 3.5, high: 5.5))
        XCTAssertEqual(LabMath.reference("3,5–5,5"), .init(low: 3.5, high: 5.5))
        XCTAssertEqual(LabMath.reference("3,5 bis 5,5"), .init(low: 3.5, high: 5.5))
        XCTAssertEqual(LabMath.reference("(3.5-5.5)"), .init(low: 3.5, high: 5.5))
        XCTAssertEqual(LabMath.reference("< 5"), .init(low: nil, high: 5, highInclusive: false))
        XCTAssertEqual(LabMath.reference("≤5,0"), .init(low: nil, high: 5))
        XCTAssertEqual(LabMath.reference("bis 5"), .init(low: nil, high: 5))
        XCTAssertEqual(LabMath.reference("> 10"), .init(low: 10, high: nil, lowInclusive: false))
        for text in ["", "negativ", "m: 3-5 w: 2-4", "5 - 3", "siehe Kommentar"] { XCTAssertNil(LabMath.reference(text), text) }
    }

    func testTheAppAssessesOnlyPlainNumbersAgainstThePrintedRange() {
        XCTAssertEqual(LabMath.assess("6,0", reference: "3,5 - 5,5"), .high)
        XCTAssertEqual(LabMath.assess("3,5", reference: "3,5 - 5,5"), .normal)
        XCTAssertEqual(LabMath.assess("5,5", reference: "3,5 - 5,5"), .normal)
        XCTAssertEqual(LabMath.assess("3,4", reference: "3,5 - 5,5"), .low)
        XCTAssertEqual(LabMath.assess("5", reference: "< 5"), .high)
        XCTAssertEqual(LabMath.assess("5", reference: "≤ 5"), .normal)
        XCTAssertEqual(LabMath.assess("10", reference: "> 10"), .low)
        XCTAssertEqual(LabMath.assess("< 0,1", reference: "< 0,5"), .unknown)
        XCTAssertEqual(LabMath.assess("negativ", reference: "negativ"), .unknown)
        XCTAssertEqual(LabMath.assess("4,0", reference: ""), .unknown)
    }

    func testALabFlagThatContradictsThePrintedRangeIsMarked() {
        let misread = LabValue(parameter: "Kreatinin", value: "1,6", reference: "0,5 - 1,8", flag: "H")
        XCTAssertTrue(misread.flagConflict && misread.needsCheck)
        XCTAssertTrue(LabValue(parameter: "K", value: "5,0", reference: "3,5 - 5,5", flag: "↓").flagConflict)
        XCTAssertFalse(LabValue(parameter: "Kreatinin", value: "1,9", reference: "0,5 - 1,8", flag: "H").flagConflict)
        XCTAssertFalse(LabValue(parameter: "Parvo", value: "positiv", reference: "negativ", flag: "+").flagConflict)
    }

    func testRequestsSendPageImagesWithAStrictSchemaAndKeepTheKeyInTheHeader() throws {
        let openAI = try LabExtraction.openAIRequest(modelID: "synthetic-model", key: key, pages: [page, page])
        XCTAssertEqual(openAI.value(forHTTPHeaderField: "Authorization"), "Bearer " + key)
        XCTAssertFalse(String(decoding: openAI.httpBody!, as: UTF8.self).contains(key))
        let body = json(openAI.httpBody)
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertTrue((body["instructions"] as? String)?.contains("Erfinde niemals einen Referenzbereich") == true)
        let content = ((body["input"] as? [[String: Any]])?.first?["content"] as? [[String: Any]]) ?? []
        XCTAssertEqual(content.filter { ($0["image_url"] as? String)?.hasPrefix("data:image/jpeg;base64,") == true }.count, 2)
        let format = (body["text"] as? [String: Any])?["format"] as? [String: Any]
        XCTAssertEqual(format?["strict"] as? Bool, true)
        let row = (((format?["schema"] as? [String: Any])?["properties"] as? [String: Any])?["values"] as? [String: Any])?["items"] as? [String: Any]
        XCTAssertEqual(row?["required"] as? [String], ["parameter", "value", "unit", "reference", "flag", "page", "uncertain"])
        XCTAssertThrowsError(try LabExtraction.openAIRequest(modelID: "m", key: key, pages: Array(repeating: page, count: 7)))
        XCTAssertThrowsError(try LabExtraction.openAIRequest(modelID: "m", key: key, pages: [Data(count: LabExtraction.maxPageBytes + 1)]))

        let gemini = try LabExtraction.geminiRequest(modelID: "gemini-3.6-flash", key: key, pages: [page])
        XCTAssertEqual(gemini.url?.absoluteString, "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.6-flash:generateContent")
        XCTAssertEqual(gemini.value(forHTTPHeaderField: "x-goog-api-key"), key)
        let parts = (((json(gemini.httpBody)["contents"] as? [[String: Any]])?.first)?["parts"] as? [[String: Any]]) ?? []
        XCTAssertEqual(parts.filter { $0["inlineData"] != nil }.count, 1)
        XCTAssertThrowsError(try LabExtraction.geminiRequest(modelID: "../x", key: key, pages: [page]))
    }

    private let table = #"{"laboratory":"Synthetisches Labor","sampleDate":"12.10.2026","values":[{"parameter":" ALT (GPT) ","value":"85","unit":"U/l","reference":"10 - 100","flag":"","page":1,"uncertain":false},{"parameter":"Kreatinin","value":"1,6","unit":"mg/dl","reference":"0,5 - 1,8","flag":"","page":9,"uncertain":false},{"parameter":"Glukose","value":"5,1","unit":"mmol/l","reference":"3,9 - 6,1","flag":"","page":1,"uncertain":true}]}"#

    func testTheModelTableIsParsedStrictlyAndCheckedAgainstTheOriginal() throws {
        let report = try LabExtraction.parse(table, method: "m", pages: 2)
        XCTAssertEqual(report.values.map(\.parameter), ["ALT (GPT)", "Kreatinin", "Glukose"])
        XCTAssertEqual(report.values[1].page, 2)
        XCTAssertThrowsError(try LabExtraction.parse("kein JSON", method: "m", pages: 1))
        XCTAssertThrowsError(try LabExtraction.parse(#"{"laboratory":"","sampleDate":"","values":[]}"#, method: "m", pages: 1))
        let local = "Synthetisches Labor\nALT (GPT) 85 U/l 10 - 100\nKreatinin 1,9 mg/dl 0,5 - 1,8 H\nGlukose 5.1 mmol/l 3,9 - 6,1"
        let verified = LabExtraction.verify(report, localText: local)
        XCTAssertEqual(verified.values.map(\.evidence), [.found, .notFound, .found])
        XCTAssertEqual(verified.openChecks, 2)
        XCTAssertTrue(LabExtraction.verify(report, localText: "").values.allSatisfy { $0.evidence == .unchecked })
    }

    func testTheDeviceOnlyParserReadsLinesButMarksEveryRow() throws {
        let report = try LabExtraction.parseLocal("Seite 1\nKlinik Muster\nALT 85 U/l 10 - 100\nSeite 2\nKreatinin 1,9 mg/dl 0,5-1,8 H\nKommentar: unauffällig", pages: 2)
        XCTAssertEqual(report.values.map(\.parameter), ["ALT", "Kreatinin"])
        XCTAssertEqual(report.values.map(\.unit), ["U/l", "mg/dl"])
        XCTAssertEqual(report.values.map(\.reference), ["10 - 100", "0,5-1,8"])
        XCTAssertEqual(report.values.map(\.flag), ["", "H"])
        XCTAssertEqual(report.values.map(\.page), [1, 2])
        XCTAssertTrue(report.values.allSatisfy { $0.evidence == .local && $0.needsCheck })
        XCTAssertThrowsError(try LabExtraction.parseLocal("Nur Fließtext ohne Werte.", pages: 1))
    }

    func testOnlyAConfirmedTableReachesTheChatWithTheAppsOwnAssessment() throws {
        let attachment = ChatAttachment(id: UUID(), kind: .document, originalName: "Befund.pdf", originalExtension: "pdf", originalByteCount: 10,
                                        originalSHA256: String(repeating: "0", count: 64), uploadSHA256: nil, uploadByteCount: nil, width: nil, height: nil,
                                        extractedText: "x", usedOCR: false, isLab: true)
        let read = try LabExtraction.parse(table.replacingOccurrences(of: #""1,6""#, with: #""1,9""#), method: "m", pages: 1)
        var attachments = try LabOperations.save(read, id: attachment.id, in: [attachment])
        XCTAssertNil(attachments[0].reviewedAt)
        var blank = read; blank.values.append(LabValue(parameter: "", value: "1"))
        XCTAssertThrowsError(try LabOperations.confirm(blank, id: attachment.id, in: attachments))
        attachments = try LabOperations.confirm(read, id: attachment.id, in: attachments)
        let text = try XCTUnwrap(attachments[0].reviewedText)
        XCTAssertNotNil(attachments[0].lab?.confirmedAt)
        XCTAssertTrue(text.hasPrefix("Laborbefund · Synthetisches Labor · Probe vom 12.10.2026"))
        XCTAssertTrue(text.contains("| Kreatinin | 1,9 | mg/dl | 0,5 - 1,8 | – | ↑ hoch |"))
        XCTAssertTrue(text.contains("| ALT (GPT) | 85 | U/l | 10 - 100 | – | im Bereich |"))
        attachments = try LabOperations.save(attachments[0].lab!, id: attachment.id, in: attachments)
        XCTAssertNil(attachments[0].lab?.confirmedAt)
        XCTAssertNil(attachments[0].reviewedText)
        XCTAssertThrowsError(try LabOperations.save(read, id: UUID(), in: attachments))
    }

    func testEarlierConfirmedValuesOfTheSameCaseFormTheCourse() {
        func lab(_ date: String, _ value: String) -> ChatAttachment {
            ChatAttachment(id: UUID(), kind: .document, originalName: "b.pdf", originalExtension: "pdf", originalByteCount: 1, originalSHA256: "0",
                           uploadSHA256: nil, uploadByteCount: nil, width: nil, height: nil, usedOCR: false,
                           lab: LabReport(sampleDate: date, values: [LabValue(parameter: "Kreatinin", value: value, unit: "mg/dl")], method: "m", confirmedAt: Date()), isLab: true)
        }
        let earlier = lab("01.10.2026", "1,4"), current = lab("12.10.2026", "1,9")
        var first = Encounter(); first.chatAttachments = [earlier]
        var second = Encounter(); second.chatAttachments = [current]
        var item = VetCase(label: "Fall", species: "Hund"); item.encounters = [first, second]
        let history = LabHistory.previous(cases: [item], caseID: item.id, excluding: current.id)
        XCTAssertEqual(history[LabHistory.key(parameter: "kreatinin ", unit: "mg/dl")]?.map(\.value.value), ["1,4"])
        XCTAssertEqual(history[LabHistory.key(parameter: "Kreatinin", unit: "mg/dl")]?.first?.date, "01.10.2026")
        XCTAssertTrue(LabHistory.previous(cases: [item], caseID: nil, excluding: current.id).isEmpty)
    }
}
