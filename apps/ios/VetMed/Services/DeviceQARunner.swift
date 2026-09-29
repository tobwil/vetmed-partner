#if DEBUG
import Foundation
import Darwin
import UIKit
import AVFoundation
import Network

/// Explicit debug-only launch job. Uses only its bundled synthetic input and never opens the case vault.
@MainActor
enum DeviceQARunner {
    struct Result: Codable {
        var date = Date()
        var model = ModelOption.gemma4E2B.id
        var revision = ModelOption.revision
        var operatingSystem = ProcessInfo.processInfo.operatingSystemVersionString
        var loadSeconds: Double?
        var reportSeconds: Double?
        var peakResidentMiB: UInt64 = 0
        var thermalState = ""
        var completed = false
        var warnings: [String] = []
        var error: String?
        var errorDomain: String?
        var errorCode: Int?
        var report: StructuredReport?
        var syntheticCandidates: [String] = []
        var rounds: [Round] = []
        var cancellationRecovered: Bool?
        struct Round: Codable { var seconds: Double; var residentMiB: UInt64; var warnings: [String] }
    }
    static func run(engine: MLXLocalReportEngine, repeatCount: Int = 1, testCancellation: Bool = false) async {
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }
        var result = Result()
        let captured = SyntheticCapture(engine: engine)
        let sampler = Task { () -> UInt64 in
            var peak: UInt64 = 0
            while !Task.isCancelled {
                peak = max(peak, residentMiB())
                try? await Task.sleep(for: .milliseconds(200))
            }
            return peak
        }
        do {
            try AppPaths.prepare(AppPaths.root)
            print("VETMED_QA_BEGIN synthetic-only")
            if !engine.installed { print("VETMED_QA_DOWNLOAD_BEGIN"); try await engine.install(); print("VETMED_QA_DOWNLOAD_DONE") }
            let start = Date(); try await engine.load(); result.loadSeconds = Date().timeIntervalSince(start)
            print("VETMED_QA_MODEL_READY")
            let transcript = TranscriptBuilder.edited("Synthetischer Testfall. Hund, 12,5 kg. Seit gestern verminderter Appetit. Kein Erbrechen. Temperatur nicht gemessen. Kontrolle in 3 Tagen vereinbart.", previous: nil)
            for round in 0..<max(1, min(10, repeatCount)) {
                let generation = Date()
                let report = try await ReportPipeline(engine: captured).run(transcript: transcript, template: .treatment_report, length: .medium, audience: .veterinarian) { status in print("VETMED_QA_PROGRESS Runde \(round + 1) · \(status)") }
                let seconds = Date().timeIntervalSince(generation)
                result.reportSeconds = seconds
                result.report = report.content; result.warnings = report.warnings
                result.rounds.append(.init(seconds: seconds, residentMiB: residentMiB(), warnings: report.warnings))
            }
            if testCancellation {
                let generation = Task { try await engine.generate(prompt: "Schreibe eine sehr ausführliche Beschreibung aller Zahlen von eins bis tausend.", instructions: "Antworte auf Deutsch.") }
                try await Task.sleep(for: .milliseconds(200))
                generation.cancel()
                do { _ = try await generation.value; result.cancellationRecovered = false }
                catch { result.cancellationRecovered = !engine.isBusy }
                // Require a real generation after cancellation, so clearing just the UI flag cannot pass.
                _ = try await ReportPipeline(engine: captured).run(transcript: transcript, template: .treatment_report, length: .medium, audience: .veterinarian) { _ in }
            }
            result.completed = true
        } catch { result.error = error.localizedDescription; result.errorDomain = (error as NSError).domain; result.errorCode = (error as NSError).code }
        result.syntheticCandidates = captured.candidates
        sampler.cancel(); result.peakResidentMiB = await sampler.value
        result.thermalState = String(describing: ProcessInfo.processInfo.thermalState)
        do {
            let root = AppPaths.root.appendingPathComponent("SyntheticQA")
            try AppPaths.prepare(root)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(result)
            try data.write(to: root.appendingPathComponent("local-report.json"), options: [.atomic, .completeFileProtection])
            print("VETMED_QA_RESULT " + String(decoding: data, as: UTF8.self))
        } catch { print("VETMED_QA_RESULT_WRITE_FAILED") }
        print("VETMED_QA_END completed=\(result.completed)")
    }
    private final class SyntheticCapture: ReportTextEngine {
        let engine: MLXLocalReportEngine
        var engineID: String { engine.engineID }
        var engineRevision: String { engine.engineRevision }
        var candidates: [String] = []
        init(engine: MLXLocalReportEngine) { self.engine = engine }
        func generate(prompt: String, instructions: String) async throws -> String {
            let output = try await engine.generate(prompt: prompt, instructions: instructions)
            // This wrapper is exclusive to the hard-coded synthetic QA input. Never used for case content.
            let visible = output.replacingOccurrences(of: "(?s)<think>.*?</think>", with: "", options: .regularExpression)
            candidates.append(visible)
            return output
        }
    }
    struct SpeechResult: Codable {
        var file: String
        var audioSeconds: Double
        var wallSeconds: Double
        var segmentCount: Int
        var transcript: String
        var synthetic = true
        var error: String?
    }
    static func runOfflinePipeline(engine: MLXLocalReportEngine, requireOffline: Bool = true) async -> String {
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }
        struct Evidence: Codable {
            var date = Date()
            var synthetic = true
            var inputFile = "synthetic-300s.wav"
            var networkBefore = "unknown"
            var networkAfter = "unknown"
            var requiredOffline = true
            var stages: [String] = []
            var sourceCount = 0
            var peakResidentMiB: UInt64 = 0
            var durationSeconds = 0.0
            var thermalState = ""
            var completed = false
            var error: String?
            var report: StructuredReport?
            var syntheticTranscript: String?
            var syntheticCandidates: [String] = []
        }
        var evidence = Evidence()
        evidence.requiredOffline = requireOffline
        let captured = SyntheticCapture(engine: engine)
        let start = Date()
        let sampler = Task { () -> UInt64 in
            var peak: UInt64 = 0
            while !Task.isCancelled { peak = max(peak, residentMiB()); try? await Task.sleep(for: .milliseconds(200)) }
            return peak
        }
        let qaRoot = AppPaths.root.appendingPathComponent("SyntheticQA")
        do {
            print("VETMED_OFFLINE_BEGIN synthetic-only")
            evidence.networkBefore = await networkStatus()
            guard !requireOffline || evidence.networkBefore == "unsatisfied" else { throw AppFailure("Offlinetest benötigt einen nicht verfügbaren Netzwerkpfad; gemessen: \(evidence.networkBefore)") }
            let rawSegments = try await AppleOfflineTranscriber().transcribe(file: qaRoot.appendingPathComponent(evidence.inputFile), audioID: UUID())
            let text = rawSegments.map(\.text).joined(separator: "\n")
            evidence.syntheticTranscript = text
            let transcript = TranscriptVersion(rawText: text, editedText: text, segments: TranscriptBuilder.audioSentences(rawSegments), engine: "Apple SpeechAnalyzer · de-DE · offline")
            guard !transcript.segments.isEmpty else { throw AppFailure("Synthetisches Audio lieferte keinen Text.") }
            evidence.sourceCount = transcript.segments.count; evidence.stages.append("offline-asr")
            print("VETMED_OFFLINE_ASR_DONE sources=\(evidence.sourceCount)")
            let root = qaRoot.appendingPathComponent("OfflineVault")
            try AppPaths.prepare(root)
            let key = try SecureStore(service: "de.tobwil.vetmed.synthetic-qa").vaultKey(existingData: CaseRepository.hasExistingData(at: root))
            let repository = try CaseRepository(root: root, key: key)
            var encounter = Encounter(); encounter.transcripts = [transcript]
            var item = VetCase(label: "Synthetic offline test", species: "Hund"); item.encounters = [encounter]
            var document = VaultDocument(cases: [item]); try await repository.save(document)
            evidence.stages.append("encrypted-transcript-save")
            try await engine.load()
            let report = try await ReportPipeline(engine: captured).run(transcript: transcript, template: .treatment_report, length: .medium, audience: .veterinarian, checkpoint: { value in
                document.cases[0].encounters[0].reportCheckpoint = value
                try await repository.save(document)
            }) { print("VETMED_OFFLINE_PROGRESS " + $0) }
            evidence.report = report.content; evidence.stages.append("local-report-validation")
            document.cases[0].encounters[0].reports = [report]; document.cases[0].encounters[0].reportCheckpoint = nil
            try await repository.save(document)
            let reopened = try CaseRepository(root: root, key: key)
            guard try await reopened.load() == document else { throw AppFailure("Offline-Wiederöffnen wich vom gespeicherten Stand ab.") }
            try await reopened.verifyIntegrity(); evidence.stages.append("encrypted-reopen-integrity")
            _ = try ExportService.pdf(report); evidence.stages.append("pdf-export")
            evidence.networkAfter = await networkStatus()
            guard !requireOffline || evidence.networkAfter == "unsatisfied" else { throw AppFailure("Netzwerkpfad hat sich während des Tests geändert.") }
            evidence.completed = true
        } catch { evidence.error = error.localizedDescription }
        evidence.syntheticCandidates = captured.candidates
        sampler.cancel(); evidence.peakResidentMiB = await sampler.value
        evidence.durationSeconds = Date().timeIntervalSince(start); evidence.thermalState = String(describing: ProcessInfo.processInfo.thermalState)
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(evidence)
            try data.write(to: qaRoot.appendingPathComponent(requireOffline ? "offline-pipeline.json" : "full-pipeline.json"), options: [.atomic, .completeFileProtection])
            print("VETMED_OFFLINE_RESULT " + String(decoding: data, as: UTF8.self))
        } catch { print("VETMED_OFFLINE_RESULT_WRITE_FAILED") }
        print("VETMED_OFFLINE_END completed=\(evidence.completed)")
        return evidence.completed ? "Offline-Test bestanden: 5-Minuten-Audio, Transkript, Bericht, verschlüsseltes Wiederöffnen und PDF. Netzwerk vorher/nachher nicht verfügbar. Fachliche Prüfung bleibt offen." : "Offline-Test abgebrochen: " + (evidence.error ?? "Unbekannter Fehler")
    }
    private static func networkStatus() async -> String {
        let monitor = NWPathMonitor()
        let (stream, continuation) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(1))
        monitor.pathUpdateHandler = { path in continuation.yield(String(describing: path.status)); continuation.finish() }
        monitor.start(queue: DispatchQueue(label: "de.tobwil.vetmed.synthetic-network-status"))
        defer { monitor.cancel() }
        for await status in stream { return status }
        return "unknown"
    }
    static func runSpeech() async {
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }
        var results: [SpeechResult] = []
        do {
            print("VETMED_ASR_INSTALL_BEGIN")
            try await AppleOfflineTranscriber.install()
            print("VETMED_ASR_STATUS " + (await AppleOfflineTranscriber.status()))
            for seconds in [30, 120, 300] {
                let filename = "synthetic-\(seconds)s.wav"
                let file = AppPaths.root.appendingPathComponent("SyntheticQA").appendingPathComponent(filename)
                let start = Date()
                do {
                    let audio = try AVAudioFile(forReading: file)
                    let duration = Double(audio.length) / audio.fileFormat.sampleRate
                    let segments = try await AppleOfflineTranscriber().transcribe(file: file, audioID: UUID())
                    results.append(SpeechResult(file: filename, audioSeconds: duration, wallSeconds: Date().timeIntervalSince(start), segmentCount: segments.count, transcript: segments.map(\.text).joined(separator: " ")))
                    print("VETMED_ASR_FILE_DONE \(filename)")
                } catch {
                    results.append(SpeechResult(file: filename, audioSeconds: Double(seconds), wallSeconds: Date().timeIntervalSince(start), segmentCount: 0, transcript: "", error: error.localizedDescription))
                }
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(results)
            try data.write(to: AppPaths.root.appendingPathComponent("SyntheticQA/speech-results.json"), options: [.atomic, .completeFileProtection])
            print("VETMED_ASR_RESULTS " + String(decoding: data, as: UTF8.self))
        } catch { print("VETMED_ASR_FAILED \(error.localizedDescription)") }
        print("VETMED_ASR_END")
    }
    private static func residentMiB() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return status == KERN_SUCCESS ? UInt64(info.resident_size) / 1_048_576 : 0
    }
}
#endif
