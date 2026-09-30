import SwiftUI
import UIKit

// MARK: - Appearance (Tag / Nacht)

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    static let storageKey = "appearance-mode"
    var id: String { rawValue }
    var title: String {
        switch self { case .system: "Automatisch"; case .light: "Tag"; case .dark: "Nacht" }
    }
    var symbol: String {
        switch self { case .system: "circle.lefthalf.filled"; case .light: "sun.max.fill"; case .dark: "moon.stars.fill" }
    }
    var interfaceStyle: UIUserInterfaceStyle {
        switch self { case .system: .unspecified; case .light: .light; case .dark: .dark }
    }
}

/// Applies the chosen appearance to every window. The day/night toggle reveals the new
/// appearance with a circle growing from the toggle; other changes cross-fade.
@MainActor
enum AppearanceSwitcher {
    static func apply(_ mode: AppearanceMode, revealFrom origin: CGPoint? = nil, animated: Bool = true) {
        let style = mode.interfaceStyle
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        for window in windows where window.overrideUserInterfaceStyle != style {
            guard animated, !UIAccessibility.isReduceMotionEnabled else {
                window.overrideUserInterfaceStyle = style
                continue
            }
            guard let origin, window.isKeyWindow, let snapshot = window.snapshotView(afterScreenUpdates: false) else {
                UIView.transition(with: window, duration: 0.35, options: [.transitionCrossDissolve, .allowUserInteraction]) {
                    window.overrideUserInterfaceStyle = style
                }
                continue
            }
            reveal(style, in: window, snapshot: snapshot, from: origin)
        }
    }

    private static func reveal(_ style: UIUserInterfaceStyle, in window: UIWindow, snapshot: UIView, from origin: CGPoint) {
        let bounds = window.bounds
        snapshot.frame = bounds
        snapshot.isUserInteractionEnabled = false
        window.addSubview(snapshot)
        window.overrideUserInterfaceStyle = style
        let radius = hypot(max(origin.x, bounds.width - origin.x), max(origin.y, bounds.height - origin.y)) + 20
        func hole(_ r: CGFloat) -> CGPath {
            let path = UIBezierPath(rect: bounds)
            path.append(UIBezierPath(arcCenter: origin, radius: r, startAngle: 0, endAngle: .pi * 2, clockwise: true))
            return path.cgPath
        }
        let mask = CAShapeLayer()
        mask.fillRule = .evenOdd
        mask.path = hole(radius)
        snapshot.layer.mask = mask
        let animation = CABasicAnimation(keyPath: "path")
        animation.fromValue = hole(0.1)
        animation.toValue = hole(radius)
        animation.duration = 0.6
        animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.65, 0, 0.35, 1)
        mask.add(animation, forKey: "reveal")
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(650))
            snapshot.removeFromSuperview()
        }
    }
}

// MARK: - Farbthemen

enum AccentTheme: String, CaseIterable, Identifiable {
    case klinik, ozean, lavendel, koralle, wald, graphit
    static let storageKey = "accent-theme"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .klinik: "Klinik"
        case .ozean: "Ozean"
        case .lavendel: "Lavendel"
        case .koralle: "Koralle"
        case .wald: "Wald"
        case .graphit: "Graphit"
        }
    }
    /// Main tint: buttons, icons, selection.
    var primary: Color {
        switch self {
        case .klinik: Color(light: (0.05, 0.47, 0.43), dark: (0.30, 0.82, 0.74))
        case .ozean: Color(light: (0.07, 0.38, 0.85), dark: (0.42, 0.66, 1.00))
        case .lavendel: Color(light: (0.44, 0.29, 0.84), dark: (0.72, 0.62, 1.00))
        case .koralle: Color(light: (0.86, 0.33, 0.26), dark: (1.00, 0.56, 0.47))
        case .wald: Color(light: (0.16, 0.50, 0.24), dark: (0.50, 0.83, 0.47))
        case .graphit: Color(light: (0.22, 0.26, 0.32), dark: (0.80, 0.84, 0.90))
        }
    }
    /// Gradient partner of `primary`.
    var secondary: Color {
        switch self {
        case .klinik: Color(light: (0.13, 0.62, 0.78), dark: (0.36, 0.72, 0.95))
        case .ozean: Color(light: (0.05, 0.66, 0.80), dark: (0.35, 0.88, 0.95))
        case .lavendel: Color(light: (0.84, 0.32, 0.62), dark: (1.00, 0.55, 0.80))
        case .koralle: Color(light: (0.95, 0.60, 0.15), dark: (1.00, 0.76, 0.36))
        case .wald: Color(light: (0.55, 0.66, 0.10), dark: (0.80, 0.90, 0.40))
        case .graphit: Color(light: (0.36, 0.44, 0.60), dark: (0.55, 0.62, 0.78))
        }
    }
    var gradient: LinearGradient {
        LinearGradient(colors: [primary, secondary], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

extension Color {
    /// A color that adapts to light and dark mode.
    init(light: (Double, Double, Double), dark: (Double, Double, Double)) {
        self.init(uiColor: UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: value.0, green: value.1, blue: value.2, alpha: 1)
        })
    }
}

