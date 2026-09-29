import XCTest
import AVFoundation
import CryptoKit
@testable import VetMed

@MainActor
private final class SyntheticCapture: AudioCaptureFile {
    var isRecording = true
    var currentTime: TimeInterval = 1
    func stop() { isRecording = false }
}

@MainActor
private final class RecordingFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let center = NotificationCenter()
    var captures: [SyntheticCapture] = []
    var activations = 0
    var deactivations = 0
    var idleDisabled = false
    var space: Int64 = 100_000_000
    var allowed = true
    var active = true
    var saved: [AudioSegment] = []
    var interruptions = 0
    let payload = Data(repeating: 0x42, count: 32_000)
    func make() -> AudioRecorder {
        let environment = AudioRecordingEnvironment(permission: { self.allowed }, isActive: { self.active },
            activate: { self.activations += 1; self.route(.categoryChange) },
            deactivate: { self.deactivations += 1; self.route(.categoryChange) },
            idleTimer: { self.idleDisabled = $0 }, open: { url in
                try self.payload.write(to: url, options: [.atomic, .completeFileProtection])
                let capture = SyntheticCapture(); self.captures.append(capture); return capture
            }, scratch: root, availableBytes: { _ in self.space })
        let recorder = AudioRecorder(environment: environment, notifications: center)
        recorder.onSegment = { data, segment in XCTAssertEqual(data, self.payload); self.saved.append(segment) }
        recorder.onInterruption = { self.interruptions += 1 }
        return recorder
    }
    func route(_ reason: AVAudioSession.RouteChangeReason) {
        center.post(name: AVAudioSession.routeChangeNotification, object: nil, userInfo: [AVAudioSessionRouteChangeReasonKey: reason.rawValue])
    }
    func interrupt(_ type: AVAudioSession.InterruptionType) {
        center.post(name: AVAudioSession.interruptionNotification, object: nil, userInfo: [AVAudioSessionInterruptionTypeKey: type.rawValue])
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

@MainActor
final class AudioRecorderTests: XCTestCase {
    private func settle() async throws { try await Task.sleep(for: .milliseconds(80)) }
    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Audio lifecycle did not reach expected state")
    }
    func testOwnCategoryChangeAfterStartDoesNotAbortRecording() async throws {
        let f = RecordingFixture(); defer { f.cleanup() }
        let audio = f.make()
        try await audio.start(caseID: UUID(), encounterID: UUID())
        // This is emitted by setCategory/setActive, sometimes after record() returns.
        f.route(.categoryChange); f.route(.override); f.route(.routeConfigurationChange)
        try await settle()
        XCTAssertTrue(audio.isRecording); XCTAssertTrue(f.idleDisabled)
        XCTAssertEqual(f.interruptions, 0); XCTAssertEqual(f.saved.count, 0)
        await audio.pause()
        XCTAssertEqual(f.saved.count, 1); XCTAssertFalse(f.idleDisabled)
    }
    func testInterruptionEndNeverStopsOrAutomaticallyRestartsRecording() async throws {
        let f = RecordingFixture(); defer { f.cleanup() }
        let audio = f.make()
        try await audio.start(caseID: UUID(), encounterID: UUID())
        f.interrupt(.ended); try await settle()
        XCTAssertTrue(audio.isRecording)
        f.interrupt(.began)
        try await eventually { f.interruptions == 1 }
        XCTAssertFalse(audio.isRecording); XCTAssertEqual(f.saved.count, 1)
        f.interrupt(.ended); try await settle()
        XCTAssertFalse(audio.isRecording); XCTAssertEqual(f.activations, 1)
    }
    func testHeadsetRemovalSavesOnceAndResumeUsesNewSegment() async throws {
        let f = RecordingFixture(); defer { f.cleanup() }
        let audio = f.make(), caseID = UUID(), encounterID = UUID()
        try await audio.start(caseID: caseID, encounterID: encounterID)
        f.route(.oldDeviceUnavailable); f.interrupt(.began)
        try await eventually { f.interruptions == 1 }
        XCTAssertEqual(f.saved.count, 1); XCTAssertNotNil(audio.error)
        try await audio.start(caseID: caseID, encounterID: encounterID)
        XCTAssertNil(audio.error); XCTAssertTrue(audio.isRecording)
        await audio.pause()
        XCTAssertEqual(f.saved.count, 2); XCTAssertNotEqual(f.saved[0].id, f.saved[1].id)
        XCTAssertEqual(audio.elapsed, 2, accuracy: 0.01)
    }
    func testMediaServicesResetStopsCaptureAndKeepsSegment() async throws {
        let f = RecordingFixture(); defer { f.cleanup() }
        let audio = f.make()
        try await audio.start(caseID: UUID(), encounterID: UUID())
        f.center.post(name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
        try await eventually { f.interruptions == 1 }
        XCTAssertFalse(audio.isRecording); XCTAssertEqual(f.saved.count, 1)
    }
    func testStartCannotOvertakePendingSaveAndFailedSaveKeepsRecoveryFile() async throws {
        let f = RecordingFixture(); defer { f.cleanup() }
        let audio = f.make()
        var saveGate: CheckedContinuation<Void, Never>?
        audio.onSegment = { _, _ in
            await withCheckedContinuation { saveGate = $0 }
            throw AppFailure("synthetic full disk")
        }
        try await audio.start(caseID: UUID(), encounterID: UUID())
        let pause = Task { await audio.pause() }
        try await eventually { saveGate != nil }
        XCTAssertTrue(audio.isStopping)
        do { try await audio.start(caseID: UUID(), encounterID: UUID()); XCTFail("Started while saving") } catch {}
        XCTAssertEqual(f.activations, 1)
        saveGate?.resume(); await pause.value
        XCTAssertFalse(audio.isStopping); XCTAssertNotNil(audio.error)
        let files = try FileManager.default.contentsOfDirectory(at: f.root, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(files.first)), f.payload)
    }
    func testPauseDuringRolloverWaitsForSaveAndDoesNotStartAnotherSegment() async throws {
        let f = RecordingFixture(); defer { f.cleanup() }
        let audio = f.make()
        var saveGate: CheckedContinuation<Void, Never>?
        audio.onSegment = { _, segment in
            await withCheckedContinuation { saveGate = $0 }
            f.saved.append(segment)
        }
        try await audio.start(caseID: UUID(), encounterID: UUID())
        f.captures[0].currentTime = 20
        try await eventually { saveGate != nil }
        let pause = Task { await audio.pause() }
        try await eventually { audio.isStopping }
        XCTAssertEqual(f.deactivations, 0)
        saveGate?.resume(); await pause.value
        XCTAssertFalse(audio.isRecording); XCTAssertFalse(audio.isStopping)
        XCTAssertEqual(f.saved.count, 1); XCTAssertEqual(f.captures.count, 1)
        XCTAssertEqual(f.deactivations, 1)
    }
    func testPermissionAndBackgroundPreventOpeningMicrophone() async throws {
        for denied in [true, false] {
            let f = RecordingFixture(); defer { f.cleanup() }
            f.allowed = !denied; f.active = denied
            let audio = f.make()
            do { try await audio.start(caseID: UUID(), encounterID: UUID()); XCTFail("Unexpected start") } catch {}
            XCTAssertEqual(f.activations, 0); XCTAssertTrue(f.captures.isEmpty)
            XCTAssertFalse(audio.isStarting); XCTAssertFalse(audio.isRecording)
        }
    }
    func testInsufficientStorageDeactivatesSessionWithoutOpeningFile() async throws {
        let f = RecordingFixture(); defer { f.cleanup() }
        f.space = 1
        let audio = f.make()
        do { try await audio.start(caseID: UUID(), encounterID: UUID()); XCTFail("Unexpected start") } catch {}
        XCTAssertEqual(f.activations, 1); XCTAssertEqual(f.deactivations, 1)
        XCTAssertTrue(f.captures.isEmpty); XCTAssertFalse(audio.isStarting)
    }
    func testInterruptedSegmentReopensFromEncryptedRepositoryInCorrectCase() async throws {
        let f = RecordingFixture(); defer { f.cleanup() }
        let storeRoot = f.root.appendingPathComponent("vault")
        let key = SymmetricKey(size: .bits256)
        let repository = try CaseRepository(root: storeRoot, key: key)
        let audio = f.make(), caseID = UUID(), encounterID = UUID()
        var segmentID: UUID?
        audio.onSegment = { data, segment in
            try await repository.storeAudio(data, caseID: caseID, encounterID: encounterID, segmentID: segment.id)
            segmentID = segment.id
        }
        try await audio.start(caseID: caseID, encounterID: encounterID)
        f.interrupt(.began)
        try await eventually { f.interruptions == 1 }
        let id = try XCTUnwrap(segmentID)
        let reopened = try CaseRepository(root: storeRoot, key: key)
        let data = try await reopened.audio(caseID: caseID, encounterID: encounterID, segmentID: id)
        XCTAssertEqual(data, f.payload)
        do { _ = try await reopened.audio(caseID: UUID(), encounterID: encounterID, segmentID: id); XCTFail("Cross-case audio") } catch {}
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(at: f.root, includingPropertiesForKeys: nil).contains { $0.pathExtension == "caf" })
    }
}
