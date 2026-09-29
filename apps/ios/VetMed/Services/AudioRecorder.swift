import Foundation
import AVFoundation
import Combine
import UIKit

@MainActor
protocol AudioCaptureFile: AnyObject {
    var isRecording: Bool { get }
    var currentTime: TimeInterval { get }
    func stop()
}
extension AVAudioRecorder: AudioCaptureFile {}

/// The production implementation uses the microphone. Tests supply synthetic files instead.
@MainActor
struct AudioRecordingEnvironment {
    var permission: () async -> Bool
    var isActive: () -> Bool
    var activate: () throws -> Void
    var deactivate: () -> Void
    var idleTimer: (Bool) -> Void
    var open: (URL) throws -> any AudioCaptureFile
    var scratch: URL
    var availableBytes: (URL) throws -> Int64

    static var live: Self {
        Self(permission: { await AVAudioApplication.requestRecordPermission() },
             isActive: { UIApplication.shared.applicationState == .active },
             activate: {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
                try session.setActive(true)
             }, deactivate: { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) },
             idleTimer: { UIApplication.shared.isIdleTimerDisabled = $0 },
             open: { url in
                let audio = try AVAudioRecorder(url: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000,
                    AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false])
                guard audio.prepareToRecord() else { throw AppFailure("Aufnahme konnte nicht vorbereitet werden.") }
                try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
                guard audio.record() else { throw AppFailure("Aufnahme konnte nicht gestartet werden.") }
                return audio
             }, scratch: AppPaths.scratch,
             availableBytes: { try $0.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0 })
    }
}

/// Classify before the actor hop: category changes from our own start/stop are not interruptions.
enum RecordingSessionEvent: Sendable {
    case interruptionBegan, routeChanged, mediaServicesLost
    var message: String {
        switch self {
        case .interruptionBegan: "iOS hat die Audioaufnahme unterbrochen. Du kannst sie mit Fortsetzen erneut starten."
        case .routeChanged: "Die Audioverbindung wurde geändert. Bitte das Mikrofon prüfen und die Aufnahme bewusst fortsetzen."
        case .mediaServicesLost: "Der iOS-Audiodienst wurde beendet oder neu gestartet. Bitte die Aufnahme erneut starten."
        }
    }
    static func parse(_ notification: Notification) -> Self? {
        switch notification.name {
        case AVAudioSession.interruptionNotification:
            guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return nil }
            return .interruptionBegan
        case AVAudioSession.routeChangeNotification:
            guard let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return nil }
            switch reason {
            case .oldDeviceUnavailable, .newDeviceAvailable, .noSuitableRouteForCategory: return .routeChanged
            // setCategory/setActive can deliver these after record() has already returned.
            // If recording actually stops, the recorder-state check handles that separately.
            default: return nil
            }
        case AVAudioSession.mediaServicesWereLostNotification, AVAudioSession.mediaServicesWereResetNotification:
            return .mediaServicesLost
        default: return nil
        }
    }
}

@MainActor
final class AudioRecorder: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isStarting = false
    @Published private(set) var isStopping = false
    var isTransitioning: Bool { isStarting || isStopping }
    @Published private(set) var elapsed: Double = 0
    @Published var error: String?
    private let environment: AudioRecordingEnvironment
    private let notifications: NotificationCenter
    private var recorder: (any AudioCaptureFile)?
    private var timer: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var generation = UUID()
    private var currentID: UUID?
    private var currentURL: URL?
    private var completedDuration: Double = 0
    private var caseID: UUID?
    private var encounterID: UUID?
    private var saving = false
    private var saveWaiters: [CheckedContinuation<Void, Never>] = []
    var onSegment: (@MainActor (Data, AudioSegment) async throws -> Void)?
    var onInterruption: (@MainActor () async -> Void)?
    init(environment: AudioRecordingEnvironment = .live, notifications: NotificationCenter = .default) {
        self.environment = environment; self.notifications = notifications
        super.init()
        for name in [AVAudioSession.interruptionNotification, AVAudioSession.routeChangeNotification,
                     AVAudioSession.mediaServicesWereLostNotification, AVAudioSession.mediaServicesWereResetNotification] {
            observers.append(notifications.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                guard let event = RecordingSessionEvent.parse(notification) else { return }
                // NotificationCenter's main queue guarantees this synchronous access is on MainActor.
                MainActor.assumeIsolated { self?.handle(event) }
            })
        }
    }
    private func handle(_ event: RecordingSessionEvent) {
        guard isRecording else { return }
        let activeGeneration = generation
        Task { [weak self] in
            guard let self, self.isRecording, self.generation == activeGeneration else { return }
            self.error = event.message
            let interrupted = self.onInterruption
            await self.pause(); await interrupted?()
        }
    }
    func start(caseID: UUID, encounterID: UUID) async throws {
        guard !isRecording, !saving, !isTransitioning else { throw AppFailure("Bitte warten, bis die laufende Aufnahmeaktion abgeschlossen ist.") }
        isStarting = true
        defer { isStarting = false }
        guard await environment.permission() else { throw AppFailure("Mikrofonzugriff fehlt. Bitte in den iOS-Einstellungen erlauben.") }
        try Task.checkCancellation()
        guard environment.isActive() else { throw AppFailure("Bitte die App öffnen und die Aufnahme erneut starten.") }
        if self.caseID != caseID || self.encounterID != encounterID { completedDuration = 0; elapsed = 0 }
        self.caseID = caseID; self.encounterID = encounterID
        generation = UUID()
        do { try environment.activate(); try beginSegment() }
        catch { environment.deactivate(); throw error }
        isRecording = true; error = nil; environment.idleTimer(true)
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
        guard !isStopping else { return }
        isStopping = true
        defer { isStopping = false }
        generation = UUID()
        isRecording = false; timer?.cancel(); timer = nil
        environment.idleTimer(false)
        // A segment rollover may already be awaiting its durable save. Never resume or switch
        // case before that save completes, and never deactivate a later recording session.
        if saving { await withCheckedContinuation { saveWaiters.append($0) } }
        do { try await finishSegment() } catch { self.error = error.localizedDescription }
        environment.deactivate()
    }
    private func beginSegment() throws {
        guard let caseID, let encounterID else { throw AppFailure("Aufnahme hat keinen Vorgang.") }
        try AppPaths.prepare(environment.scratch)
        guard try environment.availableBytes(environment.scratch) >= 20_000_000 else { throw AppFailure("Zu wenig freier Speicher für eine sichere Aufnahme. Bitte Speicher freigeben; vorhandene Segmente bleiben erhalten.") }
        let id = UUID()
        // IDs allow recovery without a cleartext sidecar containing clinical information.
        let url = environment.scratch.appendingPathComponent("\(caseID)_\(encounterID)_\(id).caf")
        recorder = try environment.open(url); currentID = id; currentURL = url
    }
    private func finishSegment() async throws {
        guard !saving, let recorder, let id = currentID, let url = currentURL else { return }
        saving = true
        defer {
            saving = false
            let waiters = saveWaiters; saveWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
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
