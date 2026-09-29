import Foundation
import AVFoundation
import Combine
import UIKit

@MainActor
final class AudioRecorder: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isStarting = false
    @Published private(set) var elapsed: Double = 0
    @Published var error: String?
    private var recorder: AVAudioRecorder?
    private var timer: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var currentID: UUID?
    private var currentURL: URL?
    private var completedDuration: Double = 0
    private var caseID: UUID?
    private var encounterID: UUID?
    private var saving = false
    var onSegment: (@MainActor (Data, AudioSegment) async throws -> Void)?
    var onInterruption: (@MainActor () async -> Void)?
    override init() {
        super.init()
        for name in [AVAudioSession.interruptionNotification, AVAudioSession.routeChangeNotification, AVAudioSession.mediaServicesWereResetNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.isRecording else { return }
                    await self.pause(); await self.onInterruption?()
                }
            })
        }
    }
    func start(caseID: UUID, encounterID: UUID) async throws {
        guard !isRecording, !saving, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        guard await AVAudioApplication.requestRecordPermission() else { throw AppFailure("Mikrofonzugriff fehlt. Bitte in den iOS-Einstellungen erlauben.") }
        guard UIApplication.shared.applicationState == .active else { throw AppFailure("Bitte die App öffnen und die Aufnahme erneut starten.") }
        if self.encounterID != encounterID { completedDuration = 0; elapsed = 0 }
        self.caseID = caseID; self.encounterID = encounterID
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try session.setActive(true)
        try beginSegment()
        isRecording = true; error = nil; UIApplication.shared.isIdleTimerDisabled = true
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled, let self, self.isRecording else { break }
                if let audio = self.recorder, !audio.isRecording {
                    self.error = "Die Aufnahme wurde vom System beendet. Gesicherte Segmente bleiben erhalten."
                    await self.pause(); await self.onInterruption?(); break
                }
                self.elapsed = self.completedDuration + (self.recorder?.currentTime ?? 0)
                if (self.recorder?.currentTime ?? 0) >= 20 {
                    do { try await self.finishSegment(); if self.isRecording { try self.beginSegment() } }
                    catch { self.error = error.localizedDescription; await self.pause(); await self.onInterruption?(); break }
                }
            }
        }
    }
    func pause() async {
        isRecording = false; timer?.cancel(); timer = nil
        UIApplication.shared.isIdleTimerDisabled = false
        do { try await finishSegment() } catch { self.error = error.localizedDescription }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    private func beginSegment() throws {
        guard let caseID, let encounterID else { throw AppFailure("Aufnahme hat keinen Vorgang.") }
        try AppPaths.prepare(AppPaths.scratch)
        let free = try AppPaths.scratch.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
        guard free >= 20_000_000 else { throw AppFailure("Zu wenig freier Speicher für eine sichere Aufnahme. Bitte Speicher freigeben; vorhandene Segmente bleiben erhalten.") }
        let id = UUID()
        // IDs allow recovery without a cleartext sidecar containing clinical information.
        let url = AppPaths.scratch.appendingPathComponent("\(caseID)_\(encounterID)_\(id).caf")
        let audio = try AVAudioRecorder(url: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false])
        guard audio.prepareToRecord() else { throw AppFailure("Aufnahme konnte nicht vorbereitet werden.") }
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        guard audio.record() else { throw AppFailure("Aufnahme konnte nicht gestartet werden.") }
        recorder = audio; currentID = id; currentURL = url
    }
    private func finishSegment() async throws {
        guard !saving, let recorder, let id = currentID, let url = currentURL else { return }
        saving = true
        defer { saving = false }
        var duration = recorder.currentTime
        recorder.stop(); self.recorder = nil; currentID = nil; currentURL = nil
        if duration <= 0.05, let file = try? AVAudioFile(forReading: url) { duration = Double(file.length) / file.fileFormat.sampleRate }
        guard duration > 0.05 else { throw AppFailure("Das letzte Audiosegment ist unvollständig. Die Datei bleibt zur Wiederherstellung erhalten.") }
        let data = try Data(contentsOf: url)
        guard let onSegment else { throw AppFailure("Aufnahme kann keinem Fallspeicher zugeordnet werden.") }
        try await onSegment(data, AudioSegment(id: id, duration: duration))
        completedDuration += duration; elapsed = completedDuration
        try FileManager.default.removeItem(at: url)
    }
}
