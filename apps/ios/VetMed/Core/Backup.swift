import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(CommonCrypto)
import CommonCrypto
#endif

/// Password-protected backup of all cases (ADR 0019), byte-compatible with Android's `BackupFormat`: a backup made on
/// one platform opens on the other.
///
///     header  "VMBK" | version u8 | iterations u32 | salt 16 | chunk size u32          (29 bytes, big endian)
///     chunk   length u32 | ciphertext with tag                                      nonce = 0000 | index u64
///
/// Every chunk authenticates the header, its index and whether it is the last one.
enum BackupFormat {
    static let magic = Data("VMBK".utf8)
    static let version: UInt8 = 1
    static let headerBytes = 29
    static let defaultIterations = 600_000
    static let chunkBytes = 1 << 20
    static let tagBytes = 16
    static let minimumPassword = 10
    static let fileExtension = "vetmedbackup"

    /// Unicode-normalized UTF-8, so "ü" typed on iOS and on Android gives the same key.
    static func passwordBytes(_ password: String) -> Data { Data(password.precomposedStringWithCanonicalMapping.utf8) }

    static func checkNewPassword(_ password: String, repeated: String) throws {
        guard password.count >= minimumPassword else { throw AppFailure("Das Passwort braucht mindestens \(minimumPassword) Zeichen.") }
        guard !password.trimmingCharacters(in: .whitespaces).isEmpty else { throw AppFailure("Das Passwort darf nicht nur aus Leerzeichen bestehen.") }
        guard password == repeated else { throw AppFailure("Die beiden Passwörter stimmen nicht überein.") }
    }

