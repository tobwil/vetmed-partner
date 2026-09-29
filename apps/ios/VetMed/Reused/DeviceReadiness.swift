import Foundation

/// Owns exactly one immutable Dispatch source and cancels it with its owner.
final class MemoryPressureMonitor: @unchecked Sendable {
    private let source: DispatchSourceMemoryPressure
    init(handler: @escaping @Sendable () -> Void) {
        source = DispatchSource.makeMemoryPressureSource(eventMask: .critical, queue: .main)
        source.setEventHandler(handler: handler)
        source.resume()
    }
    deinit { source.cancel() }
}

enum MemoryPressurePolicy {
    enum Action: Equatable { case reclaimedCaches, releaseIdleModel, stopActiveWork }

    /// Called AFTER reclaiming caches. Notification count/time is not a measurement
    /// of remaining memory: UIKit and Dispatch can repeatedly report one episode.
    static func action(availableBytes: Int, hasModel: Bool, activeWork: Bool) -> Action {
        guard availableBytes < 256 * 1_048_576 else { return .reclaimedCaches }
        if activeWork { return .stopActiveWork }
        return hasModel ? .releaseIdleModel : .reclaimedCaches
    }
}

enum DeviceReadiness {
    // Runtime protection, NOT an App Store device filter or device qualification claim.
    static func blockingReason(modelID: String, physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory,
                               criticalTemperature: Bool = ProcessInfo.processInfo.thermalState == .critical) -> String? {
        guard ModelOption.supported.contains(where: { $0.id == modelID }) else {
            return "Dieses Modell ist in diesem Release nicht freigegeben. Bitte Gemma 4 ausdrücklich in den Einstellungen auswählen. Vorhandene Downloads, Chats und Profile bleiben erhalten."
        }
        if criticalTemperature { return "Das iPhone ist zu warm. Bitte abkühlen lassen, bevor du die lokale KI erneut startest." }
        if physicalMemory < 8_000_000_000 { return "Für diese Version sind mindestens 8 GB Arbeitsspeicher vorgesehen. Der Download wird nicht gestartet. Die Gerätefreigabe für den App Store steht noch aus." }
        return nil
    }
    static var summary: String {
        "Arbeitsspeicher: " + ByteCountFormatter.string(fromByteCount: Int64(ProcessInfo.processInfo.physicalMemory), countStyle: .memory)
    }
}
