import SwiftUI

/// What the menu bar icon is showing this instant.
@MainActor
final class StatusIconModel: ObservableObject {
    @Published var symbol = "hourglass"
    /// nil = the normal menu bar colour.
    @Published var tint: Color?
    /// The count (and countdown) next to the icon. Empty = icon only.
    @Published var text = ""
    /// The number in `text`, so digits can roll in the right direction.
    @Published var value = 0
    @Published var scale: CGFloat = 1
    @Published var motion = true
}

/// The menu bar icon: an SF Symbol and, usually, a number in Menlo.
struct StatusIconView: View {
    @ObservedObject var model: StatusIconModel

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: model.symbol)
                .font(.system(size: 14.5, weight: .medium))
                .foregroundStyle(model.tint ?? Color.primary)
                .contentTransition(model.motion ? .symbolEffect(.replace) : .identity)
                .scaleEffect(model.scale)
                .frame(minWidth: 18)
            if !model.text.isEmpty {
                Text(model.text)
                    .font(Mono.font(12.5))
                    .foregroundStyle(Color.primary)
                    .contentTransition(model.motion ? .numericText(value: Double(model.value)) : .identity)
            }
        }
        .padding(.horizontal, 5)
        .frame(height: 22)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Notion tasks: \(model.text.isEmpty ? "nothing due" : model.text + " due")")
    }
}

/// What the icon should end up showing once any animation has played out.
struct IconTarget: Equatable {
    var count = 0
    var overdue = false
    var error = false
    /// `45m`: time until the next timed item, when that setting is on.
    var countdown: String?
    /// `24:59`: the focus countdown, which takes over the icon while it runs.
    var focus: String?

    var symbol: String {
        if focus != nil { return "timer" }
        if error { return "exclamationmark.triangle" }
        if overdue { return "exclamationmark.circle" }
        return count > 0 ? "checklist" : "checkmark.circle"
    }

    func text(count shown: Int) -> String {
        if let focus { return focus }
        if error { return "" }
        var parts: [String] = []
        if shown > 0 { parts.append(String(shown)) }
        if let countdown { parts.append(countdown) }
        return parts.joined(separator: " · ")
    }
}

/// Plays the menu bar animations, one after another, and always lands on the latest target:
///
/// - marked done: a green check pops in, holds, then the count rolls down
/// - count change: the number rolls from the old value to the new one
/// - loading: the hourglass turns over while a fetch is running
/// - overdue: three red pulses after a refresh, then still
@MainActor
final class StatusIconAnimator {
    let model: StatusIconModel
    private var target = IconTarget()
    private var shownCount: Int?
    private var isLoading = false
    private var wantsPulse = false
    private var wantsCelebration = false
    private var hourglassFrame = 0
    private var runner: Task<Void, Never>?

    private static let hourglass = ["hourglass.bottomhalf.filled", "hourglass", "hourglass.tophalf.filled"]

    init(model: StatusIconModel) {
        self.model = model
    }

    /// Animations on or off (the Settings toggle and Reduce Motion both land here).
    var motion: Bool {
        get { model.motion }
        set {
            model.motion = newValue
            if !newValue { settleNow() }
        }
    }

    func setTarget(_ next: IconTarget, pulse: Bool = false) {
        target = next
        if pulse { wantsPulse = true }
        kick()
    }

    func setLoading(_ loading: Bool) {
        isLoading = loading
        kick()
    }

    /// Something was just marked done.
    func celebrate() {
        wantsCelebration = true
        kick()
    }

    private func kick() {
        guard motion else { return settleNow() }
        guard runner == nil else { return }
        runner = Task { [weak self] in
            await self?.run()
            self?.runner = nil
        }
    }

    /// Jumps straight to the target with no animation.
    private func settleNow() {
        runner?.cancel()
        runner = nil
        wantsPulse = false
        wantsCelebration = false
        shownCount = target.count
        show(symbol: target.symbol, tint: nil, count: target.count, animated: false)
    }

    /// Does one small piece of animation per pass, then looks again at what's wanted.
    /// That way a new target, a fetch starting or a second mark-done can arrive mid-animation.
    private func run() async {
        while !Task.isCancelled {
            let countable = !target.error && target.focus == nil

            if wantsCelebration {
                wantsCelebration = false
                await pop()
            } else if countable, let shown = shownCount, shown != target.count {
                await rollOneStep(from: shown)
            } else if isLoading && target.focus == nil {
                await turnHourglass()
            } else if wantsPulse {
                wantsPulse = false
                if target.overdue && countable { await pulse() }
            } else {
                shownCount = target.count
                show(symbol: target.symbol, tint: nil, count: target.count, animated: true)
                return
            }
        }
    }

    private func show(symbol: String, tint: Color?, count: Int, animated: Bool) {
        let apply = {
            self.model.symbol = symbol
            self.model.tint = tint
            self.model.value = count
            self.model.text = self.target.text(count: count)
            self.model.scale = 1
        }
        if animated && motion {
            withAnimation(.snappy(duration: 0.2), apply)
        } else {
            apply()
        }
    }

    private func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// `hourglass.bottomhalf.filled` → `hourglass` → `hourglass.tophalf.filled`, about 0.35 s each.
    private func turnHourglass() async {
        let symbol = StatusIconAnimator.hourglass[hourglassFrame % StatusIconAnimator.hourglass.count]
        hourglassFrame += 1
        show(symbol: symbol, tint: nil, count: shownCount ?? 0, animated: true)
        await pause(0.35)
    }

    /// Rolls the number one step toward the target: about 90 ms a step, at most 10 steps.
    private func rollOneStep(from shown: Int) async {
        let direction = target.count > shown ? 1 : -1
        var next = shown + direction
        if abs(target.count - next) >= 10 {
            next = target.count - direction * 9
        }
        shownCount = next
        // Keep the icon that goes with the number on screen while it rolls.
        let symbol = target.overdue ? "exclamationmark.circle" : (next > 0 ? "checklist" : "checkmark.circle")
        withAnimation(.snappy(duration: 0.09)) {
            model.symbol = symbol
            model.tint = nil
            model.value = next
            model.text = target.text(count: next)
        }
        await pause(0.09)
    }

    /// Filled red, then outline, three times at about 0.45 s. Then it stays still.
    private func pulse() async {
        for _ in 0..<3 {
            guard !Task.isCancelled, target.overdue, !wantsCelebration else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                model.symbol = "exclamationmark.circle.fill"
                model.tint = Tint.red
            }
            await pause(0.45)
            withAnimation(.easeInOut(duration: 0.2)) {
                model.symbol = "exclamationmark.circle"
                model.tint = nil
            }
            await pause(0.45)
        }
    }

    /// A green check pops in (scale 0.4 → 1.25 → 1) and holds for about 1.2 s.
    private func pop() async {
        var instantly = Transaction()
        instantly.disablesAnimations = true
        withTransaction(instantly) {
            model.symbol = "checkmark.circle.fill"
            model.tint = Tint.green
            model.scale = 0.4
        }
        await pause(0.02)
        withAnimation(.easeOut(duration: 0.16)) { model.scale = 1.25 }
        await pause(0.16)
        withAnimation(.spring(response: 0.22, dampingFraction: 0.55)) { model.scale = 1 }
        await pause(1.2)
    }
}
