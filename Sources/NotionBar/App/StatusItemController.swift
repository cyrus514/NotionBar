import AppKit
import Combine
import SwiftUI

/// A hosting view that lets clicks fall through to the status bar button underneath.
private final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The menu bar item. The icon is a small SwiftUI view living inside the status bar button,
/// which is what lets it animate (rolling count, pop, pulse) and use colour.
@MainActor
final class StatusItemController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let iconModel = StatusIconModel()
    private let animator: StatusIconAnimator
    private var hosting: NSView?
    private var subscriptions = Set<AnyCancellable>()

    private let store: TaskStore
    private let settings: AppSettings
    private let focus: FocusTimer

    /// Left click.
    var onClick: () -> Void = {}
    /// Builds the right-click menu.
    var makeMenu: () -> NSMenu = { NSMenu() }

    var button: NSStatusBarButton? { statusItem.button }

    init(store: TaskStore, settings: AppSettings, focus: FocusTimer) {
        self.store = store
        self.settings = settings
        self.focus = focus
        self.animator = StatusIconAnimator(model: iconModel)
        super.init()
        animator.motion = settings.motion
        install()
        observe()
    }

    private func install() {
        statusItem.autosaveName = "NotionBar"
        statusItem.behavior = []
        guard let button = statusItem.button else { return }
        button.title = ""
        button.image = nil
        button.target = self
        button.action = #selector(clicked(_:))
        button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        button.setAccessibilityTitle("NotionBar")

        let hosting = PassthroughHostingView(rootView: StatusIconView(model: iconModel))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            hosting.centerYAnchor.constraint(equalTo: button.centerYAnchor),
        ])
        self.hosting = hosting
        updateLength()
    }

    private func observe() {
        // The icon's width follows its contents.
        iconModel.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateLength() }
            .store(in: &subscriptions)

        Publishers.CombineLatest4(store.$board, store.$failure, store.$now, settings.$showCountdown)
            .combineLatest(focus.$session, focus.$remaining)
            .map { [weak focus] core, session, _ -> IconTarget in
                StatusItemController.target(board: core.0, failure: core.1, now: core.2, countdown: core.3,
                                            focus: session == nil ? nil : focus?.label)
            }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] target in
                self?.animator.setTarget(target)
                self?.updateToolTip()
            }
            .store(in: &subscriptions)

        store.$isLoading.removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] loading in self?.animator.setLoading(loading) }
            .store(in: &subscriptions)

        store.events
            .sink { [weak self] event in
                guard let self else { return }
                switch event {
                case .markedDone:
                    self.animator.celebrate()
                case .refreshed:
                    // After each refresh, pulse if anything is overdue.
                    self.animator.setTarget(self.currentTarget(), pulse: true)
                case .markFailed:
                    break
                }
            }
            .store(in: &subscriptions)

        settings.$animations.combineLatest(settings.$reduceMotion)
            .map { $0 && !$1 }
            .removeDuplicates()
            .sink { [weak self] motion in self?.animator.motion = motion }
            .store(in: &subscriptions)
    }

    private func currentTarget() -> IconTarget {
        StatusItemController.target(board: store.board, failure: store.failure, now: store.now,
                                    countdown: settings.showCountdown,
                                    focus: focus.isRunning ? focus.label : nil)
    }

    private static func target(board: Board, failure: TaskStore.Failure?, now: Date,
                               countdown: Bool, focus: String?) -> IconTarget {
        var target = IconTarget(count: board.count, overdue: board.hasOverdue, error: failure != nil, focus: focus)
        if countdown, failure == nil, let next = board.nextDue {
            target.countdown = StatusItemController.short(next.timeIntervalSince(now))
        }
        return target
    }

    /// Hovering the icon says what the number means.
    private func updateToolTip() {
        let board = store.board
        var parts: [String] = []
        if let failure = store.failure {
            parts.append("couldn't load tasks: \(failure.hint ?? failure.message)")
        } else {
            if !board.overdue.isEmpty { parts.append("\(board.overdue.count) overdue") }
            if !board.dueToday.isEmpty { parts.append("\(board.dueToday.count) due today") }
            if parts.isEmpty { parts.append("nothing due today") }
            if let next = board.nextDue {
                parts.append("next: \(board.nextDueName) at \(Schedule.clock(next))")
            }
        }
        statusItem.button?.toolTip = parts.joined(separator: " · ")
    }

    /// `45m`, `1h20m`, `3d`
    static func short(_ interval: TimeInterval) -> String {
        let minutes = max(1, Int((interval / 60).rounded(.up)))
        if minutes < 60 { return "\(minutes)m" }
        if minutes < 24 * 60 {
            return minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h\(minutes % 60)m"
        }
        return "\(minutes / (24 * 60))d"
    }

    private func updateLength() {
        guard let hosting else { return }
        let width = ceil(hosting.fittingSize.width)
        if abs(statusItem.length - width) > 0.5 {
            statusItem.length = max(24, width)
        }
    }

    /// Shows the button as pressed while the panel is open.
    func setHighlighted(_ highlighted: Bool) {
        // After the click has been handled, or the button un-highlights itself on mouse up.
        DispatchQueue.main.async { [weak self] in
            self?.statusItem.button?.highlight(highlighted)
        }
    }

    /// What the icon shows this instant, for the debug driver's log.
    var debugState: String {
        let tint = iconModel.tint == Tint.red ? " red" : (iconModel.tint == Tint.green ? " green" : "")
        return "\(iconModel.symbol)\(tint) \"\(iconModel.text)\" scale=\(String(format: "%.2f", iconModel.scale)) width=\(Int(statusItem.length))"
    }

    /// For the focus timer finishing: the same pop as marking something done.
    func celebrate() {
        animator.celebrate()
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseDown
            || (event?.modifierFlags.contains(.control) ?? false)
        if isRightClick {
            showMenu()
        } else {
            onClick()
        }
    }

    private func showMenu() {
        // Attach the menu only for this click, so a left click still opens the panel.
        statusItem.menu = makeMenu()
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }
}
