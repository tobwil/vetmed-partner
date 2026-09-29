import Foundation
import CryptoKit
import Security
import GRDB

enum AppPaths {
    static var root: URL { URL.applicationSupportDirectory.appendingPathComponent("VetMed", isDirectory: true) }
    static var scratch: URL { root.appendingPathComponent("Scratch", isDirectory: true) }
    static var exports: URL { root.appendingPathComponent("Exports", isDirectory: true) }
    static func prepare(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete])
        var url = directory, values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
    static func clean(_ directory: URL) throws {
        try prepare(directory)
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            try FileManager.default.removeItem(at: file)
        }
    }
}
struct SecureStore: Sendable {
    var service = "de.tobwil.vetmed.secrets"
    func read(_ account: String) throws -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        if status == errSecMissingEntitlement { throw AppFailure("Diesem App-Build fehlt die Schlüsselbund-Berechtigung. Bitte einen korrekt signierten Build installieren.") }
        guard status == errSecSuccess, let data = result as? Data else { throw AppFailure("Schlüsselbund ist nicht verfügbar (\(status)). Bitte Gerät entsperren.") }
        return data
    }
    func write(_ data: Data, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let insert = query.merging(attributes) { _, new in new }
            let added = SecItemAdd(insert as CFDictionary, nil)
            guard added == errSecSuccess else { throw AppFailure("Schlüssel konnte nicht gespeichert werden (\(added)).") }
        } else if status != errSecSuccess { throw AppFailure("Schlüssel konnte nicht aktualisiert werden (\(status)).") }
    }
    func vaultKey(existingData: Bool) throws -> SymmetricKey {
        if let data = try read("vault-key-v1") {
            guard data.count == 32 else { throw AppFailure("Ungültiger Speicherschlüssel.") }
            return SymmetricKey(data: data)
        }
        guard !existingData else { throw AppFailure("Der Schlüssel zu vorhandenen Daten fehlt. Daten werden nicht überschrieben.") }
        let key = SymmetricKey(size: .bits256)
        try write(key.withUnsafeBytes { Data($0) }, account: "vault-key-v1")
        return key
    }
    func delete(_ account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AppFailure("Schlüssel konnte nicht entfernt werden (\(status)).") }
    }
}