    /// PBKDF2-HMAC-SHA256 (RFC 8018). CommonCrypto on Apple platforms; the same algorithm written out elsewhere.
    static func pbkdf2(password: Data, salt: Data, iterations: Int, length: Int = 32) -> Data {
        #if canImport(CommonCrypto)
        var out = Data(count: length)
        let status = out.withUnsafeMutableBytes { outBytes in
            password.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), passwordBytes.baseAddress?.assumingMemoryBound(to: CChar.self), password.count,
                                         saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                                         UInt32(iterations), outBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), length)
                }
            }
        }
        precondition(status == kCCSuccess, "PBKDF2 failed")
        return out
        #else
        let key = SymmetricKey(data: password)
        var out = Data()
        var block: UInt32 = 1
        while out.count < length {
            var u = Data(HMAC<SHA256>.authenticationCode(for: salt + bigEndian(block), using: key))
            var t = [UInt8](u)
            for _ in 1..<max(iterations, 1) {
                u = Data(HMAC<SHA256>.authenticationCode(for: u, using: key))
                for (i, byte) in u.enumerated() { t[i] ^= byte }
            }
            out.append(contentsOf: t); block += 1
        }
        return out.prefix(length)
        #endif
    }

    static func bigEndian<T: FixedWidthInteger>(_ value: T) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
    static func integer<T: FixedWidthInteger>(_ data: Data) -> T { data.reduce(T(0)) { ($0 << 8) | T($1) } }

    static func header(iterations: Int, salt: Data, chunkBytes: Int) -> Data {
        magic + Data([version]) + bigEndian(UInt32(iterations)) + salt + bigEndian(UInt32(chunkBytes))
    }
    static func nonce(_ index: UInt64) throws -> AES.GCM.Nonce { try AES.GCM.Nonce(data: Data(count: 4) + bigEndian(index)) }
    static func aad(_ header: Data, _ index: UInt64, last: Bool) -> Data { header + bigEndian(index) + Data([last ? 1 : 0]) }

    /// Encrypting writer. `close()` writes the last chunk; without it the file is incomplete and will not open.
    final class Writer {
        private let sink: (Data) throws -> Void
        private let header: Data
        private let key: SymmetricKey
        private let chunkBytes: Int
        private var buffer = Data()
        private var index: UInt64 = 0
        private var closed = false

        init(sink: @escaping (Data) throws -> Void, password: String, iterations: Int = BackupFormat.defaultIterations,
             salt: Data? = nil, chunkBytes: Int = BackupFormat.chunkBytes) throws {
            let salt = salt ?? Data((0..<16).map { _ in UInt8.random(in: 0...255) })
            precondition(salt.count == 16 && (1...8 * BackupFormat.chunkBytes).contains(chunkBytes))
            self.sink = sink; self.chunkBytes = chunkBytes
            header = BackupFormat.header(iterations: iterations, salt: salt, chunkBytes: chunkBytes)
            key = SymmetricKey(data: BackupFormat.pbkdf2(password: BackupFormat.passwordBytes(password), salt: salt, iterations: iterations))
            try sink(header)
        }
        func write(_ data: Data) throws {
            precondition(!closed)
            var rest = data[...]
            while !rest.isEmpty {
                if buffer.count == chunkBytes { try emit(last: false) }
                let take = min(chunkBytes - buffer.count, rest.count)
                buffer.append(rest.prefix(take)); rest = rest.dropFirst(take)
            }
        }
        private func emit(last: Bool) throws {
            let box = try AES.GCM.seal(buffer, using: key, nonce: BackupFormat.nonce(index), authenticating: BackupFormat.aad(header, index, last: last))
            let sealed = box.ciphertext + box.tag
            try sink(BackupFormat.bigEndian(UInt32(sealed.count)) + sealed)
            index += 1; buffer = Data()
        }
        func close() throws { guard !closed else { return }; try emit(last: true); closed = true }
    }

    /// Decrypting reader. Fails on a wrong password, a changed byte, reordered chunks or a cut-off file.
    final class Reader {
        private let source: (Int) throws -> Data
        private var header = Data()
        private var key = SymmetricKey(size: .bits256)
        private var chunkBytes = 0
        private var index: UInt64 = 0
        private var pending: Data?
        private var plain = Data()
        private var finished = false

        /// `source(n)` returns up to n bytes, or empty data at the end.
        init(source: @escaping (Int) throws -> Data, password: String) throws {
            self.source = source
            header = try readExactly(BackupFormat.headerBytes, cutOff: AppFailure("Das ist keine VetMed-Sicherung."))
            guard header.prefix(4) == BackupFormat.magic else { throw AppFailure("Das ist keine VetMed-Sicherung.") }
            guard header[header.startIndex + 4] == BackupFormat.version else { throw AppFailure("Diese Sicherung stammt aus einer neueren App-Version. Bitte die App aktualisieren.") }
            let iterations: UInt32 = BackupFormat.integer(header.subdata(in: 5..<9))
            let salt = header.subdata(in: 9..<25)
            chunkBytes = Int(BackupFormat.integer(header.subdata(in: 25..<29)) as UInt32)
            guard (1_000...5_000_000).contains(Int(iterations)), (1...8 * BackupFormat.chunkBytes).contains(chunkBytes) else { throw AppFailure("Die Sicherung ist beschädigt.") }
            key = SymmetricKey(data: BackupFormat.pbkdf2(password: BackupFormat.passwordBytes(password), salt: salt, iterations: Int(iterations)))
            guard let first = try readSealed() else { throw AppFailure("Die Sicherung ist unvollständig.") }
            pending = first
        }
        private func readExactly(_ count: Int, cutOff: AppFailure) throws -> Data {
            var data = Data()
            while data.count < count {
                let more = try source(count - data.count)
                if more.isEmpty { throw cutOff }
                data.append(more)
            }
            return data
        }
        private func readSealed() throws -> Data? {
            let first = try source(4)
            if first.isEmpty { return nil }
            let lengthBytes = first.count == 4 ? first : first + (try readExactly(4 - first.count, cutOff: AppFailure("Die Sicherung ist unvollständig.")))
            let length = Int(BackupFormat.integer(lengthBytes) as UInt32)
            guard (BackupFormat.tagBytes...(chunkBytes + BackupFormat.tagBytes)).contains(length) else { throw AppFailure("Die Sicherung ist beschädigt.") }
            return try readExactly(length, cutOff: AppFailure("Die Sicherung ist unvollständig."))
        }
        /// Decrypts the next chunk. Looking one chunk ahead tells whether this one must be the last.
        private func advance() throws -> Bool {
            guard let current = pending else { return false }
            let next = try readSealed()
            let last = next == nil
            do {
                let box = try AES.GCM.SealedBox(nonce: BackupFormat.nonce(index), ciphertext: current.dropLast(BackupFormat.tagBytes), tag: current.suffix(BackupFormat.tagBytes))
                plain = try AES.GCM.open(box, using: key, authenticating: BackupFormat.aad(header, index, last: last))
            } catch {
                throw AppFailure(index == 0 ? (last ? "Das Passwort ist falsch, oder die Sicherung ist beschädigt oder unvollständig." : "Das Passwort ist falsch oder die Sicherung ist beschädigt.")
                                 : (last ? "Die Sicherung ist unvollständig." : "Die Sicherung ist beschädigt."))
            }
            index += 1; pending = next
            if last { finished = true }
            return true
        }
        /// Up to `count` bytes; empty at the authenticated end.
        func read(_ count: Int) throws -> Data {
            while plain.isEmpty { if try !advance() { return Data() } }
            let out = plain.prefix(count)
            plain = plain.dropFirst(out.count)
            return Data(out)
        }
        func readExactly(_ count: Int) throws -> Data {
            var data = Data()
            while data.count < count {
                let more = try read(count - data.count)
                if more.isEmpty { throw AppFailure("Die Sicherung ist unvollständig.") }
                data.append(more)
            }
            return data
        }
        var complete: Bool { finished && plain.isEmpty && pending == nil }
    }
}

