import SwiftUI

/// The voice conversation (ADR 0016), same layout as Android's `VoiceOverlay`: a circle that follows the voice, the
/// live transcript of both sides, mute, interrupt and end. The circle only moves with the audio level.
struct VoiceView: View {
    @EnvironmentObject private var app: VetAppModel
    @Environment(\.accentTheme) private var theme
    @ObservedObject var session: LiveSession
    @ObservedObject var audio: VoiceAudio
    @State private var muted = false

    var body: some View {
        VStack(spacing: 14) {
            Text("Sprachmodus").font(.title2.bold())
            Text(status).font(.subheadline).foregroundStyle(isEnded ? Color.red : Color.secondary).multilineTextAlignment(.center)
                .accessibilityIdentifier("voice-status")
            ZStack {
                Circle().fill(theme.primary.opacity(0.18)).frame(width: 120, height: 120).scaleEffect(1 + CGFloat(min(max(audio.level, 0), 1)) * 0.35)
                    .animation(.spring(response: 0.25, dampingFraction: 0.6), value: audio.level)
                Circle().fill(muted ? AnyShapeStyle(Color.gray) : AnyShapeStyle(theme.gradient)).frame(width: 96, height: 96)
                Image(systemName: muted ? "mic.slash.fill" : "mic.fill").font(.system(size: 40, weight: .semibold)).foregroundStyle(.white)
            }.frame(height: 150).accessibilityHidden(true)
            Text("Gesprochen \(clock(session.inputSeconds)) · Antwort \(clock(session.outputSeconds)) · ca. \(String(format: "%.2f", GeminiLive.costUSD(inputSeconds: session.inputSeconds, outputSeconds: session.outputSeconds))) US-$")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(session.turns) { turn in
                            HStack {
                                if turn.fromUser { Spacer(minLength: 40) }
                                Text(turn.text + (turn.interrupted ? " (unterbrochen)" : "")).padding(12)
                                    .background(turn.fromUser ? AnyShapeStyle(theme.primary.opacity(0.16)) : AnyShapeStyle(.regularMaterial), in: RoundedRectangle(cornerRadius: 16))
                                if !turn.fromUser { Spacer(minLength: 40) }
                            }.id(turn.id)
                        }
                    }
                }
                .onChange(of: session.turns.last?.text) { _, _ in if let last = session.turns.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } } }
            }
            Text("Gespeichert wird nur die Mitschrift, kein Audio. Keine Websuche. Antworten fachlich prüfen.").font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button(muted ? "Mikro an" : "Stumm", systemImage: muted ? "mic.fill" : "mic.slash.fill") { muted.toggle(); app.setVoiceMuted(muted) }
                    .buttonStyle(.bordered).frame(maxWidth: .infinity).disabled(session.state != .live).accessibilityIdentifier("voice-mute")
                Button("Unterbrechen", systemImage: "hand.raised.fill") { session.interrupt() }
                    .buttonStyle(.bordered).frame(maxWidth: .infinity).disabled(session.state != .live).accessibilityIdentifier("voice-interrupt")
            }
            Button(role: .destructive) { Task { await app.endVoice() } } label: {
                Label("Beenden und Mitschrift speichern", systemImage: "phone.down.fill").frame(maxWidth: .infinity)
            }.buttonStyle(.borderedProminent).tint(.red).controlSize(.large).accessibilityIdentifier("voice-end")
        }
        .padding(20)
        .themedBackground()
    }

    private var isEnded: Bool { if case .ended = session.state { true } else { false } }
    private var status: String {
        switch session.state {
        case .idle, .connecting: "Verbinde mit Gemini …"
        case .live: muted ? "Mikrofon aus" : "Hört zu · einfach sprechen"
        case .resuming: "Verbindung wird erneuert …"
        case .ended(let message): message ?? "Gespräch beendet"
        }
    }
    private func clock(_ seconds: Double) -> String { String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60) }
}

extension VetAppModel {
    static let voiceConsentText = "Im Sprachmodus gehen deine Stimme und der gewählte Fallkontext (ausgewählte Berichte, Falltext und bestätigte Labortabellen) live an Google Gemini. Gespeichert wird nur die Mitschrift im Chat, kein Audio. Eine Websuche gibt es nicht.\n\nKosten im bezahlten Kontingent: ca. 0,5 US-Cent pro Minute Sprechen und 1,8 US-Cent pro Minute Antwort. Für Patienten- und Halterdaten nur einen Key mit aktivierter Abrechnung verwenden: Im kostenlosen Kontingent darf Google Eingaben zur Produktverbesserung nutzen."
}
