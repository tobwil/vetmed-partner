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
    /// What the database holds after the last read or successful write; nil means "unknown, write everything".
    private var written: CaseRows.Snapshot?
    private var writtenDataVersion: Int64?
    /// Rows touched by the last save. Tests use it to prove that saves stay proportional to the change.
    struct WriteStats: Equatable, Sendable { let inserted: Int; let updated: Int; let deleted: Int; let full: Bool }
    private(set) var lastWrite: WriteStats?
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
        migrator.registerMigration("quick-check-v1") { db in
            try db.execute(sql: "CREATE TABLE quick_check (id TEXT PRIMARY KEY NOT NULL, position INTEGER NOT NULL, payload BLOB NOT NULL)")
        }
        try migrator.migrate(database)
        let legacy = root.appendingPathComponent("cases.v1.aesgcm")
        if FileManager.default.fileExists(atPath: legacy.path) {
            let count = try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM clinical_case") ?? 0 }
            let data = try AES.GCM.open(AES.GCM.SealedBox(combined: Data(contentsOf: legacy)), using: key, authenticating: Data("cases-v1".utf8))
            let document = try JSONDecoder().decode(VaultDocument.self, from: data)
            if count == 0 { try Self.replaceAll(try CaseRows(document), in: database) }
            guard try Self.read(database) == document else { throw AppFailure("Migration konnte nicht vollständig bestätigt werden. Die alte verschlüsselte Datei bleibt erhalten.") }
            try FileManager.default.removeItem(at: legacy)
        }
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: root.appendingPathComponent("cases.sqlite").path)
    }
    func load() throws -> VaultDocument {
        written = nil; writtenDataVersion = nil
        let (document, snapshot, version) = try database.read { db in
            (try Self.decode(db), try CaseRows.stored(db), try Int64.fetchOne(db, sql: "PRAGMA data_version"))
        }
        written = snapshot; writtenDataVersion = version
        return document
    }
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
        do { try write(document) }
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
        try database.read { try decode($0) }
    }
    private static func decode(_ db: Database) throws -> VaultDocument {
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
        let quickChecks = try Row.fetchAll(db, sql: "SELECT payload FROM quick_check ORDER BY position").map { try decoder.decode(QuickCheck.self, from: $0["payload"] as Data) }
        return VaultDocument(cases: cases, quickChecks: quickChecks.isEmpty ? nil : quickChecks)
    }
    /// Writes only the rows that differ from the database, in one transaction. Before, every save (autosave,
    /// every second of a streaming chat answer, every audio segment) deleted and rewrote the whole store with
    /// secure_delete. If the known state is missing or turns out to be wrong, everything is written as before;
    /// after any failure the known state is dropped, so the next save starts from a full write again.
    private func write(_ document: VaultDocument) throws {
        guard document.schemaVersion == 1 else { throw AppFailure("Unbekannte Speicherversion.") }
        let rows = try CaseRows(document)
        // Duplicate IDs would silently collapse in the difference; the full write rejected them via the primary key.
        guard rows.hasUniqueIDs else { throw AppFailure("Speichern fehlgeschlagen: doppelte Kennungen. Die letzte gespeicherte Fassung bleibt erhalten.") }
        let previous = written, previousVersion = writtenDataVersion
        written = nil; writtenDataVersion = nil
        let result: (WriteStats, Int64?)
        do {
            result = try database.write { db in
                // DatabaseQueue uses one connection. Compare on that connection inside the write transaction,
                // including no-op saves: a second writer may have changed an otherwise untouched row.
                let version = try Int64.fetchOne(db, sql: "PRAGMA data_version")
                if let previous, let previousVersion, previousVersion == version {
                    let changes = RowChanges(previous: previous, next: rows)
                    try changes.apply(db)
                    return (WriteStats(inserted: changes.inserts.count, updated: changes.updates.count, deleted: changes.deletedCount, full: false), version)
                }
                try Self.replaceRows(rows, in: db)
                return (WriteStats(inserted: rows.entries.count, updated: 0, deleted: 0, full: true), version)
            }
        } catch let error as DatabaseError where error.resultCode == .SQLITE_FULL {
            throw error
        } catch {
            // The failed transaction rolled back. Preserve the previous full-document save semantics.
            result = try database.write { db in
                try Self.replaceRows(rows, in: db)
                return (WriteStats(inserted: rows.entries.count, updated: 0, deleted: 0, full: true), try Int64.fetchOne(db, sql: "PRAGMA data_version"))
            }
        }
        lastWrite = result.0; writtenDataVersion = result.1; written = rows.snapshot
    }
    private static func replaceAll(_ rows: CaseRows, in database: DatabaseQueue) throws {
        try database.write { try replaceRows(rows, in: $0) }
    }
    private static func replaceRows(_ rows: CaseRows, in db: Database) throws {
        // A single transaction makes replacement all-or-nothing, including every version and share event.
        for table in CaseRows.Table.allCases.reversed() { try db.execute(sql: "DELETE FROM \(table.rawValue)") }
        for entry in rows.entries { try RowChanges.insert(entry, into: db) }
    }
    private func attachmentURL(caseID: UUID?, encounterID: UUID, id: UUID, upload: Bool) -> URL {
        root.appendingPathComponent("ChatAttachments").appendingPathComponent(caseID?.uuidString ?? "QuickChecks")
            .appendingPathComponent(encounterID.uuidString).appendingPathComponent(id.uuidString + (upload ? "-upload" : "-original") + ".aesgcm")
    }
    func storeAttachment(_ value: PreparedChatAttachment, caseID: UUID?, encounterID: UUID) throws {
        let original = attachmentURL(caseID: caseID, encounterID: encounterID, id: value.attachment.id, upload: false)
        try AppPaths.prepare(original.deletingLastPathComponent())
        let available = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
        guard available > Int64((value.original.count + (value.upload?.count ?? 0)) * 3 + 20_000_000) else { throw AppFailure("Zu wenig Gerätespeicher für diesen Anhang. Bitte Speicher freigeben.") }
        let context = "chat-attachment-v1/\(caseID?.uuidString ?? "quick")/\(encounterID)/\(value.attachment.id)"
        try encrypt(value.original, context: context + "/original").write(to: original, options: [.atomic, .completeFileProtection])
        if let upload = value.upload {
            do {
                try encrypt(upload, context: context + "/upload").write(to: attachmentURL(caseID: caseID, encounterID: encounterID, id: value.attachment.id, upload: true), options: [.atomic, .completeFileProtection])
            } catch { try? FileManager.default.removeItem(at: original); throw error }
        }
    }
    func attachmentData(caseID: UUID?, encounterID: UUID, id: UUID, upload: Bool) throws -> Data {
        let url = attachmentURL(caseID: caseID, encounterID: encounterID, id: id, upload: upload)
        let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        let maximum = upload ? ChatAttachmentImporter.maximumImageBytes : ChatAttachmentImporter.maximumOriginalBytes
        guard bytes <= maximum + 128 else { throw AppFailure("Der gespeicherte Anhang überschreitet sein Größenlimit.") }
        return try decrypt(Data(contentsOf: url), context: "chat-attachment-v1/\(caseID?.uuidString ?? "quick")/\(encounterID)/\(id)/\(upload ? "upload" : "original")")
    }
    func removeAttachment(caseID: UUID?, encounterID: UUID, id: UUID) throws {
        for upload in [false, true] {
            let url = attachmentURL(caseID: caseID, encounterID: encounterID, id: id, upload: upload)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }
    func removeQuickCheckFiles(_ id: UUID) throws {
        let url = root.appendingPathComponent("ChatAttachments/QuickChecks").appendingPathComponent(id.uuidString)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    func cleanUnreferencedAttachments(_ document: VaultDocument) throws {
        var keep = Set<URL>()
        func retain(_ attachments: [ChatAttachment], caseID: UUID?, encounterID: UUID) {
            for attachment in attachments {
                keep.insert(attachmentURL(caseID: caseID, encounterID: encounterID, id: attachment.id, upload: false))
                if attachment.uploadSHA256 != nil { keep.insert(attachmentURL(caseID: caseID, encounterID: encounterID, id: attachment.id, upload: true)) }
            }
        }
        for item in document.cases { for encounter in item.encounters { retain(encounter.chatAttachments ?? [], caseID: item.id, encounterID: encounter.id) } }
        for check in document.quickChecks ?? [] { retain(check.chatAttachments ?? [], caseID: nil, encounterID: check.id) }
        let directory = root.appendingPathComponent("ChatAttachments")
        guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return }
        for case let url as URL in files {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { files.skipDescendants(); continue }
            if values.isRegularFile == true, url.pathExtension == "aesgcm", !keep.contains(url) { try FileManager.default.removeItem(at: url) }
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
        let attachments = root.appendingPathComponent("ChatAttachments").appendingPathComponent(id.uuidString)
        if FileManager.default.fileExists(atPath: attachments.path) { try FileManager.default.removeItem(at: attachments) }
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

/// The rows of one save, built from the document with the same layout as before: one row per case, encounter
/// and version with a JSON payload and a position. Pure, so the difference logic is testable without a database.
struct CaseRows: Sendable {
    /// Parents before children; deletions run in reverse.
    enum Table: String, CaseIterable, Sendable {
        case clinicalCase = "clinical_case", encounter, transcriptVersion = "transcript_version"
        case reportVersion = "report_version", shareEvent = "share_event", quickCheck = "quick_check"
        var parentColumn: String? {
            switch self {
            case .encounter: return "caseID"
            case .transcriptVersion, .reportVersion, .shareEvent: return "encounterID"
            case .clinicalCase, .quickCheck: return nil
            }
        }
    }
    /// What is stored for one row, without its content: parent, position and a SHA-256 of the payload.
    struct State: Equatable, Sendable { let parent: String?; let position: Int; let digest: Data }
    struct Entry: Sendable { let table: Table; let id: String; let parent: String?; let position: Int; let payload: Data }
    typealias Snapshot = [Table: [String: State]]

    let entries: [Entry]
    let snapshot: Snapshot
    let hasUniqueIDs: Bool

    init(_ document: VaultDocument) throws {
        let encoder = JSONEncoder()
        // Stable key order keeps the digest of an unchanged value unchanged.
        encoder.outputFormatting = [.sortedKeys]
        var entries: [Entry] = []
        func add<Value: Encodable>(_ table: Table, _ id: UUID, _ parent: UUID?, _ position: Int, _ value: Value) throws {
            entries.append(Entry(table: table, id: id.uuidString, parent: parent?.uuidString, position: position, payload: try encoder.encode(value)))
        }
        for (position, original) in document.cases.enumerated() {
            var item = original; item.encounters = []
            try add(.clinicalCase, item.id, nil, position, item)
            for (index, originalEncounter) in original.encounters.enumerated() {
                var encounter = originalEncounter; encounter.transcripts = []; encounter.reports = []; encounter.shares = []
                try add(.encounter, encounter.id, item.id, index, encounter)
                for (n, value) in originalEncounter.transcripts.enumerated() { try add(.transcriptVersion, value.id, encounter.id, n, value) }
                for (n, value) in originalEncounter.reports.enumerated() { try add(.reportVersion, value.id, encounter.id, n, value) }
                for (n, value) in originalEncounter.shares.enumerated() { try add(.shareEvent, value.id, encounter.id, n, value) }
            }
        }
        for (position, check) in (document.quickChecks ?? []).enumerated() { try add(.quickCheck, check.id, nil, position, check) }
        var snapshot: Snapshot = [:]
        for table in Table.allCases { snapshot[table] = [:] }
        for entry in entries {
            snapshot[entry.table, default: [:]][entry.id] = State(parent: entry.parent, position: entry.position, digest: Data(SHA256.hash(data: entry.payload)))
        }
        self.entries = entries
        self.snapshot = snapshot
        hasUniqueIDs = snapshot.values.reduce(0) { $0 + $1.count } == entries.count
    }

    /// The state of the rows as they are stored, read once when the cases are opened.
    static func stored(_ db: Database) throws -> Snapshot {
        var snapshot: Snapshot = [:]
        for table in Table.allCases {
            let parent = table.parentColumn ?? "NULL"
            var states: [String: State] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT id, \(parent) AS parent, position, payload FROM \(table.rawValue)") {
                let id: String = row["id"]
                let parentID: String? = row["parent"]
                let position: Int = row["position"]
                let payload: Data = row["payload"]
                states[id] = State(parent: parentID, position: position, digest: Data(SHA256.hash(data: payload)))
            }
            snapshot[table] = states
        }
        return snapshot
    }
}

/// The difference between what the database holds and the next document: only these rows are written.
struct RowChanges: Sendable {
    let inserts: [CaseRows.Entry]
    let updates: [CaseRows.Entry]
    let deletions: [CaseRows.Table: [String]]
    var deletedCount: Int { deletions.values.reduce(0) { $0 + $1.count } }
    var isEmpty: Bool { inserts.isEmpty && updates.isEmpty && deletedCount == 0 }

    init(previous: CaseRows.Snapshot, next: CaseRows) {
        var inserts: [CaseRows.Entry] = [], updates: [CaseRows.Entry] = []
        for entry in next.entries {
            let before = previous[entry.table]?[entry.id]
            guard before != next.snapshot[entry.table]?[entry.id] else { continue }
            if before == nil { inserts.append(entry) } else { updates.append(entry) }
        }
        var deletions: [CaseRows.Table: [String]] = [:]
        for table in CaseRows.Table.allCases {
            let remaining = Set(next.snapshot[table]?.keys.map { $0 } ?? [])
            deletions[table] = (previous[table]?.keys.map { $0 } ?? []).filter { !remaining.contains($0) }
        }
        self.inserts = inserts; self.updates = updates; self.deletions = deletions
    }

    /// Updates never delete a row first, so ON DELETE CASCADE cannot remove versions of an unchanged encounter.
    /// Children are deleted before and inserted after their parents.
    func apply(_ db: Database) throws {
        for table in CaseRows.Table.allCases.reversed() {
            for id in deletions[table] ?? [] { try db.execute(sql: "DELETE FROM \(table.rawValue) WHERE id = ?", arguments: [id]) }
        }
        for entry in inserts { try Self.insert(entry, into: db) }
        for entry in updates {
            if let column = entry.table.parentColumn {
                try db.execute(sql: "UPDATE \(entry.table.rawValue) SET \(column) = ?, position = ?, payload = ? WHERE id = ?",
                               arguments: [entry.parent, entry.position, entry.payload, entry.id])
            } else {
                try db.execute(sql: "UPDATE \(entry.table.rawValue) SET position = ?, payload = ? WHERE id = ?",
                               arguments: [entry.position, entry.payload, entry.id])
            }
            // A row that should exist but does not means the known state is wrong: roll back, write everything.
            guard db.changesCount == 1 else { throw AppFailure("Gespeicherter Stand weicht ab.") }
        }
    }

    static func insert(_ entry: CaseRows.Entry, into db: Database) throws {
        if let column = entry.table.parentColumn {
            try db.execute(sql: "INSERT INTO \(entry.table.rawValue) (id, \(column), position, payload) VALUES (?, ?, ?, ?)",
                           arguments: [entry.id, entry.parent, entry.position, entry.payload])
        } else {
            try db.execute(sql: "INSERT INTO \(entry.table.rawValue) (id, position, payload) VALUES (?, ?, ?)",
                           arguments: [entry.id, entry.position, entry.payload])
        }
    }
}
