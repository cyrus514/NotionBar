import AppKit
import SwiftUI

/// The frosted backing of the panel. A real `NSVisualEffectView`, so it blurs what's behind the window.
struct VisualEffect: NSViewRepresentable {
    var cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        view.maskImage = VisualEffect.mask(cornerRadius)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}

    /// A stretchable rounded rectangle: the only way to round a behind-window blur.
    private static func mask(_ radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// A one-pixel rule.
struct Hairline: View {
    @Environment(\.theme) private var theme
    var inset: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(theme.separator)
            .frame(height: 1)
            .padding(.horizontal, inset)
    }
}

/// `// overdue (3)`
struct SectionHeader: View {
    @Environment(\.theme) private var theme
    @Environment(\.metrics) private var metrics
    var text: String
    var count: Int?

    var body: some View {
        HStack(spacing: 0) {
            Text("// " + text)
            if let count {
                Text(" (")
                Text("\(count)").contentTransition(.numericText(value: Double(count)))
                Text(")")
            }
            Spacer(minLength: 0)
        }
        .font(metrics.detail)
        .foregroundStyle(theme.comment)
        .padding(.horizontal, Metrics.rowInset)
        .padding(.top, 7)
        .padding(.bottom, 3)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A plain line of text in a section, such as `✓ nothing due today`.
struct NoteLine: View {
    @Environment(\.metrics) private var metrics
    var text: String
    var color: Color
    var small = false

    var body: some View {
        Text(text)
            .font(small ? metrics.detail : metrics.title)
            .foregroundStyle(color)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Metrics.rowInset)
            .padding(.vertical, 5)
    }
}

/// A footer or inline action written like a shell command: `$ refresh`.
struct CommandButton: View {
    @Environment(\.theme) private var theme
    @Environment(\.metrics) private var metrics
    var name: String
    var tint: Color?
    var help: String = ""
    var action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                Text("$ ").foregroundStyle(hovering ? (tint ?? theme.accent) : theme.faint)
                Text(name).foregroundStyle(hovering ? (tint ?? theme.accent) : theme.text)
            }
            .font(metrics.detail)
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(name)
        .clickTarget("cmd|" + name)
    }
}

/// A small icon button in the header.
struct IconButton: View {
    @Environment(\.theme) private var theme
    var symbol: String
    var help: String
    var spinning = false
    /// Drawn in the accent colour: the thing it switches is on.
    var active = false
    var action: () -> Void
    @ViewState private var hovering = false
    @ViewState private var turns = 0.0
    @Environment(\.motion) private var motion

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(active ? theme.accent : (hovering ? theme.text : theme.detail))
                .contentTransition(.symbolEffect(.replace))
                .rotationEffect(.degrees(turns * 360))
                .frame(width: 22, height: 20)
                .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? theme.hover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
        .clickTarget("icon|" + symbol)
        .onChange(of: spinning) { _, isSpinning in
            guard motion, isSpinning else { return }
            withAnimation(.easeInOut(duration: 0.7)) { turns += 1 }
        }
    }
}

/// A row of little blocks: `■■■□□`. Shows how much of something is done.
struct SegmentBar: View {
    @Environment(\.theme) private var theme
    var done: Int
    var total: Int
    var maxSegments = 10
    var height: CGFloat = 8

    var body: some View {
        // More items than blocks: each block stands for a share of them.
        let segments = max(1, min(total, maxSegments))
        let filled = total == 0 ? 0 : Int((Double(done) / Double(total) * Double(segments)).rounded(.down))
        let shown = done > 0 ? max(filled, 1) : 0
        HStack(spacing: 2) {
            ForEach(0..<segments, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(index < shown ? theme.success : theme.faint.opacity(0.35))
                    .frame(width: 5, height: height)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The highlight behind a row: a soft fill, plus an accent bar when the keyboard is on it.
struct RowHighlight: View {
    @Environment(\.theme) private var theme
    var hovering: Bool
    var selected: Bool
    var tint: Color?

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(selected ? theme.selection : (hovering ? (tint?.opacity(0.14) ?? theme.hover) : .clear))
            if selected {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(theme.accent)
                    .frame(width: 3)
                    .padding(.vertical, 4)
            }
        }
        .padding(.horizontal, 5)
    }
}

/// Fades and lifts a row in when the panel opens, a beat after the row above it.
struct Reveal: ViewModifier {
    @EnvironmentObject private var model: PanelModel
    @Environment(\.motion) private var motion
    var order: Int
    @ViewState private var shown = true

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 5)
            .onChange(of: model.presentCount) { _, _ in
                guard motion else { return }
                shown = false
                let delay = min(0.26, Double(order) * 0.022)
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 0.24).delay(delay)) { shown = true }
                }
            }
    }
}

extension View {
    func reveal(_ order: Int) -> some View {
        modifier(Reveal(order: order))
    }
}

/// Reports the height of the list so the panel can hug it.
struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

extension View {
    /// Calls `report` with this view's height, now and whenever it changes.
    func readHeight(_ report: @escaping (CGFloat) -> Void) -> some View {
        background(GeometryReader { geometry in
            Color.clear.onChange(of: geometry.size.height, initial: true) { _, height in
                report(height)
            }
        })
    }
}

/// Where the clickable things in the panel are, by name. Only filled in while the debug driver
/// is running (`--debug`), which uses it to aim real mouse clicks at rows and buttons.
@MainActor
enum ClickTargets {
    static var enabled = false
    /// In the hosting view's coordinates (origin at its top-left).
    static var frames: [String: CGRect] = [:]
}