/// Named entries inside the encrypted stream: 'E' | name length u16 | name | size u64 | bytes, ended by 'Z'.
enum BackupArchive {
    static let maximumEntryBytes: UInt64 = 512 * 1024 * 1024

    final class Writer {
        let stream: BackupFormat.Writer
        init(_ stream: BackupFormat.Writer) { self.stream = stream }
        func entry(_ name: String, _ data: Data) throws {
            let encoded = Data(name.utf8)
            precondition((1...1024).contains(encoded.count))
            try stream.write(Data("E".utf8) + BackupFormat.bigEndian(UInt16(encoded.count)) + encoded + BackupFormat.bigEndian(UInt64(data.count)))
            try stream.write(data)
        }
        func finish() throws { try stream.write(Data("Z".utf8)); try stream.close() }
    }

    final class Reader {
        let stream: BackupFormat.Reader
        init(_ stream: BackupFormat.Reader) { self.stream = stream }
        /// Next entry, or nil after the end marker. A missing end marker means the archive was cut off.
        func next() throws -> (name: String, data: Data)? {
            let tag = try stream.read(1)
            if tag.isEmpty { throw AppFailure("Die Sicherung ist unvollständig.") }
            switch tag.first {
            case UInt8(ascii: "Z"):
                guard try stream.read(1).isEmpty, stream.complete else { throw AppFailure("Die Sicherung ist beschädigt.") }
                return nil
            case UInt8(ascii: "E"):
                let nameLength = Int(BackupFormat.integer(try stream.readExactly(2)) as UInt16)
                guard (1...1024).contains(nameLength), let name = String(data: try stream.readExactly(nameLength), encoding: .utf8) else { throw AppFailure("Die Sicherung ist beschädigt.") }
                let size: UInt64 = BackupFormat.integer(try stream.readExactly(8))
                guard size <= BackupArchive.maximumEntryBytes else { throw AppFailure("Die Sicherung ist beschädigt.") }
                return (name, try stream.readExactly(Int(size)))
            default: throw AppFailure("Die Sicherung ist beschädigt.")
            }
        }
    }
}

struct BackupManifest: Codable, Equatable, Sendable {
    var format = "vetmed-backup"
    var version = 1
    var createdAt = Date()
    var platform: String
    var cases: Int
    var quickChecks: Int
    var attachments: Int
    var recordings: Int
    var includesAudio: Bool
}

/// An encrypted file of the case store, named the same way on both platforms.
enum BackupFile: Hashable, Sendable {
    case attachment(caseID: UUID?, encounterID: UUID, id: UUID, upload: Bool)
    case audio(caseID: UUID, encounterID: UUID, segmentID: UUID)

