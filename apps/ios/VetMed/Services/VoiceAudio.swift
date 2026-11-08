import AVFoundation
import Combine

/// Microphone and speaker for one voice conversation (ADR 0016). The voice-chat path cancels the echo, so the model
/// does not hear itself. Nothing is written to disk: audio only exists in these buffers while the conversation runs.
@MainActor
final class VoiceAudio: ObservableObject {
    /// 0…1 for the pulsing circle: the microphone while listening, the speaker while the model talks.
    @Published private(set) var level: Float = 0
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(GeminiLive.outputRate), channels: 1, interleaved: false)!
    private let sendFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(GeminiLive.inputRate), channels: 1, interleaved: true)!
    private var converter: AVAudioConverter?
    private var muted = false
    private var running = false

    func start(onChunk: @escaping @MainActor (Data) -> Void) throws {
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try audioSession.setActive(true)
        try engine.inputNode.setVoiceProcessingEnabled(true)
        let input = engine.inputNode.outputFormat(forBus: 0)
        guard input.sampleRate > 0, let converter = AVAudioConverter(from: input, to: sendFormat) else { throw AppFailure("Das Mikrofon konnte nicht geöffnet werden.") }
        self.converter = converter
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: outputFormat)
        let deliver: @Sendable (Data, Float) -> Void = { [weak self] data, level in
            Task { @MainActor [weak self] in
                guard let self, self.running, !self.muted else { return }
                if !self.player.isPlaying || self.level < level { self.level = level }
                onChunk(data)
            }
        }
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: input, block: Self.tap(converter: converter, input: input, output: sendFormat, deliver: deliver))
        engine.prepare()
        try engine.start()
        player.play()
        running = true
    }

    /// 24 kHz 16-bit PCM from the model, scheduled in order.
    func play(_ pcm: Data) {
        guard running, pcm.count >= 2 else { return }
        let frames = AVAudioFrameCount(pcm.count / 2)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frames), let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = frames
        var sum: Float = 0
        pcm.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for index in 0..<Int(frames) { let value = Float(Int16(littleEndian: samples[index])) / 32768; channel[index] = value; sum += value * value }
        }
        level = min(1, sqrt(sum / Float(frames)) * 4)
        player.scheduleBuffer(buffer)
        if !player.isPlaying { player.play() }
    }

    /// Drops everything scheduled for playback at once (interruption).
    func flush() { player.stop(); if running { player.play() } }

    func setMuted(_ muted: Bool) { self.muted = muted; if muted { level = 0 } }

    func stop() {
        running = false
        engine.inputNode.removeTap(onBus: 0)
        player.stop(); engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        level = 0
    }

    /// Runs on the audio thread, so it is built outside the main actor (Swift 6 would otherwise trap at runtime).
    nonisolated private static func tap(converter: AVAudioConverter, input: AVAudioFormat, output: AVAudioFormat,
                                        deliver: @escaping @Sendable (Data, Float) -> Void) -> AVAudioNodeTapBlock {
        { buffer, _ in
            // 16 kHz 16-bit mono, as Gemini Live expects.
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * output.sampleRate / input.sampleRate) + 32
            guard let converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return }
            var consumed = false
            var error: NSError?
            converter.convert(to: converted, error: &error) { _, status in
                if consumed { status.pointee = .noDataNow; return nil }
                consumed = true; status.pointee = .haveData; return buffer
            }
            guard error == nil, converted.frameLength > 0, let samples = converted.int16ChannelData else { return }
            deliver(Data(bytes: samples[0], count: Int(converted.frameLength) * 2), rms(samples[0], count: Int(converted.frameLength)))
        }
    }

    nonisolated private static func rms(_ samples: UnsafePointer<Int16>, count: Int) -> Float {
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for index in stride(from: 0, to: count, by: 4) { let value = Float(samples[index]) / 32768; sum += value * value }
        return min(1, sqrt(sum / Float((count + 3) / 4)) * 4)
    }
}