/// SQLCipher protects metadata, all clinical content and SQLite journals. Audio uses case-bound AES-GCM.
actor CaseRepository {
    let root: URL
    private let key: SymmetricKey
    private let database: DatabaseQueue
    static func hasExistingData(at root: URL) -> Bool {
        ["cases.sqlite", "cases.v1.aesgcm"].contains { FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }
    }
    init(root: URL = AppPaths.root, key: SymmetricKey) throws {
        self.root = root; self.key = key
        try AppPaths.prepare(root)
        let passphrase = key.withUnsafeBytes { Data($0) }
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.usePassphrase(passphrase)
            guard let version = try String.fetchOne(db, sql: "PRAGMA cipher_version"), !version.isEmpty else {
                throw AppFailure("SQLCipher ist nicht aktiv. Kein unverschlüsselter Fallspeicher wird angelegt.")
            }
            try db.execute(sql: "PRAGMA cipher_memory_security = ON; PRAGMA secure_delete = ON")
        }
        database = try DatabaseQueue(path: root.appendingPathComponent("cases.sqlite").path, configuration: configuration)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("clinical-schema-v1") { db in
            try db.execute(sql: """
            CREATE TABLE clinical_case (id TEXT PRIMARY KEY NOT NULL, position INTEGER NOT NULL, payload BLOB NOT NULL);
            CREATE TABLE encounter (id TEXT PRIMARY KEY NOT NULL, caseID TEXT NOT NULL REFERENCES clinical_case(id) ON DELETE CASCADE, position INTEGER NOT NULL, payload BLOB NOT NULL);
            CREATE TABLE transcript_version (id TEXT PRIMARY KEY NOT NULL, encounterID TEXT NOT NULL REFERENCES encounter(id) ON DELETE CASCADE, position INTEGER NOT NULL, payload BLOB NOT NULL);
            CREATE TABLE report_version (id TEXT PRIMARY KEY NOT NULL, encounterID TEXT NOT NULL REFERENCES encounter(id) ON DELETE CASCADE, position INTEGER NOT NULL, payload BLOB NOT NULL);
            CREATE TABLE share_event (id TEXT PRIMARY KEY NOT NULL, encounterID TEXT NOT NULL REFERENCES encounter(id) ON DELETE CASCADE, position INTEGER NOT NULL, payload BLOB NOT NULL);
            CREATE INDEX encounter_case ON encounter(caseID);
            CREATE INDEX transcript_encounter ON transcript_version(encounterID);
            CREATE INDEX report_encounter ON report_version(encounterID);
            CREATE INDEX share_encounter ON share_event(encounterID);
            """)
        }
        migrator.registerMigration("vocabulary-v1") { db in
            try db.execute(sql: "CREATE TABLE vocabulary (id TEXT PRIMARY KEY NOT NULL, position INTEGER NOT NULL, payload BLOB NOT NULL)")
        }
        try migrator.migrate(database)
        let legacy = root.appendingPathComponent("cases.v1.aesgcm")
        if FileManager.default.fileExists(atPath: legacy.path) {
            let count = try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM clinical_case") ?? 0 }
            let data = try AES.GCM.open(AES.GCM.SealedBox(combined: Data(contentsOf: legacy)), using: key, authenticating: Data("cases-v1".utf8))
            let document = try JSONDecoder().decode(VaultDocument.self, from: data)
            if count == 0 { try Self.write(document, to: database) }
            guard try Self.read(database) == document else { throw AppFailure("Migration konnte nicht vollständig bestätigt werden. Die alte verschlüsselte Datei bleibt erhalten.") }
            try FileManager.default.removeItem(at: legacy)
        }
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: root.appendingPathComponent("cases.sqlite").path)
    }
    func load() throws -> VaultDocument { try Self.read(database) }
    func vocabulary() throws -> [VocabularyEntry] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT payload FROM vocabulary ORDER BY position").map { try JSONDecoder().decode(VocabularyEntry.self, from: $0["payload"] as Data) }
        }
    }
    func saveVocabulary(_ entries: [VocabularyEntry]) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM vocabulary")
            for (position, entry) in entries.enumerated() {
                try db.execute(sql: "INSERT INTO vocabulary VALUES (?, ?, ?)", arguments: [entry.id.uuidString, position, try JSONEncoder().encode(entry)])
            }
        }
    }
    func save(_ document: VaultDocument) throws {
        do { try Self.write(document, to: database) }
        catch let error as DatabaseError where error.resultCode == .SQLITE_FULL {
            throw AppFailure("Der Gerätespeicher ist voll. Die letzte gespeicherte Fassung bleibt erhalten. Bitte Speicher freigeben und erneut speichern.")
        }
    }
    #if DEBUG
    /// Real SQLite SQLITE_FULL fault without filling the host or phone volume.
    func constrainDatabaseForStorageTest() throws {
        try database.writeWithoutTransaction { db in
            let pages = try Int.fetchOne(db, sql: "PRAGMA page_count") ?? 0
            try db.execute(sql: "PRAGMA max_page_count = \(pages + 1)")
        }
    }
    #endif
    func verifyIntegrity() throws {
        try database.read { db in
            let cipherProblems = try String.fetchAll(db, sql: "PRAGMA cipher_integrity_check")
            let sqliteResult = try String.fetchOne(db, sql: "PRAGMA integrity_check")
            guard cipherProblems.isEmpty, sqliteResult == "ok" else { throw AppFailure("Die verschlüsselte Datenbank ist beschädigt.") }
        }
    }
    private static func read(_ database: DatabaseQueue) throws -> VaultDocument {
        try database.read { db in
            let decoder = JSONDecoder()
            var cases: [VetCase] = []
            for row in try Row.fetchAll(db, sql: "SELECT payload FROM clinical_case ORDER BY position") {
                var item = try decoder.decode(VetCase.self, from: row["payload"] as Data)
                for encounterRow in try Row.fetchAll(db, sql: "SELECT payload FROM encounter WHERE caseID = ? ORDER BY position", arguments: [item.id.uuidString]) {
                    var encounter = try decoder.decode(Encounter.self, from: encounterRow["payload"] as Data)
                    encounter.transcripts = try Row.fetchAll(db, sql: "SELECT payload FROM transcript_version WHERE encounterID = ? ORDER BY position", arguments: [encounter.id.uuidString]).map { try decoder.decode(TranscriptVersion.self, from: $0["payload"] as Data) }
                    encounter.reports = try Row.fetchAll(db, sql: "SELECT payload FROM report_version WHERE encounterID = ? ORDER BY position", arguments: [encounter.id.uuidString]).map { try decoder.decode(ReportVersion.self, from: $0["payload"] as Data) }
                    encounter.shares = try Row.fetchAll(db, sql: "SELECT payload FROM share_event WHERE encounterID = ? ORDER BY position", arguments: [encounter.id.uuidString]).map { try decoder.decode(ShareEvent.self, from: $0["payload"] as Data) }
                    item.encounters.append(encounter)
                }
                cases.append(item)
            }
            return VaultDocument(cases: cases)
        }
    }
    private static func write(_ document: VaultDocument, to database: DatabaseQueue) throws {
        guard document.schemaVersion == 1 else { throw AppFailure("Unbekannte Speicherversion.") }
        try database.write { db in
            let encoder = JSONEncoder()
            // A single transaction makes replacement all-or-nothing, including every version and share event.
            try db.execute(sql: "DELETE FROM clinical_case")
            for (position, original) in document.cases.enumerated() {
                var item = original; item.encounters = []
                try db.execute(sql: "INSERT INTO clinical_case VALUES (?, ?, ?)", arguments: [item.id.uuidString, position, try encoder.encode(item)])
                for (index, originalEncounter) in original.encounters.enumerated() {
                    var encounter = originalEncounter; encounter.transcripts = []; encounter.reports = []; encounter.shares = []
                    try db.execute(sql: "INSERT INTO encounter VALUES (?, ?, ?, ?)", arguments: [encounter.id.uuidString, item.id.uuidString, index, try encoder.encode(encounter)])
                    for (n, value) in originalEncounter.transcripts.enumerated() { try db.execute(sql: "INSERT INTO transcript_version VALUES (?, ?, ?, ?)", arguments: [value.id.uuidString, encounter.id.uuidString, n, try encoder.encode(value)]) }
                    for (n, value) in originalEncounter.reports.enumerated() { try db.execute(sql: "INSERT INTO report_version VALUES (?, ?, ?, ?)", arguments: [value.id.uuidString, encounter.id.uuidString, n, try encoder.encode(value)]) }
                    for (n, value) in originalEncounter.shares.enumerated() { try db.execute(sql: "INSERT INTO share_event VALUES (?, ?, ?, ?)", arguments: [value.id.uuidString, encounter.id.uuidString, n, try encoder.encode(value)]) }
                }
            }
        }
    }
    func storeAudio(_ data: Data, caseID: UUID, encounterID: UUID, segmentID: UUID) throws {
        let location = audioURL(caseID, encounterID, segmentID)
        try AppPaths.prepare(location.deletingLastPathComponent())
        try encrypt(data, context: "\(caseID)/\(encounterID)/\(segmentID)").write(to: location, options: [.atomic, .completeFileProtection])
    }
    func audio(caseID: UUID, encounterID: UUID, segmentID: UUID) throws -> Data {
        try decrypt(Data(contentsOf: audioURL(caseID, encounterID, segmentID)), context: "\(caseID)/\(encounterID)/\(segmentID)")
    }
    func storedAudioIDs(caseID: UUID, encounterID: UUID) throws -> [UUID] {
        let directory = root.appendingPathComponent(caseID.uuidString).appendingPathComponent(encounterID.uuidString)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])
            .filter { $0.pathExtension == "aesgcm" }
            .sorted { ((try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) < ((try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) }
            .compactMap { UUID(uuidString: $0.deletingPathExtension().lastPathComponent) }
    }
    func removeCaseFiles(_ id: UUID) throws {
        let location = root.appendingPathComponent(id.uuidString, isDirectory: true)
        if FileManager.default.fileExists(atPath: location.path) { try FileManager.default.removeItem(at: location) }
    }
    private func audioURL(_ c: UUID, _ e: UUID, _ s: UUID) -> URL {
        root.appendingPathComponent(c.uuidString).appendingPathComponent(e.uuidString).appendingPathComponent(s.uuidString + ".aesgcm")
    }
    private func encrypt(_ data: Data, context: String) throws -> Data {
        guard let sealed = try AES.GCM.seal(data, using: key, authenticating: Data(context.utf8)).combined else { throw AppFailure("Verschlüsselung fehlgeschlagen.") }
        return sealed
    }
    private func decrypt(_ data: Data, context: String) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key, authenticating: Data(context.utf8))
    }
}
