import CryptoKit
import Foundation
import HuggingFace

struct ModelManifest: Codable, Equatable, Sendable {
    struct File: Codable, Equatable, Sendable {
        let name: String
        let bytes: Int64
        let sha256: String
    }
    let id: String
    let revision: String
    let files: [File]
    var bytes: Int64 { files.reduce(0) { $0 + $1.bytes } }

    func validate() throws {
        let hex = CharacterSet(charactersIn: "0123456789abcdef")
        let repositoryCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./")
        guard id.split(separator: "/", omittingEmptySubsequences: false).count == 2, !id.hasPrefix("/"), !id.hasSuffix("/"), !id.contains(".."), id.unicodeScalars.allSatisfy(repositoryCharacters.contains),
              revision.count == 40, revision.unicodeScalars.allSatisfy(hex.contains),
              !files.isEmpty, Set(files.map(\.name)).count == files.count,
              files.contains(where: { $0.name == "config.json" }),
              files.contains(where: { $0.name == "tokenizer.json" }),
              files.contains(where: { $0.name.hasSuffix(".safetensors") }) else {
            throw AppFailure("Ungültiges Modellverzeichnis. Kein Download gestartet.")
        }
        for file in files {
            guard !file.name.isEmpty, !file.name.contains("/"), !file.name.contains("\\"), !file.name.hasPrefix("."),
                  ["json", "safetensors", "model", "jinja"].contains((file.name as NSString).pathExtension),
                  file.bytes > 0, file.sha256.count == 64, file.sha256.unicodeScalars.allSatisfy(hex.contains) else {
                throw AppFailure("Ungültige Modelldatei. Kein Download gestartet.")
            }
        }
    }
    static func bundled() throws -> [Self] {
        guard let url = Bundle.main.url(forResource: "ModelManifest", withExtension: "json") else {
            throw AppFailure("Das geprüfte Modellverzeichnis fehlt in diesem Build.")
        }
        let values = try JSONDecoder().decode([Self].self, from: Data(contentsOf: url))
        guard Set(values.map(\.id)).count == values.count else { throw AppFailure("Doppelte Modellkennung.") }
        for value in values { try value.validate() }
        return values
    }
}

/// Remembers which file stamps passed a full SHA-256 check in this process. Every load used to hash the whole
/// model again (about 3.6 GB), although the model is unloaded on each app switch. Now the full check runs after
/// installation and once per app start; later loads only confirm that size and modification date are unchanged.
struct ModelVerificationMemory: Sendable {
    private(set) var verified: [String: ModelRepository.Receipt.Stamp]?
    func needsFullCheck(current: [String: ModelRepository.Receipt.Stamp]?) -> Bool { current == nil || current != verified }
    mutating func remember(_ stamps: [String: ModelRepository.Receipt.Stamp]?) { verified = stamps }
    mutating func forget() { verified = nil }
}

/// All paths derive from validated, bundled manifests, never network-supplied filenames.
/// A staging directory becomes usable only after all pinned SHA-256 checks succeed.
struct ModelRepository: Sendable {
    let root: URL
    private let copyFile: @Sendable (URL, URL) throws -> Void
    init(root: URL = AppPaths.root.appendingPathComponent("Models", isDirectory: true),
         copyFile: @escaping @Sendable (URL, URL) throws -> Void = { try FileManager.default.copyItem(at: $0, to: $1) }) {
        self.root = root; self.copyFile = copyFile
    }

    struct Receipt: Codable {
        struct Stamp: Codable, Equatable { let size: Int64; let modified: Date }
        let manifest: ModelManifest
        let stamps: [String: Stamp]
    }

    func directory(_ manifest: ModelManifest) -> URL {
        root.appendingPathComponent(manifest.id.replacingOccurrences(of: "/", with: "--"), isDirectory: true)
            .appendingPathComponent(manifest.revision, isDirectory: true)
    }
    func staging(_ manifest: ModelManifest) -> URL { directory(manifest).appendingPathExtension("partial") }

    /// Fast UI readiness check. Every actual load additionally hashes all files off the main actor.
    func isInstalled(_ manifest: ModelManifest) -> Bool {
        guard (try? manifest.validate()) != nil else { return false }
        let location = directory(manifest)
        guard let data = try? Data(contentsOf: location.appendingPathComponent("verified.json")),
              let receipt = try? JSONDecoder().decode(Receipt.self, from: data), receipt.manifest == manifest,
              let current = try? stamps(manifest, at: location) else { return false }
        return receipt.stamps == current
    }

