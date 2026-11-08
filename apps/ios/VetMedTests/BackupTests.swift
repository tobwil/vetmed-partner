import XCTest
@testable import VetMed

/// Encrypted backup (ADR 0019). Same cases as Android `BackupTests`, plus opening the backup Android wrote.
@MainActor
final class BackupTests: XCTestCase {
    private let password = "Grüne Wiese 2026"
    private let caseID = UUID(uuidString: "6B1E3C2A-0D51-4E0B-9F1A-1C2D3E4F5A60")!
    private let encounterID = UUID(uuidString: "0C7E5B1D-2A3F-4B6C-8D9E-0F1A2B3C4D5E")!
    private let audioID = UUID(uuidString: "9A8B7C6D-5E4F-4A3B-2C1D-0E9F8A7B6C5D")!
    private let photoID = UUID(uuidString: "1F2E3D4C-5B6A-4978-8695-A4B3C2D1E0F9")!
    private let checkID = UUID(uuidString: "2E3F4A5B-6C7D-4E8F-9A0B-1C2D3E4F5A6B")!
    private let pdfID = UUID(uuidString: "3F4A5B6C-7D8E-4F9A-0B1C-2D3E4F5A6B7C")!

    private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    /// The Android fixture: test bundle on the Mac, `VETMED_SHARED` or the source tree elsewhere.
    private func fixture() throws -> Data {
        let name = "backup-v1-synthetic"
        #if !SWIFT_PACKAGE
        if let url = Bundle(for: Self.self).url(forResource: name, withExtension: "vetmedbackup") { return try Data(contentsOf: url) }
        #endif
        let shared = ProcessInfo.processInfo.environment["VETMED_SHARED"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("shared")
        return try Data(contentsOf: shared.appendingPathComponent("fixtures/\(name).vetmedbackup"))
    }

    private var files: [String: Data] {
        ["attachment/\(caseID)/\(encounterID)/\(photoID)/original": Data("PHOTO".utf8),
         "attachment/\(caseID)/\(encounterID)/\(photoID)/upload": Data("JPG".utf8),
         "attachment/quick/\(checkID)/\(pdfID)/original": Data("%PDF".utf8),
         "audio/\(caseID)/\(encounterID)/\(audioID)": Data((0..<3000).map { UInt8($0 % 251) })]
    }

    private func restore(_ data: Data, local: VaultDocument = VaultDocument(), password: String? = nil) throws -> (BackupContent.Restored, [String: Data]) {
        var offset = 0
        var stored: [String: Data] = [:]
        let result = try BackupContent.restore(source: { count in
            let end = min(offset + count, data.count); defer { offset = end }
            return data.subdata(in: offset..<end)
        }, password: password ?? self.password, local: local, localVocabulary: []) { file, bytes in stored[file.name] = bytes }
        return (result, stored)
    }

    private func fails(_ text: String, _ block: () throws -> Void, line: UInt = #line) {
        do { try block(); XCTFail("must fail: \(text)", line: line) }
        catch { XCTAssertTrue(error.localizedDescription.contains(text), error.localizedDescription, line: line) }
    }

    func testKeyDerivationMatchesTheStandardAndAndroid() async throws {
        XCTAssertEqual(hex(BackupFormat.pbkdf2(password: Data("passwd".utf8), salt: Data("salt".utf8), iterations: 1, length: 64)),
                       "55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc49ca9cccf179b645991664b39d77ef317c71b845b1e30bd509112041d3a19783")
        XCTAssertEqual(hex(BackupFormat.pbkdf2(password: BackupFormat.passwordBytes(password), salt: Data("vetmed-salt-0001".utf8), iterations: 1000)),
                       "f8310ac2f5c7c9515b3ed66b866de3ae3e164528c50ae1512ab9e74cea385687")
        XCTAssertEqual(BackupFormat.passwordBytes("Grüne"), BackupFormat.passwordBytes("Gru\u{0308}ne"))
    }

    func testPasswordRules() async throws {
        fails("mindestens 10 Zeichen") { try BackupFormat.checkNewPassword("kurz", repeated: "kurz") }
        fails("Leerzeichen") { try BackupFormat.checkNewPassword("            ", repeated: "            ") }
        fails("stimmen nicht überein") { try BackupFormat.checkNewPassword(password, repeated: password + "!") }
        try BackupFormat.checkNewPassword(password, repeated: password)
    }

    func testTheBackupWrittenOnAndroidOpensWithAllFiles() async throws {
        let (result, stored) = try restore(try fixture())
        XCTAssertEqual(result.manifest.platform, "android")
        XCTAssertEqual(result.document.cases.first?.animalName, "Testhund")
        XCTAssertEqual(result.document.cases.first?.encounters.first?.transcripts.first?.editedText, "Kein Fieber.")
        XCTAssertEqual(result.document.quickChecks?.first?.id, checkID)
        XCTAssertEqual(result.vocabulary.first?.preferred, "Meloxicam")
        XCTAssertEqual(Set(stored.keys), Set(files.keys))
        for (name, data) in files { XCTAssertEqual(stored[name], data, name) }
        XCTAssertEqual(result.summary, "1 Fall und 1 Schnellcheck wiederhergestellt.")
        fails("Passwort ist falsch") { _ = try self.restore(try self.fixture(), password: "Falsches Passwort 1") }
    }

    func testAnIOSBackupRoundTripsAndNeverOverwrites() async throws {
        let android = try restore(try fixture()).0
        var out = Data()
        let written = try BackupContent.write(sink: { out.append($0) }, password: password, document: android.document, vocabulary: android.vocabulary,
                                              includeAudio: false, iterations: 1_000) { self.files[$0.name] }
        XCTAssertEqual(written.files, 3); XCTAssertEqual(written.missing, 0)
        for secret in ["Testhund", "Kein Fieber", "PHOTO", "Meloxikam"] { XCTAssertNil(out.range(of: Data(secret.utf8)), secret) }
        let (again, stored) = try restore(out)
        XCTAssertEqual(again.document, android.document)
        XCTAssertEqual(stored.count, 3); XCTAssertEqual(again.missingFiles, 1)
        XCTAssertTrue(again.summary.contains("Aufnahmen nicht mitgesichert"))
        // Restoring onto a device that already has the case changes nothing there.
        var local = android.document; local.cases[0].label = "Lokal geändert"; local.quickChecks = nil
        let (merged, mergedFiles) = try restore(out, local: local)
        XCTAssertEqual(merged.document.cases.map(\.label), ["Lokal geändert"])
        XCTAssertEqual(Set(mergedFiles.keys), ["attachment/quick/\(checkID)/\(pdfID)/original"])
    }

    func testDamageAndCutOffsAreRefused() async throws {
        let bytes = try fixture()
        fails("beschädigt") { var copy = bytes; copy[copy.count / 2] ^= 1; _ = try self.restore(copy) }
        fails("unvollständig") { _ = try self.restore(bytes.prefix(bytes.count - 10)) }
        fails("keine VetMed-Sicherung") { _ = try self.restore(Data("%PDF-1.7 synthetic".utf8)) }
        fails("beschädigt") { _ = try self.restore(bytes + Data([0, 0, 0, 20]) + Data(count: 20)) }
        XCTAssertNil(BackupFile.parse("audio/../x/y")); XCTAssertNil(BackupFile.parse("attachment/a/b/c/original"))
        XCTAssertEqual(BackupFile.parse("audio/\(caseID)/\(encounterID)/\(audioID)"), .audio(caseID: caseID, encounterID: encounterID, segmentID: audioID))
    }
}
