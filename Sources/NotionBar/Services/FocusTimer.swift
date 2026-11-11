import AppKit
import SwiftUI

/// A countdown tied to one row: pick a step, work on it for 25 minutes, and the menu bar
/// counts down. When it ends the panel offers to mark the step done.
@MainActor
final class FocusTimer: ObservableObject {
    struct Session: Equatable {
        var item: Item
        var minutes: Int
        var end: Date
    }

    /// The countdown that's running, if any.
    @Published private(set) var session: Session?
    /// Seconds left in the running countdown.
    @Published private(set) var remaining: TimeInterval = 0
    /// The countdown that just ended, until it's marked done or dismissed.
    @Published private(set) var completed: Session?

    /// Called once when a countdown reaches zero.
    var onComplete: (Session) -> Void = { _ in }

    private var timer: Timer?

    var isRunning: Bool { session != nil }

    /// `24:59`
    var label: String {
        let seconds = max(0, Int(remaining.rounded(.up)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    func start(_ item: Item, minutes: Int) {
        stop()
        completed = nil
        let end = Date().addingTimeInterval(TimeInterval(minutes * 60))
        session = Session(item: item, minutes: minutes, end: end)
        remaining = end.timeIntervalSinceNow
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        session = nil
        remaining = 0
    }

    func dismissCompleted() {
        completed = nil
    }

    private func tick() {
        guard let session else { return }
        // Measured against the end time, so sleep or a busy main thread can't make it drift.
        remaining = session.end.timeIntervalSinceNow
        guard remaining <= 0 else { return }
        stop()
        completed = session
        onComplete(session)
    }
}
