import Foundation
import Speech
import AVFoundation

protocol OfflineTranscriber: Sendable {
    func transcribe(file: URL, audioID: UUID) async throws -> [TranscriptSegment]
}
struct AppleOfflineTranscriber: OfflineTranscriber {
    static func module() async throws -> SpeechTranscriber {
        guard SpeechTranscriber.isAvailable, let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "de-DE")) else {
            throw AppFailure("Deutsche Offline-Spracherkennung ist auf diesem Gerät nicht verfügbar. Aufnahme und Texteingabe bleiben möglich.")
        }
        return SpeechTranscriber(locale: locale, preset: .timeIndexedTranscriptionWithAlternatives)
    }
    static func status() async -> String {
        do {
            let transcriber = try await module()
            switch await AssetInventory.status(forModules: [transcriber]) {
            case .installed: return "Deutsch · offline bereit"
            case .supported: return "Deutsche Sprachressourcen fehlen"
            case .downloading: return "Sprachressourcen werden installiert"
            case .unsupported: return "Auf diesem Gerät nicht verfügbar"
            @unknown default: return "Status unbekannt"
            }
        } catch { return error.localizedDescription }
    }
    static func install() async throws {
        let transcriber = try await module()
        _ = try await AssetInventory.reserve(locale: Locale(identifier: "de-DE"))
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) { try await request.downloadAndInstall() }
    }
    func transcribe(file: URL, audioID: UUID) async throws -> [TranscriptSegment] {
        let transcriber = try await Self.module()
        guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
            throw AppFailure("Deutsche Sprachressourcen fehlen. Bitte in Einstellungen ausdrücklich installieren. Kein Cloud-Fallback.")
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let results = Task { () throws -> [TranscriptSegment] in
            var segments: [TranscriptSegment] = []
            for try await result in transcriber.results {
                try Task.checkCancellation()
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    segments.append(.init(id: "\(audioID)-\(segments.count)", text: text, audioID: audioID,
                        startSeconds: result.range.start.seconds, endSeconds: result.range.end.seconds))
                }
            }
            return segments
        }
        return try await withTaskCancellationHandler {
            do {
                let audio = try AVAudioFile(forReading: file)
                if let end = try await analyzer.analyzeSequence(from: audio) { try await analyzer.finalizeAndFinish(through: end) }
                else { try await analyzer.finalizeAndFinishThroughEndOfInput() }
                return try await results.value
            } catch {
                results.cancel(); await analyzer.cancelAndFinishNow(); throw error
            }
        } onCancel: {
            results.cancel()
            Task { await analyzer.cancelAndFinishNow() }
        }
    }
}
