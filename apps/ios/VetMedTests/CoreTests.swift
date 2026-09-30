import XCTest
import CryptoKit
import PDFKit
@testable import VetMed

final class CoreTests: XCTestCase {
    private func fixture(_ text: String = "Hund, 12,5 kg. Kein Fieber. Gabe 0,5 mg/kg.") -> (TranscriptVersion, StructuredReport) {
        let t = TranscriptVersion(rawText: text, editedText: text, segments: [.init(id: "test-source", text: text)], engine: "synthetic")
        let report = StructuredReport(template: .treatment_report, length: .medium, audience: .veterinarian,
            sourceTranscriptVersionId: t.id.uuidString,
            sections: [.init(key: "Befunde", items: [.init(text: text, sourceRefs: [.init(segmentId: t.segments[0].id, quote: text)], origin: "dictated")])], missingInformation: [], conflicts: [])
        return (t, report)
    }
    func testValidSourceAndGermanDecimal() throws {
        let (t, r) = fixture()
        XCTAssertEqual(try ReportValidator.validate(r, transcript: t), [])
        XCTAssertEqual(ReportValidator.numbers("0,5 und 12.5"), ["0.5", "12.5"])
    }
    func testEscapedJSONWhitespaceDoesNotRewriteQuotedContent() throws {
        let text = #"{\n"items":[{\n"section":"Befunde","text":"Kein Fieber.","segmentId":"q1","quote":"Zeile\nKein Fieber."}],\n"missingInformation":[],"conflicts":[]\n}"#
        let draft = try ReportValidator.decodeJSON(ModelReportDraft.self, text)
        XCTAssertEqual(draft.items.first?.quote, "Zeile\nKein Fieber.")
        XCTAssertEqual(draft.items.first?.text, "Kein Fieber.")
        XCTAssertThrowsError(try ReportValidator.decodeJSON(ModelReportDraft.self, #"{"items": []}, "conflicts": []}"#))
    }
    func testOptionalModelAnnotationsDoNotMakeFactualItemsOptional() throws {
        let draft = try ReportValidator.decodeJSON(ModelReportDraft.self, #"{"items":[{"section":"Befunde","text":"Kein Fieber.","segmentId":"q1","quote":"Kein Fieber."}]}"#)
        XCTAssertTrue(draft.conflicts.isEmpty); XCTAssertTrue(draft.missingInformation.isEmpty)
        XCTAssertThrowsError(try ReportValidator.decodeJSON(ModelReportDraft.self, #"{"conflicts":[]}"#))
        XCTAssertThrowsError(try ReportValidator.decodeJSON(ModelReportDraft.self, #"{"items":[],"conflicts":"none"}"#))
    }
    func testInventedDoseRejectedEvenWhenOtherSourceContainsNumber() {
        let (t, original) = fixture(); var report = original
        report.sections[0].items[0].text = "Gabe 5 mg/kg."
        XCTAssertThrowsError(try ReportValidator.validate(report, transcript: t))
    }
    func testChangedUnitRejected() {
        let (t, original) = fixture(); var report = original
        report.sections[0].items[0].text = "Gabe 0,5 mmol/l."
        XCTAssertThrowsError(try ReportValidator.validate(report, transcript: t))
    }
    func testEmptyStructuredReportIsRejected() {
        let (t, original) = fixture(); var report = original
        report.sections[0].items = []
        XCTAssertThrowsError(try ReportValidator.validate(report, transcript: t))
    }
    func testEditedTranscriptKeepsOriginalAudioReachable() {
        let audio = UUID()
        let raw = TranscriptVersion(rawText: "Kein Fieber", editedText: "Kein Fieber", segments: [.init(id: "audio-1", text: "Kein Fieber", audioID: audio, startSeconds: 1, endSeconds: 3)], engine: "synthetic")
        let edit = TranscriptBuilder.edited("Kein Fieber.", previous: raw)
        var encounter = Encounter(); encounter.transcripts = [raw, edit]
        XCTAssertEqual(encounter.playbackSegments.count, 1)
        XCTAssertEqual(encounter.playbackSegments.first?.audioID, audio)
    }
    func testChangedOrLostComparisonSignIsRejected() {
        let (t, original) = fixture("Laborwert > 20 mg/dl.")
        for value in ["Laborwert < 20 mg/dl.", "Laborwert 20 mg/dl."] {
            var report = original; report.sections[0].items[0].text = value
            XCTAssertThrowsError(try ReportValidator.validate(report, transcript: t))
        }
    }
    func testModelDraftUsesImmutableRequestMetadata() throws {
        let t = fixture().0
        let draft = ModelReportDraft(items: [.init(section: "Befunde", text: t.editedText, segmentId: t.segments[0].id, quote: t.editedText)], missingInformation: [], conflicts: [])
        let report = try draft.report(transcriptID: t.id, template: .treatment_report, length: .short, audience: .owner)
        XCTAssertEqual(report.sourceTranscriptVersionId, t.id.uuidString)
        XCTAssertEqual(report.length, .short); XCTAssertEqual(report.audience, .owner)
        XCTAssertTrue(report.requiresReview)
        XCTAssertEqual(try ReportValidator.validate(report, transcript: t), [])
    }
    func testSourceSegmentationKeepsNegationsAndDecimalTogether() {
        let t = TranscriptBuilder.edited("Hund, 12,5 kg. Kein Erbrechen. Temperatur nicht gemessen. Kontrolle in 3 Tagen.", previous: nil)
        XCTAssertEqual(t.segments.count, 4)
        XCTAssertTrue(t.segments[0].text.contains("12,5"))
        XCTAssertTrue(t.segments[1].text.contains("Kein Erbrechen"))
        XCTAssertTrue(t.segments[2].text.contains("nicht gemessen"))
        XCTAssertEqual(t.segments.map(\.text).joined(), t.editedText)
    }
    func testASRBoundaryDoesNotSeparateNegationFromFinding() {
        let audio = UUID()
        let pieces: [TranscriptSegment] = [
            .init(id: "a", text: "Hund 12,5 kg. Kein", audioID: audio, startSeconds: 0, endSeconds: 3),
            .init(id: "b", text: "Erbrechen. Temperatur nicht gemessen.", audioID: audio, startSeconds: 3, endSeconds: 7)
        ]
        let sentences = TranscriptBuilder.audioSentences(pieces)
        XCTAssertEqual(sentences.count, 3)
        XCTAssertEqual(sentences[1].text.trimmingCharacters(in: .whitespacesAndNewlines), "Kein Erbrechen.")
        XCTAssertEqual(sentences[1].startSeconds, 0)
        XCTAssertEqual(sentences[1].endSeconds, 7)
        XCTAssertEqual(sentences[1].audioID, audio)
        XCTAssertEqual(sentences.map(\.text).joined(), "Hund 12,5 kg. Kein Erbrechen. Temperatur nicht gemessen.")
    }
    @MainActor
    func testIncompleteModelOutputCannotSilentlyOmitNegation() async throws {
        final class IncompleteEngine: ReportTextEngine {
            let result: String
            var calls = 0
            init(_ result: String) { self.result = result }
            func generate(prompt: String, instructions: String) async throws -> String { calls += 1; return result }
        }
        let t = TranscriptBuilder.edited("Appetit vermindert. Kein Erbrechen.", previous: nil)
        let draft = ModelReportDraft(items: [.init(section: "Anamnese", text: "Appetit vermindert.", segmentId: "q1", quote: "Appetit vermindert.")], missingInformation: [], conflicts: [])
        let engine = IncompleteEngine(String(decoding: try JSONEncoder().encode(draft), as: UTF8.self))
        do { _ = try await ReportPipeline(engine: engine).run(transcript: t, template: .treatment_report, length: .medium, audience: .veterinarian) { _ in }; XCTFail("A whole omitted negation source must fail") }
        catch { XCTAssertEqual(engine.calls, 2) }
    }
    func testOnlyClosedListOfHousekeepingPhrasesCanBeOmitted() {
        XCTAssertFalse(TranscriptSourcePolicy.requiresCoverage(" Diktatende. "))
        XCTAssertFalse(TranscriptSourcePolicy.requiresCoverage("Abschnitt erster synthetischer Testfall."))
        XCTAssertTrue(TranscriptSourcePolicy.requiresCoverage("Abschnitt erster synthetischer Testfall. Kein Fieber."))
        for text in ["Kein Fieber.", "Temperatur nicht gemessen.", "Hund 12,5 kg.", "Diktatende, Kontrolle in 3 Tagen.", "Keine Angaben zur Therapie."] {
            XCTAssertTrue(TranscriptSourcePolicy.requiresCoverage(text))
        }
    }
    @MainActor
    func testRepairOnlyRequestsMissingSourceAndRetainsFirstPass() async throws {
        final class RepairEngine: ReportTextEngine {
            var prompts: [String] = []
            let drafts: [ModelReportDraft]
            init(_ drafts: [ModelReportDraft]) { self.drafts = drafts }
            func generate(prompt: String, instructions: String) async throws -> String {
                prompts.append(prompt)
                return String(decoding: try JSONEncoder().encode(drafts[prompts.count - 1]), as: UTF8.self)
            }
        }
        let t = TranscriptBuilder.edited("Temperatur nicht gemessen. Kontrolle in 3 Tagen vereinbart.", previous: nil)
        let drafts = t.segments.enumerated().map { index, source in ModelReportDraft(items: [.init(section: "Weiteres Vorgehen", text: source.text, segmentId: "q\(index + 1)", quote: source.text)], missingInformation: [], conflicts: []) }
        let engine = RepairEngine(drafts)
        let report = try await ReportPipeline(engine: engine).run(transcript: t, template: .treatment_report, length: .medium, audience: .veterinarian) { _ in }
        XCTAssertEqual(engine.prompts.count, 2)
        XCTAssertFalse(engine.prompts[1].contains("Temperatur nicht gemessen"))
        XCTAssertTrue(report.text.contains("Temperatur nicht gemessen"))
        XCTAssertTrue(report.text.contains("Kontrolle in 3 Tagen vereinbart"))
        XCTAssertTrue(report.warnings.isEmpty)
    }
    func testMemoryPressurePolicyStopsWorkBeforeReleasingModel() {
        XCTAssertEqual(MemoryPressurePolicy.action(availableBytes: 100 * 1_048_576, hasModel: true, activeWork: true), .stopActiveWork)
        XCTAssertEqual(MemoryPressurePolicy.action(availableBytes: 100 * 1_048_576, hasModel: true, activeWork: false), .releaseIdleModel)
        XCTAssertEqual(MemoryPressurePolicy.action(availableBytes: 512 * 1_048_576, hasModel: true, activeWork: true), .reclaimedCaches)
    }
    @MainActor
    func testInvalidSectionRepairsOnlyItsSourceWithoutDroppingIt() async throws {
        final class SectionEngine: ReportTextEngine {
            var calls = 0
            func generate(prompt: String, instructions: String) async throws -> String {
                calls += 1
                if calls == 1 { return #"{"items":[{"section":"Nicht erlaubter Bereich","text":"Ergebnisse stehen aus.","segmentId":"q1","quote":"Ergebnisse stehen aus."},{"section":"Befunde","text":"Kein Fieber.","segmentId":"q2","quote":"Kein Fieber."}]}"# }
                XCTAssertFalse(prompt.contains("Kein Fieber"))
                XCTAssertTrue(prompt.contains("Ungültige section-Werte: Nicht erlaubter Bereich"))
                return #"{"items":[{"section":"Weiteres Vorgehen","text":"Ergebnisse stehen aus.","segmentId":"q1","quote":"Ergebnisse stehen aus."}]}"#
            }
        }
        let engine = SectionEngine()
        let t = TranscriptBuilder.edited("Ergebnisse stehen aus. Kein Fieber.", previous: nil)
        let report = try await ReportPipeline(engine: engine).run(transcript: t, template: .treatment_report, length: .medium, audience: .veterinarian) { _ in }
        XCTAssertEqual(engine.calls, 2)
        XCTAssertTrue(report.text.contains("Ergebnisse stehen aus.")); XCTAssertTrue(report.text.contains("Kein Fieber."))
        XCTAssertTrue(report.warnings.isEmpty)
    }
    func testKnownHeadingAliasChangesNeitherFactNorSource() {
        let item = ModelReportDraft.Item(section: "Kontrolle", text: "Kontrolle in drei Tagen.", segmentId: "q1", quote: "Kontrolle in drei Tagen.")
        var draft = ModelReportDraft(items: [item], missingInformation: [], conflicts: [])
        draft.normalizeSectionAliases(for: .treatment_report)
        XCTAssertEqual(draft.items[0].section, "Weiteres Vorgehen")
        XCTAssertEqual(draft.items[0].text, item.text); XCTAssertEqual(draft.items[0].quote, item.quote)
        XCTAssertEqual(draft.items[0].segmentId, item.segmentId)
    }
    @MainActor
    func testCompletedChunkIsPersistedBeforeLaterGenerationFails() async throws {
        final class FailingLaterEngine: ReportTextEngine {
            let first: ModelReportDraft
            var calls = 0
            init(_ first: ModelReportDraft) { self.first = first }
            func generate(prompt: String, instructions: String) async throws -> String {
                calls += 1
                if calls > 1 { throw AppFailure("synthetic interruption") }
                return String(decoding: try JSONEncoder().encode(first), as: UTF8.self)
            }
        }
        let text = "Appetit vermindert. Kein Erbrechen. Temperatur nicht gemessen. Hund 12,5 kg. Kontrolle in 3 Tagen."
        let t = TranscriptBuilder.edited(text, previous: nil)
        let first = ModelReportDraft(items: t.segments.prefix(4).enumerated().map { .init(section: "Anamnese", text: $0.element.text, segmentId: "q\($0.offset + 1)", quote: $0.element.text) }, missingInformation: [], conflicts: [])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try CaseRepository(root: root, key: SymmetricKey(size: .bits256))
        let engine = FailingLaterEngine(first)
        do {
            _ = try await ReportPipeline(engine: engine).run(transcript: t, template: .treatment_report, length: .medium, audience: .veterinarian, checkpoint: { value in
                var encounter = Encounter(); encounter.transcripts = [t]; encounter.reportCheckpoint = value
                var item = VetCase(label: "Synthetic", species: "Hund"); item.encounters = [encounter]
                try await repo.save(VaultDocument(cases: [item]))
            }) { _ in }
            XCTFail("Second chunk must fail")
        } catch { XCTAssertEqual(error.localizedDescription, "synthetic interruption") }
        let restored = try await repo.load().cases.first?.encounters.first?.reportCheckpoint
        XCTAssertEqual(restored?.completedChunks, 1); XCTAssertEqual(restored?.totalChunks, 2)
        XCTAssertTrue(restored?.report.text.contains("Kein Erbrechen") == true)
        XCTAssertNil(restored?.report.approvedAt)
    }
    func testUnknownSourceRejected() {
        let (t, original) = fixture(); var report = original
        report.sections[0].items[0].sourceRefs[0].segmentId = "another-case"
        XCTAssertThrowsError(try ReportValidator.validate(report, transcript: t))
    }
    func testDuplicateSourceIDsFailInsteadOfCrashingDictionary() {
        let (original, report) = fixture(); var t = original
        t.segments.append(t.segments[0])
        XCTAssertThrowsError(try ReportValidator.validate(report, transcript: t))
    }
    func testChangedQuoteRejected() {
        let (t, original) = fixture(); var report = original
        report.sections[0].items[0].sourceRefs[0].quote = "Hund ist gesund."
        XCTAssertThrowsError(try ReportValidator.validate(report, transcript: t))
    }
    func testNegationLossWarns() throws {
        let (t, original) = fixture("Kein Fieber."); var report = original
        report.sections[0].items[0].text = "Fieber."
        XCTAssertFalse(try ReportValidator.validate(report, transcript: t).isEmpty)
    }
    func testMissingNumberWarns() throws {
        let (t, original) = fixture(); var report = original
        report.sections[0].items[0].text = "Kein Fieber."
        XCTAssertTrue(try ReportValidator.validate(report, transcript: t).contains { $0.contains("Zahlen") })
    }
    func testWrongTranscriptVersionRejected() {
        let (t, original) = fixture(); var report = original
        report.sourceTranscriptVersionId = UUID().uuidString
        XCTAssertThrowsError(try ReportValidator.validate(report, transcript: t))
    }
    func testEditedTranscriptPreservesRawAndParent() {
        let original = TranscriptBuilder.edited("Fünf, Korrektur: 0,5 mg.", previous: nil)
        let revision = TranscriptBuilder.edited("0,5 mg.", previous: original)
        XCTAssertEqual(revision.rawText, original.rawText)
        XCTAssertEqual(revision.parentID, original.id)
        XCTAssertNotEqual(revision.id, original.id)
        XCTAssertEqual(revision.segments.map(\.text).joined(), revision.editedText)
    }
    func testLongTranscriptLosesNoCharacters() {
        let text = String(repeating: "Fieber nicht gemessen. ", count: 900)
        let version = TranscriptBuilder.edited(text, previous: nil)
        XCTAssertEqual(version.segments.map(\.text).joined(), text)
        XCTAssertTrue(version.segments.allSatisfy { $0.text.count <= 900 })
    }
    func testEmptyAudioTextDoesNotBecomeNormalFinding() { XCTAssertTrue(TranscriptBuilder.edited("\n \n", previous: nil).segments.isEmpty) }
    func testEncryptedRoundTripTamperAndWrongKey() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = SymmetricKey(size: .bits256)
        let repo = try CaseRepository(root: root, key: key)
        let document = VaultDocument(cases: [VetCase(label: "SYNTHETISCH-Geheim", species: "Hund")])
        try await repo.save(document)
        let read = try await repo.load(); XCTAssertEqual(document, read)
        let url = root.appendingPathComponent("cases.sqlite")
        var bytes = try Data(contentsOf: url)
        XCTAssertNil(String(data: bytes, encoding: .utf8))
        XCTAssertNil(bytes.range(of: Data("SYNTHETISCH-Geheim".utf8)))
        do { _ = try CaseRepository(root: root, key: SymmetricKey(size: .bits256)); XCTFail("Wrong key must fail") } catch {}
        bytes[bytes.count / 2] ^= 1; try bytes.write(to: url)
        do { let changed = try CaseRepository(root: root, key: key); try await changed.verifyIntegrity(); XCTFail("Tampered database must fail") } catch {}
    }
    func testArchiveMigrationPreservesVersionsAndApproval() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try AppPaths.prepare(root)
        let key = SymmetricKey(size: .bits256)
        let (transcript, content) = fixture()
        var report = ReportVersion(content: content, modelID: "synthetic", modelRevision: "test", warnings: [])
        report.approvedAt = Date()
        var encounter = Encounter(); encounter.transcripts = [transcript]; encounter.reports = [report]
        encounter.shares = [ShareEvent(reportID: report.id, format: "Text")]
        var item = VetCase(label: "SYNTHETISCH-Migration", species: "Hund"); item.encounters = [encounter]
        let document = VaultDocument(cases: [item])
        let legacy = root.appendingPathComponent("cases.v1.aesgcm")
        let sealed = try AES.GCM.seal(JSONEncoder().encode(document), using: key, authenticating: Data("cases-v1".utf8))
        try XCTUnwrap(sealed.combined).write(to: legacy)
        let repo = try CaseRepository(root: root, key: key)
        let loaded = try await repo.load()
        XCTAssertEqual(loaded, document)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        try await repo.verifyIntegrity()
    }
    func testFailedTransactionRetainsPreviousCases() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try CaseRepository(root: root, key: SymmetricKey(size: .bits256))
        let item = VetCase(label: "SYNTHETISCH-Original", species: "Katze")
        let original = VaultDocument(cases: [item]); try await repo.save(original)
        do { try await repo.save(VaultDocument(cases: [item, item])); XCTFail("Duplicate ID must fail atomically") } catch {}
        let read = try await repo.load(); XCTAssertEqual(read, original)
    }
    func testFullDatabaseKeepsLastSavedVersion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = SymmetricKey(size: .bits256)
        let repo = try CaseRepository(root: root, key: key)
        let saved = VaultDocument(cases: [VetCase(label: "Saved synthetic case", species: "Hund")])
        try await repo.save(saved)
        try await repo.constrainDatabaseForStorageTest()
        var larger = saved; larger.cases[0].label = String(repeating: "synthetic", count: 100_000)
        do { try await repo.save(larger); XCTFail("Storage fault must fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Gerätespeicher ist voll")) }
        let restored = try await repo.load()
        XCTAssertEqual(restored, saved)
        try await repo.verifyIntegrity()
    }
    func testVocabularyPersistsWithoutChangingOriginalTranscript() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try CaseRepository(root: root, key: SymmetricKey(size: .bits256))
        let entry = VocabularyEntry(recognized: "Fach Wort", preferred: "Fachwort")
        try await repo.saveVocabulary([entry])
        let loaded = try await repo.vocabulary()
        XCTAssertEqual(loaded, [entry])
        let original = TranscriptBuilder.edited("Fach Wort unklar.", previous: nil)
        XCTAssertTrue(entry.appears(in: original.editedText))
        let edit = TranscriptBuilder.edited(entry.applying(to: original.editedText), previous: original)
        XCTAssertEqual(edit.rawText, "Fach Wort unklar.")
        XCTAssertEqual(edit.editedText, "Fachwort unklar.")
    }
    func testAudioCannotBeMovedAcrossCases() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try CaseRepository(root: root, key: SymmetricKey(size: .bits256))
        let a = UUID(), b = UUID(), e = UUID(), s = UUID()
        try await repo.storeAudio(Data("synthetic audio".utf8), caseID: a, encounterID: e, segmentID: s)
        let source = root.appendingPathComponent(a.uuidString).appendingPathComponent(e.uuidString).appendingPathComponent(s.uuidString + ".aesgcm")
        let target = root.appendingPathComponent(b.uuidString).appendingPathComponent(e.uuidString).appendingPathComponent(s.uuidString + ".aesgcm")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: target)
        do { _ = try await repo.audio(caseID: b, encounterID: e, segmentID: s); XCTFail("Cross-case move must fail authentication") } catch {}
        let valid = try await repo.audio(caseID: a, encounterID: e, segmentID: s)
        XCTAssertEqual(valid, Data("synthetic audio".utf8))
    }
    func testManifestRejectsTraversal() throws {
        let file = ModelManifest.File(name: "../config.json", bytes: 1, sha256: String(repeating: "a", count: 64))
        let manifest = ModelManifest(id: "../unsafe", revision: String(repeating: "a", count: 40), files: [file])
        XCTAssertThrowsError(try manifest.validate())
    }
    func testModelIsHashedOncePerProcessAndAgainAfterAnyChange() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let names = ["config.json", "tokenizer.json", "model.safetensors"]
        let manifest = ModelManifest(id: "synthetic/model", revision: String(repeating: "a", count: 40),
                                     files: names.map { .init(name: $0, bytes: 4, sha256: String(repeating: "b", count: 64)) })
        let repository = ModelRepository(root: root)
        XCTAssertNil(repository.currentStamps(manifest), "Incomplete model has no stamps")
        let directory = repository.directory(manifest)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in names { try Data("1234".utf8).write(to: directory.appendingPathComponent(name)) }
        var memory = ModelVerificationMemory()
        let first = repository.currentStamps(manifest)
        XCTAssertNotNil(first)
        XCTAssertTrue(memory.needsFullCheck(current: first), "First load of an app start hashes the model")
        memory.remember(first)
        XCTAssertFalse(memory.needsFullCheck(current: repository.currentStamps(manifest)), "Reloading after an app switch does not hash again")
        let later = Date().addingTimeInterval(5)
        try FileManager.default.setAttributes([.modificationDate: later], ofItemAtPath: directory.appendingPathComponent("model.safetensors").path)
        XCTAssertTrue(memory.needsFullCheck(current: repository.currentStamps(manifest)), "A changed file is hashed again")
        memory.forget()
        XCTAssertTrue(memory.needsFullCheck(current: first))
    }
    func testEncryptedAudioIsDiscoverableAfterMissingMetadataWrite() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = SymmetricKey(size: .bits256)
        let repo = try CaseRepository(root: root, key: key)
        let c = UUID(), e = UUID(), s = UUID()
        try await repo.storeAudio(Data("synthetic".utf8), caseID: c, encounterID: e, segmentID: s)
        let reopened = try CaseRepository(root: root, key: key)
        let found = try await reopened.storedAudioIDs(caseID: c, encounterID: e)
        let other = try await reopened.storedAudioIDs(caseID: UUID(), encounterID: e)
        XCTAssertEqual(found, [s]); XCTAssertTrue(other.isEmpty)
        let data = try await reopened.audio(caseID: c, encounterID: e, segmentID: s)
        XCTAssertEqual(data, Data("synthetic".utf8))
    }
    @MainActor
    func testLongPDFPreservesLastParagraphAndDraftStatus() throws {
        let (transcript, content) = fixture()
        var report = ReportVersion(content: content, modelID: "synthetic", modelRevision: "test", warnings: [])
        report.editedText = (0..<200).map { "Abschnitt \($0): \(transcript.editedText)" }.joined(separator: "\n\n") + "\nENDE-DES-SYNTHETISCHEN-BERICHTS"
        let url = try ExportService.pdf(report)
        defer { try? FileManager.default.removeItem(at: url) }
        let pdf = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertGreaterThan(pdf.pageCount, 1)
        XCTAssertTrue(pdf.string?.contains("ENTWURF") == true)
        XCTAssertTrue(pdf.string?.contains("ENDE-DES-SYNTHETISCHEN-BERICHTS") == true)
        XCTAssertTrue(pdf.string?.contains("Abschnitt 199") == true)
    }
    @MainActor
    func testReportPipelineHasOneRepairAttemptAndNoSilentFallback() async {
        final class BrokenEngine: ReportTextEngine {
            var calls = 0
            func generate(prompt: String, instructions: String) async throws -> String { calls += 1; return "not JSON" }
        }
        let engine = BrokenEngine()
        do {
            _ = try await ReportPipeline(engine: engine).run(transcript: fixture().0, template: .soap, length: .short, audience: .veterinarian) { _ in }
            XCTFail("Invalid JSON must not become a report")
        } catch { XCTAssertEqual(engine.calls, 2) }
    }
}