private struct AccentThemeKey: EnvironmentKey {
    static let defaultValue: AccentTheme = .klinik
}
extension EnvironmentValues {
    var accentTheme: AccentTheme {
        get { self[AccentThemeKey.self] }
        set { self[AccentThemeKey.self] = newValue }
    }
}

// MARK: - Hintergrund

/// Soft, slowly drifting mesh gradient in the current theme colors.
struct AmbientBackground: View {
    @Environment(\.accentTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drift = false
    var body: some View {
        let strong = theme.primary.opacity(scheme == .dark ? 0.30 : 0.18)
        let soft = theme.secondary.opacity(scheme == .dark ? 0.20 : 0.12)
        let d: Float = drift ? 0.12 : -0.08
        ZStack {
            Color(.systemGroupedBackground)
            MeshGradient(width: 3, height: 3, points: [
                [0, 0], [0.5 + d, 0], [1, 0],
                [0, 0.45 - d], [0.5 - d, 0.5 + d], [1, 0.4 + d],
                [0, 1], [0.5 + d, 1], [1, 1]
            ], colors: [
                strong, soft, .clear,
                soft, .clear, strong.opacity(0.6),
                .clear, soft.opacity(0.7), soft
            ])
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.6), value: theme)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 9).repeatForever(autoreverses: true)) { drift = true }
        }
    }
}

extension View {
    /// Transparent list/form background on top of the ambient theme gradient.
    func themedBackground() -> some View {
        scrollContentBackground(.hidden).background { AmbientBackground() }
    }
    /// Rounded content card that sits on the ambient background.
    func card(cornerRadius: CGFloat = 22, inset: CGFloat = 16) -> some View {
        padding(inset)
            .background(Color(.secondarySystemGroupedBackground).opacity(0.82), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
    }
    /// Fades and lifts content in once, optionally staggered.
    func appearEffect(delay: Double = 0) -> some View { modifier(AppearEffect(delay: delay)) }
}

private struct AppearEffect: ViewModifier {
    let delay: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false
    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 16)
            .onAppear {
                guard !shown else { return }
                withAnimation(.spring(response: 0.55, dampingFraction: 0.82).delay(reduceMotion ? 0 : delay)) { shown = true }
            }
    }
}

/// Gently scales a button while pressed and dims it while disabled.
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { PressableBody(configuration: configuration) }
    private struct PressableBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        var body: some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .brightness(configuration.isPressed ? -0.03 : 0)
                .opacity(isEnabled ? 1 : 0.5)
                .animation(.spring(response: 0.28, dampingFraction: 0.6), value: configuration.isPressed)
        }
    }
}

// MARK: - Bausteine

/// Tag/Nacht-Schalter mit Kreis-Übergang.
struct DayNightToggle: View {
    @AppStorage(AppearanceMode.storageKey) private var mode: AppearanceMode = .system
    @Environment(\.colorScheme) private var scheme
    @State private var frame: CGRect = .zero
    var body: some View {
        Button {
            // Avoid SwiftUI's location-based sensory-feedback callback during appearance graph teardown.
            UISelectionFeedbackGenerator().selectionChanged()
            let next: AppearanceMode = scheme == .dark ? .light : .dark
            AppearanceSwitcher.apply(next, revealFrom: frame == .zero ? nil : CGPoint(x: frame.midX, y: frame.midY))
            mode = next
        } label: {
            Image(systemName: scheme == .dark ? "moon.stars.fill" : "sun.max.fill")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(scheme == .dark ? Color.yellow : Color.orange)
                .contentTransition(.symbolEffect(.replace.downUp))
        }
        .accessibilityLabel(scheme == .dark ? "Tagmodus" : "Nachtmodus")
        .accessibilityIdentifier("toggle-appearance")
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
    }
}