    var name: String {
        switch self {
        case let .attachment(caseID, encounterID, id, upload): "attachment/\(caseID?.uuidString ?? "quick")/\(encounterID.uuidString)/\(id.uuidString)/\(upload ? "upload" : "original")"
        case let .audio(caseID, encounterID, segmentID): "audio/\(caseID.uuidString)/\(encounterID.uuidString)/\(segmentID.uuidString)"
        }
    }
    /// Only well-formed names with real UUIDs; anything else is never turned into a file.
    static func parse(_ name: String) -> BackupFile? {
        let parts = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if parts.count == 5, parts[0] == "attachment", ["original", "upload"].contains(parts[4]),
           let encounter = UUID(uuidString: parts[2]), let id = UUID(uuidString: parts[3]) {
            if parts[1] == "quick" { return .attachment(caseID: nil, encounterID: encounter, id: id, upload: parts[4] == "upload") }
            guard let caseID = UUID(uuidString: parts[1]) else { return nil }
            return .attachment(caseID: caseID, encounterID: encounter, id: id, upload: parts[4] == "upload")
        }
        if parts.count == 4, parts[0] == "audio", let caseID = UUID(uuidString: parts[1]), let encounter = UUID(uuidString: parts[2]), let segment = UUID(uuidString: parts[3]) {
            return .audio(caseID: caseID, encounterID: encounter, segmentID: segment)
        }
        return nil
    }
}

enum BackupContent {
    static let manifestName = "manifest.json"
    static let documentName = "document.json"
    static let vocabularyName = "vocabulary.json"

    /// Every encrypted file the document refers to.
    static func files(_ document: VaultDocument, includeAudio: Bool) -> [BackupFile] {
        var files: [BackupFile] = []
        func attachments(_ caseID: UUID?, _ encounterID: UUID, _ list: [ChatAttachment]?) {
            for attachment in list ?? [] {
                files.append(.attachment(caseID: caseID, encounterID: encounterID, id: attachment.id, upload: false))
                if attachment.uploadSHA256 != nil { files.append(.attachment(caseID: caseID, encounterID: encounterID, id: attachment.id, upload: true)) }
            }
        }
        for item in document.cases {
            for encounter in item.encounters {
                attachments(item.id, encounter.id, encounter.chatAttachments)
                if includeAudio { files += encounter.audio.map { .audio(caseID: item.id, encounterID: encounter.id, segmentID: $0.id) } }
            }
        }
        for check in document.quickChecks ?? [] { attachments(nil, check.id, check.chatAttachments) }
        return files
    }

    static func manifest(_ document: VaultDocument, includeAudio: Bool, platform: String) -> BackupManifest {
        let files = files(document, includeAudio: includeAudio)
        return BackupManifest(platform: platform, cases: document.cases.count, quickChecks: document.quickChecks?.count ?? 0,
            attachments: files.filter { if case .attachment(_, _, _, false) = $0 { true } else { false } }.count,
            recordings: files.filter { if case .audio = $0 { true } else { false } }.count, includesAudio: includeAudio)
    }

    /// Rough size before writing: files as stored plus 16-bit mono audio at 16 kHz.
    static func estimatedBytes(_ document: VaultDocument, includeAudio: Bool) -> Int64 {
        let encounters: [Encounter] = document.cases.flatMap(\.encounters)
        var list: [ChatAttachment] = encounters.flatMap { $0.chatAttachments ?? [] }
        list += (document.quickChecks ?? []).flatMap { $0.chatAttachments ?? [] }
        var total: Int64 = 0
        for attachment in list { total += Int64(attachment.originalByteCount) + Int64(attachment.uploadByteCount ?? 0) }
        if includeAudio { for segment in encounters.flatMap(\.audio) { total += Int64(segment.duration * 32_000) } }
        return total
    }

    struct Written: Sendable { var manifest: BackupManifest; var files: Int; var missing: Int }

    /// Writes the whole backup. `read` returns nil for a file that is gone; it is left out and counted.
    static func write(sink: @escaping (Data) throws -> Void, password: String, document: VaultDocument, vocabulary: [VocabularyEntry], includeAudio: Bool,
                      platform: String = "ios", iterations: Int = BackupFormat.defaultIterations, salt: Data? = nil, createdAt: Date = Date(),
                      progress: (Int, Int) -> Void = { _, _ in }, read: (BackupFile) throws -> Data?) throws -> Written {
        var manifest = manifest(document, includeAudio: includeAudio, platform: platform)
        manifest.createdAt = createdAt
        let archive = BackupArchive.Writer(try BackupFormat.Writer(sink: sink, password: password, iterations: iterations, salt: salt))
        let encoder = JSONEncoder()
        try archive.entry(manifestName, encoder.encode(manifest))
        try archive.entry(documentName, encoder.encode(document))
        try archive.entry(vocabularyName, encoder.encode(vocabulary))
        let files = files(document, includeAudio: includeAudio)
        var missing = 0
        for (index, file) in files.enumerated() {
            if let data = try read(file) { try archive.entry(file.name, data) } else { missing += 1 }
            progress(index + 1, files.count)
        }
        try archive.finish()
        return Written(manifest: manifest, files: files.count - missing, missing: missing)
    }