    func storedBytes(_ manifest: ModelManifest) -> Int64 {
        [directory(manifest), staging(manifest)].reduce(0) { sum, directory in
            sum + manifest.files.reduce(0) { bytes, file in
                bytes + Int64((try? directory.appendingPathComponent(file.name).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
    }

    func prepare(_ manifest: ModelManifest, legacy: URL? = nil,
                 progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        try manifest.validate()
        try Task.checkCancellation()
        let destination = directory(manifest)
        if FileManager.default.fileExists(atPath: destination.path) {
            try await io { try verify(manifest, at: destination) }
            return destination
        }
        try createExcludedDirectory(root)
        let partial = staging(manifest)
        try createExcludedDirectory(partial)
        var completed: Int64 = 0
        for file in manifest.files {
            try Task.checkCancellation()
            let target = partial.appendingPathComponent(file.name)
            let alreadyValid = try await io { try matches(file, at: target) }
            if !alreadyValid {
                if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
                let old = legacy?.appendingPathComponent(file.name)
                let reusable: Bool
                if let old { reusable = try await io { try matches(file, at: old) } } else { reusable = false }
                if reusable, let old {
                    try await io {
                        try Task.checkCancellation()
                        try copyFile(old.resolvingSymlinksInPath(), target)
                    }
                } else {
                    let base = completed, total = manifest.bytes
                    let delegate = ModelDownloadProgress { fraction in
                        progress(Double(base) / Double(total) + fraction * Double(file.bytes) / Double(total))
                    }
                    let config = URLSessionConfiguration.ephemeral
                    config.timeoutIntervalForRequest = 60; config.timeoutIntervalForResource = 3600
                    let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
                    defer { session.invalidateAndCancel() }
                    let url = URL(string: "https://huggingface.co/\(manifest.id)/resolve/\(manifest.revision)/\(file.name)")!
                    let resumeURL = partial.appendingPathComponent(file.name + ".resume")
                    let download: (URL, URLResponse)
                    do {
                        if let resume = try? Data(contentsOf: resumeURL) {
                            download = try await session.download(resumeFrom: resume)
                        } else {
                            download = try await session.download(from: url)
                        }
                        try? FileManager.default.removeItem(at: resumeURL)
                    } catch {
                        let failure = error as NSError
                        if let resume = failure.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                            try resume.write(to: resumeURL, options: [.atomic, .completeFileProtection])
                        } else {
                            try? FileManager.default.removeItem(at: resumeURL)
                        }
                        throw error
                    }
                    let (temporary, response) = download
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    guard let response = response as? HTTPURLResponse, [200, 206].contains(response.statusCode) else {
                        throw AppFailure("Modelldownload fehlgeschlagen. Bereits geprüfte Dateien bleiben für einen neuen Versuch erhalten.")
                    }
                    guard try await io({ try matches(file, at: temporary) }) else {
                        throw AppFailure("Integritätsprüfung für \(file.name) fehlgeschlagen. Das Modell wird nicht geladen.")
                    }
                    try Task.checkCancellation()
                    try FileManager.default.moveItem(at: temporary, to: target)
                }
            }
            completed += file.bytes; progress(Double(completed) / Double(manifest.bytes))
        }
        try await io { try verify(manifest, at: partial) }
        let receipt = Receipt(manifest: manifest, stamps: try stamps(manifest, at: partial))
        try JSONEncoder().encode(receipt).write(to: partial.appendingPathComponent("verified.json"), options: .atomic)
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: partial, to: destination)
        try excludeFromBackup(destination)
        return destination
    }

    /// Legacy cache is retained until the new copy is fully verified. Explicit model deletion
    /// removes both locations; migration itself never destroys the user's last working copy.
    func legacyDirectory(modelID: String) -> URL? {
        guard let repo = Repo.ID(rawValue: modelID),
              let commit = HubCache.default.resolveRevision(repo: repo, kind: .model, ref: "main") else { return nil }
        return try? HubCache.default.snapshotPath(repo: repo, kind: .model, commitHash: commit)
    }

    func remove(_ manifest: ModelManifest) throws {
        try manifest.validate()
        for url in [directory(manifest), staging(manifest)] where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    func verify(_ manifest: ModelManifest, at location: URL) throws {
        try manifest.validate()
        for file in manifest.files {
            try Task.checkCancellation()
            guard try matches(file, at: location.appendingPathComponent(file.name)) else {
                throw AppFailure("Modelldatei \(file.name) fehlt oder ist beschädigt. Bitte das Modell in den Einstellungen löschen und erneut herunterladen; Chats bleiben erhalten.")
            }
        }
    }

    func matches(_ file: ModelManifest.File, at url: URL) throws -> Bool {
        let url = url.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: url.path),
              let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, Int64(size) == file.bytes else { return false }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while true {
            try Task.checkCancellation()
            // Foundation reads can create autoreleased NSData objects. Drain every chunk,
            // otherwise hashing a multi-GB model can retain the entire file until task exit.
            let read = try autoreleasepool {
                guard let data = try handle.read(upToCount: 1_048_576), !data.isEmpty else { return false }
                hash.update(data: data)
                return true
            }
            if !read { break }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined() == file.sha256
    }

    /// Size and modification date of every installed file, or nil when the model is incomplete.
    func currentStamps(_ manifest: ModelManifest) -> [String: Receipt.Stamp]? { try? stamps(manifest, at: directory(manifest)) }

    private func stamps(_ manifest: ModelManifest, at location: URL) throws -> [String: Receipt.Stamp] {
        var result: [String: Receipt.Stamp] = [:]
        for file in manifest.files {
            let values = try location.appendingPathComponent(file.name).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true, let size = values.fileSize, Int64(size) == file.bytes,
                  let date = values.contentModificationDate else { throw AppFailure("Modell unvollständig.") }
            result[file.name] = .init(size: Int64(size), modified: date)
        }
        return result
    }
    private func createExcludedDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try excludeFromBackup(url)
    }
    private func excludeFromBackup(_ url: URL) throws {
        var url = url, values = URLResourceValues(); values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
    private func io<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        let task = Task.detached(priority: .utility, operation: work)
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}

private final class ModelDownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let progress: @Sendable (Double) -> Void
    init(progress: @escaping @Sendable (Double) -> Void) { self.progress = progress }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 { progress(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url?.scheme == "https" ? request : nil)
    }
}