/// Einstellungen: Tag/Nacht und Farbthema.
struct AppearanceSettingsSection: View {
    @AppStorage(AppearanceMode.storageKey) private var mode: AppearanceMode = .system
    @AppStorage(AccentTheme.storageKey) private var theme: AccentTheme = .klinik
    var body: some View {
        Section("Darstellung") {
            Picker("Modus", selection: $mode) {
                ForEach(AppearanceMode.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).accessibilityIdentifier("appearance-mode")
            VStack(alignment: .leading, spacing: 12) {
                Text("Farbthema").font(.subheadline.weight(.medium))
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 14) {
                    ForEach(AccentTheme.allCases) { value in
                        ThemeSwatch(theme: value, selected: theme == value) {
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { theme = value }
                        }
                    }
                }
            }.padding(.vertical, 6)
        }
    }
}

private struct ThemeSwatch: View {
    let theme: AccentTheme
    let selected: Bool
    var action: () -> Void
    var body: some View {
        Button {
            if !selected { UISelectionFeedbackGenerator().selectionChanged() }
            action()
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    Circle().fill(theme.gradient).frame(width: 44, height: 44)
                        .shadow(color: theme.primary.opacity(selected ? 0.45 : 0), radius: 8, y: 3)
                    if selected {
                        Image(systemName: "checkmark").font(.headline.bold()).foregroundStyle(.white)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .overlay(Circle().strokeBorder(theme.primary, lineWidth: selected ? 2 : 0).padding(-4))
                .scaleEffect(selected ? 1.08 : 1)
                Text(theme.title).font(.caption).foregroundStyle(selected ? .primary : .secondary)
            }.frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Farbthema " + theme.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Runder Icon-Hintergrund im Themenverlauf.
struct GradientIcon: View {
    @Environment(\.accentTheme) private var theme
    let systemName: String
    var size: CGFloat = 44
    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(theme.gradient, in: RoundedRectangle(cornerRadius: size * 0.32, style: .continuous))
            .shadow(color: theme.primary.opacity(0.3), radius: 6, y: 3)
            .accessibilityHidden(true)
    }
}

/// Drei hüpfende Punkte, während die KI antwortet.
struct TypingIndicator: View {
    @State private var animate = false
    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                Circle().fill(.tint).frame(width: 7, height: 7)
                    .scaleEffect(animate ? 1 : 0.55)
                    .opacity(animate ? 1 : 0.35)
                    .offset(y: animate ? -2 : 2)
                    .animation(.easeInOut(duration: 0.55).repeatForever().delay(Double(index) * 0.18), value: animate)
            }
        }
        .onAppear { animate = true }
        .accessibilityHidden(true)
    }
}

/// Pulsierende Ringe hinter der Aufnahmetaste.
struct PulseRings: View {
    let active: Bool
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !active || reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(0..<3, id: \.self) { index in
                    let phase = (t / 2.4 + Double(index) / 3).truncatingRemainder(dividingBy: 1)
                    Circle().stroke(color, lineWidth: 2)
                        .scaleEffect(1 + phase * 0.7)
                        .opacity(active && !reduceMotion ? (1 - phase) * 0.55 : 0)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

enum Greeting {
    static func text(for date: Date = .now) -> String {
        switch Calendar.current.component(.hour, from: date) {
        case 5..<11: "Guten Morgen"
        case 11..<17: "Guten Tag"
        case 17..<22: "Guten Abend"
        default: "Gute Nacht"
        }
    }
    static func symbol(for date: Date = .now) -> String {
        switch Calendar.current.component(.hour, from: date) {
        case 5..<8: "sunrise.fill"
        case 8..<18: "sun.max.fill"
        case 18..<21: "sunset.fill"
        default: "moon.stars.fill"
        }
    }
}

enum SpeciesIcon {
    static func symbol(for species: String) -> String {
        let value = species.lowercased()
        func has(_ words: String...) -> Bool { words.contains { value.contains($0) } }
        if has("hund", "dog", "welpe") { return "dog.fill" }
        if has("katze", "kater", "cat") { return "cat.fill" }
        if has("vogel", "papagei", "sittich", "huhn", "bird") { return "bird.fill" }
        if has("fisch", "fish") { return "fish.fill" }
        if has("kaninchen", "hase", "rabbit") { return "hare.fill" }
        if has("schildkröte", "tortoise") { return "tortoise.fill" }
        if has("echse", "reptil", "gecko", "agame", "leguan", "schlange") { return "lizard.fill" }
        if has("pferd", "pony", "horse") { return "figure.equestrian.sports" }
        return "pawprint.fill"
    }
}