    struct Restored: Sendable {
        var document: VaultDocument
        var vocabulary: [VocabularyEntry]
        var manifest: BackupManifest
        var addedCases: Int
        var skippedCases: Int
        var addedQuickChecks: Int
        var skippedQuickChecks: Int
        var files: Int
        var missingFiles: Int
        var summary: String {
            let cases = addedCases == 1 ? "1 Fall" : "\(addedCases) Fälle"
            let checks = addedQuickChecks == 1 ? "1 Schnellcheck" : "\(addedQuickChecks) Schnellchecks"
            var text = "\(cases) und \(checks) wiederhergestellt."
            let skipped = skippedCases + skippedQuickChecks
            if skipped > 0 { text += " \(skipped) schon vorhanden, unverändert gelassen." }
            if missingFiles > 0 { text += " \(missingFiles) Dateien waren nicht in der Sicherung" + (manifest.includesAudio ? "." : " (Aufnahmen nicht mitgesichert).") }
            return text
        }
    }

    /// Reads a backup and merges it into the local cases. Nothing local is overwritten. `store` receives each file of a
    /// newly added case before the caller saves the returned document.
    static func restore(source: @escaping (Int) throws -> Data, password: String, local: VaultDocument, localVocabulary: [VocabularyEntry],
                        store: (BackupFile, Data) throws -> Void) throws -> Restored {
        let archive = BackupArchive.Reader(try BackupFormat.Reader(source: source, password: password))
        func expect(_ name: String) throws -> Data {
            guard let entry = try archive.next() else { throw AppFailure("Die Sicherung ist unvollständig.") }
            guard entry.name == name else { throw AppFailure("Die Sicherung ist beschädigt.") }
            return entry.data
        }
        let decoder = JSONDecoder()
        let manifest: BackupManifest, backup: VaultDocument, vocabulary: [VocabularyEntry]
        do {
            manifest = try decoder.decode(BackupManifest.self, from: try expect(manifestName))
            guard manifest.format == "vetmed-backup", manifest.version == 1 else { throw AppFailure("Diese Sicherung stammt aus einer neueren App-Version. Bitte die App aktualisieren.") }
            backup = try decoder.decode(VaultDocument.self, from: try expect(documentName))
            guard backup.schemaVersion == 1 else { throw AppFailure("Diese Sicherung stammt aus einer neueren App-Version. Bitte die App aktualisieren.") }
            vocabulary = try decoder.decode([VocabularyEntry].self, from: try expect(vocabularyName))
        } catch let error as AppFailure { throw error } catch { throw AppFailure("Die Sicherung ist beschädigt.") }
        let localCases = Set(local.cases.map(\.id)), localChecks = Set((local.quickChecks ?? []).map(\.id))
        let newCases = backup.cases.filter { !localCases.contains($0.id) }
        let newChecks = (backup.quickChecks ?? []).filter { !localChecks.contains($0.id) }
        let wanted = Set(files(VaultDocument(cases: newCases, quickChecks: newChecks), includeAudio: true).map(\.name))
        var stored = 0
        while let entry = try archive.next() {
            guard wanted.contains(entry.name), let file = BackupFile.parse(entry.name) else { continue }
            try store(file, entry.data); stored += 1
        }
        let knownWords = Set(localVocabulary.map { $0.recognized.lowercased() }), knownIDs = Set(localVocabulary.map(\.id))
        let merged = localVocabulary + vocabulary.filter { !knownIDs.contains($0.id) && !knownWords.contains($0.recognized.lowercased()) }
        var document = local
        document.cases += newCases
        let checks = (local.quickChecks ?? []) + newChecks
        document.quickChecks = checks.isEmpty ? nil : checks
        return Restored(document: document, vocabulary: merged, manifest: manifest, addedCases: newCases.count, skippedCases: backup.cases.count - newCases.count,
                        addedQuickChecks: newChecks.count, skippedQuickChecks: (backup.quickChecks?.count ?? 0) - newChecks.count, files: stored, missingFiles: wanted.count - stored)
    }
}