extension View {
    /// Names this view for the debug driver. Does nothing in normal use.
    @ViewBuilder
    func clickTarget(_ name: String) -> some View {
        if ClickTargets.enabled {
            background(GeometryReader { geometry in
                Color.clear
                    .onChange(of: geometry.frame(in: .global), initial: true) { _, frame in
                        ClickTargets.frames[name] = frame
                    }
                    .onDisappear { ClickTargets.frames[name] = nil }
                    // A new name (a button whose icon changed) registers afresh.
                    .id(name)
            })
        } else {
            self
        }
    }
}

/// The rule under the header. While a fetch is running, a highlight runs along it.
struct SyncLine: View {
    @Environment(\.theme) private var theme
    @Environment(\.motion) private var motion
    var active: Bool
    @ViewState private var travelling = false

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Rectangle().fill(theme.separator)
                if active && motion {
                    Rectangle()
                        .fill(LinearGradient(colors: [theme.accent.opacity(0), theme.accent, theme.accent.opacity(0)],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: geometry.size.width * 0.4)
                        .offset(x: travelling ? geometry.size.width : -geometry.size.width * 0.4)
                        .onAppear {
                            travelling = false
                            withAnimation(.linear(duration: 0.85).repeatForever(autoreverses: false)) { travelling = true }
                        }
                        .transition(.opacity)
                }
            }
        }
        .frame(height: 1)
        .clipped()
    }
}

/// Today and the next six days, with how much is due on each. Click a day to see only that day.
struct WeekStrip: View {
    @EnvironmentObject private var store: TaskStore
    @EnvironmentObject private var model: PanelModel
    @Environment(\.theme) private var theme
    @Environment(\.metrics) private var metrics

    var body: some View {
        HStack(spacing: 3) {
            ForEach(store.board.week) { load in
                DayCell(load: load, isToday: load.day == store.board.today, selected: model.dayFilter == load.day)
            }
        }
    }

    private struct DayCell: View {
        @EnvironmentObject private var model: PanelModel
        @Environment(\.theme) private var theme
        @Environment(\.metrics) private var metrics
        var load: Board.DayLoad
        var isToday: Bool
        var selected: Bool
        @ViewState private var hovering = false

        var body: some View {
            Button {
                model.toggleDay(load.day)
            } label: {
                VStack(spacing: 1) {
                    Text(Schedule.shortWeekday(load.day))
                        .font(metrics.small)
                        .foregroundStyle(isToday ? theme.success : theme.faint)
                    Text(load.count == 0 ? "·" : "\(load.count)")
                        .font(Mono.font(12 * metrics.scale, bold: load.count > 0))
                        .foregroundStyle(load.count == 0 ? theme.faint : theme.text)
                        .contentTransition(.numericText(value: Double(load.count)))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5)
                    .fill(selected ? theme.selection : (hovering ? theme.hover : .clear)))
                .overlay(alignment: .bottom) {
                    if isToday {
                        Capsule().fill(theme.success.opacity(0.7)).frame(width: 14, height: 1.5)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(load.count == 0 ? "nothing due" : "\(load.count) due · click to show only this day")
            .accessibilityLabel("\(Schedule.shortWeekday(load.day)), \(load.count) due")
            .clickTarget("day|" + load.day.iso)
        }
    }
}

/// A burst of code-flavoured confetti (`✓ + * { }`) for when the last thing due gets ticked off.
struct ConfettiView: View {
    @Environment(\.theme) private var theme
    @Environment(\.motion) private var motion
    /// Plays once each time this changes.
    var trigger: Int
    @ViewState private var started: Date?

    private static let glyphs = ["✓", "+", "*", "·", "{", "}", "/", "✓", "+"]
    private static let duration = 1.6

    var body: some View {
        TimelineView(.animation(paused: started == nil)) { timeline in
            Canvas { context, size in
                guard let started else { return }
                let t = timeline.date.timeIntervalSince(started)
                guard t < ConfettiView.duration else { return }
                let colors = [theme.success, theme.accent, Tint.yellow, Tint.purple, theme.success]
                for index in 0..<34 {
                    // Each piece gets its own launch angle, speed and spin, fixed by its index.
                    let seed = Double(index)
                    let angle = -Double.pi / 2 + (fract(seed * 0.618) - 0.5) * 2.4
                    let speed = 150 + fract(seed * 0.377) * 190
                    let x = size.width / 2 + cos(angle) * speed * t
                    let y = 46 + sin(angle) * speed * t + 330 * t * t
                    let fade = max(0, 1 - t / ConfettiView.duration)
                    var piece = context
                    piece.opacity = fade
                    piece.translateBy(x: x, y: y)
                    piece.rotate(by: .radians(t * (fract(seed * 0.21) - 0.5) * 7))
                    piece.draw(Text(ConfettiView.glyphs[index % ConfettiView.glyphs.count])
                        .font(Mono.font(11 + fract(seed * 0.47) * 6, bold: true))
                        .foregroundStyle(colors[index % colors.count]), at: .zero)
                }
            }
        }
        .allowsHitTesting(false)
        .onChange(of: trigger) { _, _ in
            guard motion else { return }
            started = Date()
            DispatchQueue.main.asyncAfter(deadline: .now() + ConfettiView.duration + 0.1) {
                started = nil
            }
        }
    }

    private func fract(_ value: Double) -> Double {
        value - value.rounded(.down)
    }
}
