import SwiftUI

extension Color {
    /// `Color(hex: 0x2E7D32)`
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

/// The code-editor look: text colours for light and dark.
struct Theme: Equatable {
    var dark: Bool

    private func pick(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(hex: self.dark ? dark : light)
    }

    /// Titles. As dark (or light) as it gets, for contrast.
    var text: Color { pick(0x1F2328, 0xF0F6FC) }
    /// Detail lines.
    var detail: Color { pick(0x57606A, 0xABB2BF) }
    /// `//` section headers.
    var comment: Color { pick(0x2E7D32, 0x7EC07A) }
    var overdue: Color { pick(0xCF222E, 0xFF7B72) }
    var late: Color { pick(0xBC4C00, 0xFFA657) }
    /// Done / success.
    var success: Color { pick(0x1A7F37, 0x7EE787) }
    /// The `$` in commands, links, the prompt.
    var accent: Color { pick(0x0969DA, 0x79C0FF) }
    /// Indent guides, placeholders, things that should sit back.
    var faint: Color { pick(0x8C959F, 0x6E7681) }
    var background: Color { pick(0xFFFFFF, 0x0D1117) }
    /// The header and footer strips, a shade off the background.
    var chrome: Color { pick(0xF6F8FA, 0x161B22) }
    var separator: Color { dark ? Color.white.opacity(0.11) : Color.black.opacity(0.10) }
    var hover: Color { dark ? Color.white.opacity(0.075) : Color.black.opacity(0.055) }
    var selection: Color { dark ? Color(hex: 0x388BFD, opacity: 0.22) : Color(hex: 0x0969DA, opacity: 0.12) }
    /// Behind the letters that match what you typed in the prompt.
    var match: Color { dark ? Color(hex: 0xBB8009, opacity: 0.45) : Color(hex: 0xFFD33D, opacity: 0.55) }

    /// A step type as text (`prepare`, `do`, `prac`): the icon tints, darkened in light mode so they stay readable.
    func stepText(_ type: String) -> Color {
        switch type {
        case "Prepare": return pick(0x0969DA, 0x79C0FF)
        case "Do": return pick(0x9A6700, 0xE3B341)
        case "Prac": return pick(0x8250DF, 0xD2A8FF)
        default: return detail
        }
    }

    func color(for state: RowState) -> Color {
        switch state {
        case .normal: return detail
        case .overdue: return overdue
        case .late: return late
        }
    }
}

/// Icon tints. One value each, readable on light and dark.
enum Tint {
    static let blue = Color(hex: 0x3B8EEA)
    static let yellow = Color(hex: 0xD4A72C)
    static let purple = Color(hex: 0xA371F7)
    static let red = Color(hex: 0xF85149)
    static let orange = Color(hex: 0xDB6D28)
    static let green = Color(hex: 0x3FB950)
    static let gray = Color(hex: 0x8B949E)

    static func step(_ type: String) -> Color {
        switch type {
        case "Prepare": return blue
        case "Do": return yellow
        case "Prac": return purple
        default: return gray
        }
    }

    /// SF Symbol and tint for a task, from the first type it has that we know.
    static func task(_ types: [String]) -> (symbol: String, color: Color) {
        for type in types {
            switch type {
            case "test": return ("graduationcap", red)
            case "homework": return ("book.closed", blue)
            case "project": return ("hammer", yellow)
            case "personal": return ("person", green)
            default: continue
            }
        }
        return ("doc.text", gray)
    }

    /// The icon for a row, with overdue and late taking over the tint.
    static func icon(for item: Item, state: RowState) -> (symbol: String, color: Color) {
        var icon = item.kind == .step ? ("chevron.right", step(item.stepType)) : task(item.types)
        if state == .overdue { icon.1 = red }
        if state == .late { icon.1 = orange }
        return icon
    }
}

/// Menlo, everywhere.
enum Mono {
    static func font(_ size: CGFloat, bold: Bool = false) -> Font {
        .custom(bold ? "Menlo-Bold" : "Menlo-Regular", fixedSize: size)
    }
}

/// Sizes that follow the "text size" setting.
struct Metrics: Equatable {
    var scale: CGFloat = 1

    var title: Font { Mono.font(13 * scale) }
    var titleBold: Font { Mono.font(13 * scale, bold: true) }
    var detail: Font { Mono.font(12 * scale) }
    var small: Font { Mono.font(11 * scale) }
    var icon: Font { .system(size: 12.5 * scale, weight: .semibold) }
    /// Width of the column the row icon sits in.
    var gutter: CGFloat { 18 * scale }

    static let panelWidth: CGFloat = 364
    static let cornerRadius: CGFloat = 12
    static let rowInset: CGFloat = 12
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme(dark: false)
}

private struct MetricsKey: EnvironmentKey {
    static let defaultValue = Metrics()
}

private struct MotionKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }

    var metrics: Metrics {
        get { self[MetricsKey.self] }
        set { self[MetricsKey.self] = newValue }
    }

    /// False when animations are switched off in Settings or by Reduce Motion.
    var motion: Bool {
        get { self[MotionKey.self] }
        set { self[MotionKey.self] = newValue }
    }
}

/// Picks the theme from the colour scheme and passes the sizes and motion setting down.
struct Themed<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    @EnvironmentObject private var settings: AppSettings
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .environment(\.theme, Theme(dark: scheme == .dark))
            .environment(\.metrics, Metrics(scale: settings.textSize.scale))
            .environment(\.motion, settings.motion)
            .transaction { transaction in
                if !settings.motion {
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }
            }
    }
}
