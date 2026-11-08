import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Combine)
import Combine
#endif

/// A WebSocket as the session needs it; `URLSessionWebSocketTask` in the app, a fake in tests.
@MainActor protocol LiveSocket: AnyObject {
    func send(_ text: String)
    func close()
}

@MainActor protocol LiveConnector {
    func connect(url: URL, onOpen: @escaping @MainActor () -> Void, onMessage: @escaping @MainActor (String) -> Void,
                 onClose: @escaping @MainActor (_ failure: String?) -> Void) -> any LiveSocket
}

enum LiveState: Equatable, Sendable {
    case idle, connecting, live
    /// The server announced the end of this connection; a new one resumes the same conversation.
    case resuming
    case ended(String?)
}

/// One voice conversation (ADR 0016), same behaviour as Android's `LiveSession`: connects with a one-time token,
/// keeps the transcript, hands 24 kHz PCM to `onAudio` and resumes after the server's go-away with the last handle.
/// A lost network ends the session visibly; nothing reconnects or resends on its own.
@MainActor
final class LiveSession: ObservableObject {
    @Published private(set) var state: LiveState = .idle
    @Published private(set) var turns: [LiveTurn] = []
    /// Seconds of audio sent and received, for the cost display.
    @Published private(set) var inputSeconds = 0.0
    @Published private(set) var outputSeconds = 0.0
    var onAudio: (Data) -> Void = { _ in }
    var onInterrupted: () -> Void = {}

    private let key: String
    private let instructions: String
    private let vocabulary: [String]
    private let connector: any LiveConnector
    private let transport: any ReportHTTPTransport
    private var socket: (any LiveSocket)?
    private var handle: String?
    private var generation = 0
    private var stopped = false
    private var muteUntilTurnEnds = false

    init(key: String, instructions: String, vocabulary: [String], connector: any LiveConnector, transport: any ReportHTTPTransport = EphemeralReportHTTP()) {
        self.key = key; self.instructions = instructions; self.vocabulary = vocabulary; self.connector = connector; self.transport = transport
    }

    func start() async {
        guard state == .idle else { return }
        state = .connecting
        await connect(resume: false)
    }

    private func connect(resume: Bool) async {
        generation += 1
        let attempt = generation
        let token: String
        do { token = try GeminiLive.token(try await transport.send(try GeminiLive.tokenRequest(key: key))) }
        catch { if attempt == generation, !stopped { end((error as? AppFailure)?.message ?? "Der Sprachmodus konnte nicht angemeldet werden. Keine Internetverbindung?") }; return }
        guard attempt == generation, !stopped else { return }
        let setup = GeminiLive.setup(instructions: instructions, vocabulary: vocabulary, handle: resume ? handle : nil)
        // onOpen can fire before connect() returns; the setup must go to this connection, never to the previous one.
        var opened: (any LiveSocket)?
        var openedEarly = false
        opened = connector.connect(url: GeminiLive.socketURL(token: token), onOpen: { [weak self] in
            guard let self, attempt == self.generation, !self.stopped else { return }
            if let opened { opened.send(setup) } else { openedEarly = true }
        }, onMessage: { [weak self] text in self?.receive(attempt, text) },
        onClose: { [weak self] failure in self?.closed(attempt, failure) })
        if openedEarly { opened?.send(setup) }
        let previous = socket
        socket = opened
        previous?.close()
    }

    private func receive(_ attempt: Int, _ text: String) {
        guard attempt == generation, !stopped else { return }
        for event in GeminiLive.parse(text) {
            switch event {
            case .setupComplete: state = .live
            case .audio(let pcm):
                if !muteUntilTurnEnds { outputSeconds += Double(pcm.count) / Double(GeminiLive.outputRate * 2); onAudio(pcm) }
            case .interrupted: muteUntilTurnEnds = false; onInterrupted()
            case .turnComplete: muteUntilTurnEnds = false
            case .resumption(let newHandle, let resumable): if resumable, let newHandle { handle = newHandle }
            case .goAway:
                if handle != nil { state = .resuming; Task { await connect(resume: true) } }
            case .failure(let message): end(message); return
            default: break
            }
            turns = LiveTranscript.apply(turns, event)
        }
    }

    private func closed(_ attempt: Int, _ failure: String?) {
        // The old connection closing after a resume is expected; only the current one matters.
        guard attempt == generation, !stopped, state != .resuming else { return }
        end(failure.map { _ in "Die Verbindung zum Sprachdienst wurde unterbrochen. Die Mitschrift bleibt erhalten; es wird nichts automatisch neu gestartet." }
            ?? "Der Sprachdienst hat das Gespräch beendet.")
    }

    private func end(_ message: String?) {
        stopped = true
        socket?.close(); socket = nil
        for index in turns.indices { turns[index].open = false }
        state = .ended(message)
    }

    /// Microphone audio, 16 kHz 16-bit PCM. Dropped while not connected; never buffered for later sending.
    func sendAudio(_ pcm: Data) {
        guard state == .live, !stopped, let socket else { return }
        socket.send(GeminiLive.audio(pcm))
        inputSeconds += Double(pcm.count) / Double(GeminiLive.inputRate * 2)
    }

    func sendImage(_ jpeg: Data) -> Bool {
        guard state == .live, let socket else { return false }
        socket.send(GeminiLive.image(jpeg)); return true
    }

    func pauseInput() { if state == .live { socket?.send(GeminiLive.audioStreamEnd()) } }

    /// "Unterbrechen": stop playing the current answer here; the rest of this turn is discarded.
    func interrupt() {
        muteUntilTurnEnds = true
        turns = LiveTranscript.apply(turns, .interrupted)
        onInterrupted()
    }

    func stop() { if !stopped { end(nil) } }
}

/// `URLSessionWebSocketTask` without cookies or cache. Text and binary frames are both read as UTF-8 JSON.
@MainActor
struct URLSessionLiveConnector: LiveConnector {
    private final class Socket: LiveSocket {
        let task: URLSessionWebSocketTask
        let session: URLSession
        init(task: URLSessionWebSocketTask, session: URLSession) { self.task = task; self.session = session }
        func send(_ text: String) { task.send(.string(text)) { _ in } }
        func close() { task.cancel(with: .normalClosure, reason: nil); session.invalidateAndCancel() }
    }

    func connect(url: URL, onOpen: @escaping @MainActor () -> Void, onMessage: @escaping @MainActor (String) -> Void,
                 onClose: @escaping @MainActor (String?) -> Void) -> any LiveSocket {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration)
        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = 16 * 1_048_576
        let socket = Socket(task: task, session: session)
        @Sendable func receive() {
            task.receive { result in
                switch result {
                case .success(let message):
                    let text: String
                    switch message {
                    case .string(let value): text = value
                    case .data(let value): text = String(decoding: value, as: UTF8.self)
                    @unknown default: text = ""
                    }
                    Task { @MainActor in onMessage(text) }
                    receive()
                case .failure:
                    // The URL carries the one-time token; it never goes into a message or log.
                    let code = task.closeCode
                    Task { @MainActor in onClose(code == .normalClosure ? nil : "closed") }
                }
            }
        }
        task.resume()
        receive()
        // Messages sent before the handshake completes are queued by the task.
        Task { @MainActor in onOpen() }
        return socket
    }
}
