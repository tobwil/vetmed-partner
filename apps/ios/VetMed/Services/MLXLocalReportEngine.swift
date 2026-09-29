import Foundation
import Darwin
import Combine
import MLX
import MLXLMCommon
import MLXLLM
import MLXVLM
import MLXHuggingFace
import Tokenizers

struct PreparedTokenizerLoader: MLXLMCommon.TokenizerLoader {
    let tokenizer: any MLXLMCommon.Tokenizer
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer { try Task.checkCancellation(); return tokenizer }
}
@MainActor
protocol ReportTextEngine: AnyObject {
    var engineID: String { get }
    var engineRevision: String { get }
    var sourceLimit: Int { get }
    var characterLimit: Int { get }
    var executionLabel: String { get }
    func generate(prompt: String, instructions: String) async throws -> String
}
extension ReportTextEngine {
    var engineID: String { "synthetic-test-engine" }
    var engineRevision: String { "synthetic" }
    var sourceLimit: Int { 4 }
    var characterLimit: Int { 1800 }
    var executionLabel: String { "auf diesem Gerät" }
}

/// Adapted from rag2go ModelService; preserves serial tokenizer loading and GPU cancellation synchronization.
@MainActor
final class MLXLocalReportEngine: ObservableObject, ReportTextEngine {
    var engineID: String { ModelOption.gemma4E2B.id }
    var engineRevision: String { ModelOption.revision }
    @Published private(set) var status = "Nicht geladen"
    @Published private(set) var progress: Double?
    @Published private(set) var isBusy = false
    @Published private(set) var ready = false
    @Published private(set) var installed = false
    @Published private(set) var lastSeconds: Double?
    private var container: ModelContainer?
    private var installationToken: UUID?
    private var memoryStopRequested = false
    private let repository = ModelRepository()
    init() {
        #if !targetEnvironment(simulator)
        Memory.cacheLimit = 32 * 1024 * 1024
        #endif
        refresh()
    }
    func refresh() { installed = ((try? ModelManifest.bundled().first).map { repository.isInstalled($0) }) ?? false }
    func install() async throws {
        guard !isBusy else { throw AppFailure("Modell arbeitet noch.") }
        guard let manifest = try ModelManifest.bundled().first else { throw AppFailure("Modellmanifest fehlt.") }
        let free = try AppPaths.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
        guard free >= 5_000_000_000 || repository.isInstalled(manifest) else { throw AppFailure("Mindestens 5 GB freier Speicher werden benötigt.") }
        let token = UUID(); installationToken = token
        isBusy = true; status = "Modell wird installiert"; progress = 0
        defer { isBusy = false; progress = nil; installationToken = nil; refresh() }
        do {
            _ = try await repository.prepare(manifest) { [weak self] fraction in
                Task { @MainActor in guard self?.installationToken == token else { return }; self?.progress = fraction }
            }
            status = "Installiert · offline verfügbar"
        } catch { status = "Installation unterbrochen"; throw error }
    }
    func load() async throws {
        guard !isBusy else { throw AppFailure("Modell arbeitet noch.") }
        if ready { return }
        #if targetEnvironment(simulator)
        throw AppFailure("Gemma benötigt ein echtes iPhone mit Metal. Im Simulator sind Oberfläche und Speicher testbar.")
        #else
        if let reason = DeviceReadiness.blockingReason(modelID: ModelOption.gemma4E2B.id) { throw AppFailure(reason) }
        guard let manifest = try ModelManifest.bundled().first, repository.isInstalled(manifest) else { throw AppFailure("Bitte Gemma zuerst in den Einstellungen installieren. Es wird nichts automatisch heruntergeladen.") }
        memoryStopRequested = false
        isBusy = true; status = "Integrität prüfen und Modell laden"
        defer { isBusy = false }
        do {
            // prepare only follows the verified installed path. It cannot download in this path.
            let directory = repository.directory(manifest)
            let verification = Task.detached { [repository] in try repository.verify(manifest, at: directory) }
            try await withTaskCancellationHandler { try await verification.value } onCancel: { verification.cancel() }
            await GemmaVisionCompatibility.register()
            let tokenizerLoader: any TokenizerLoader = #huggingFaceTokenizerLoader()
            let tokenizer = try await tokenizerLoader.load(from: directory)
            try Task.checkCancellation()
            let loaded = try await VLMModelFactory.shared.loadContainer(from: directory, using: PreparedTokenizerLoader(tokenizer: tokenizer))
            try Task.checkCancellation()
            guard !memoryStopRequested else { throw AppFailure("Modellladen wegen Speicherdruck beendet. Bitte andere Apps schließen und erneut versuchen.") }
            container = loaded; ready = true; status = "Bereit · auf diesem Gerät"
        } catch { container = nil; ready = false; status = "Laden fehlgeschlagen"; throw error }
        #endif
    }
    func unload() throws {
        guard !isBusy else { throw AppFailure("Bitte laufende Modellarbeit zuerst abbrechen.") }
        container = nil; ready = false; clearCache(); status = installed ? "Installiert · nicht geladen" : "Nicht installiert"
    }
    func delete() throws {
        try unload()
        if let manifest = try ModelManifest.bundled().first { try repository.remove(manifest) }
        refresh(); status = "Nicht installiert"
    }
    func generate(prompt: String, instructions: String) async throws -> String {
        try Task.checkCancellation()
        guard !isBusy, let container else { throw AppFailure("Lokales Modell ist nicht bereit.") }
        if let reason = DeviceReadiness.blockingReason(modelID: ModelOption.gemma4E2B.id) { throw AppFailure(reason) }
        #if !targetEnvironment(simulator)
        guard os_proc_available_memory() >= 256 * 1_048_576 else { throw AppFailure("Zu wenig freier Arbeitsspeicher für einen sicheren Modellstart. Das Transkript bleibt erhalten.") }
        #endif
        memoryStopRequested = false
        isBusy = true; status = "Bericht entsteht auf diesem Gerät"
        defer { isBusy = false; status = "Bereit · auf diesem Gerät" }
        let count = try await container.perform { context in
            let input = try await context.processor.prepare(input: UserInput(chat: [.system(instructions), .user(prompt)], additionalContext: ["enable_thinking": false]))
            return input.text.tokens.size
        }
        guard count <= 6000 else { throw AppFailure("Dieser Abschnitt überschreitet das lokale Kontextlimit. Das Transkript bleibt vollständig erhalten.") }
        let parameters = GenerateParameters(maxTokens: 2048, maxKVSize: 8192, temperature: 0, topP: 0.95, topK: 64, minP: 0, repetitionPenalty: nil, prefillStepSize: 128)
        let session = ChatSession(container, instructions: instructions, generateParameters: parameters, additionalContext: ["enable_thinking": false])
        let start = Date(); var output = ""
        do {
            for try await event in session.streamDetails(to: prompt) {
                try Task.checkCancellation()
                #if !targetEnvironment(simulator)
                if memoryStopRequested || os_proc_available_memory() < 128 * 1_048_576 {
                    throw AppFailure("Modellarbeit wegen knappem Arbeitsspeicher kontrolliert beendet. Gesicherte Inhalte bleiben erhalten.")
                }
                #endif
                switch event {
                case .chunk(let chunk):
                    output += chunk
                    if OutputRepetition.containsLoop(output) { throw OutputRepetition.Detected() }
                case .toolCall: throw AppFailure("Unerwarteter Werkzeugaufruf. Lokale Berichte verwenden keine Netzwerkwerkzeuge.")
                case .info: break
                }
            }
            try Task.checkCancellation()
        } catch {
            await session.synchronize()
            await session.clear()
            clearCache()
            throw error
        }
        await session.clear(); clearCache()
        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AppFailure("Das Modell lieferte keinen Bericht.") }
        lastSeconds = Date().timeIntervalSince(start)
        return output
    }
    func requestMemoryStop() { memoryStopRequested = true }
    func trimIdleMemory() { if !isBusy { clearCache() } }
    private func clearCache() {
        #if !targetEnvironment(simulator)
        Memory.clearCache()
        #endif
    }
}
