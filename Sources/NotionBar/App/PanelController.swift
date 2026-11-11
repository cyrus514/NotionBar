import AppKit
import Combine
import SwiftUI

/// The panel's window: borderless, see-through, floats above everything, and can take
/// keyboard focus without bringing the app to the front.
final class FloatingPanel: NSPanel {
    /// Where the card is, in window coordinates. Clicks outside it close the panel.
    var cardRect: () -> NSRect = { .zero }
    var onOutsideClick: () -> Void = {}
    /// Clicks that landed in the see-through margin. Read by the UI test.
    private(set) var outsideClicks = 0

    /// False only while the debug driver tests off screen, so the test can't take your keyboard.
    var allowsKey = true

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type),
           !cardRect().contains(event.locationInWindow) {
            outsideClicks += 1
            onOutsideClick()
            return
        }
        super.sendEvent(event)
    }
}

/// Opens and closes the panel under the menu bar icon.
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    let model: PanelModel
    private let store: TaskStore
    private let settings: AppSettings
    let panel: FloatingPanel
    private var monitors: [Any] = []
    private var subscriptions = Set<AnyCancellable>()
    /// Goes up on every open and close, so a late fade-out can tell it has been overtaken.
    private var generation = 0

    /// Debug driver only: keep the panel off screen, never focused, and open until told to close,
    /// so a scripted test neither shows up on the display nor gets closed by what you're doing.
    var stealth = false {
        didSet { panel.allowsKey = !stealth }
    }

    /// How many times something has asked the panel to close. Read by the UI test.
    private(set) var closeRequests = 0
    /// Automatic closes that a pinned panel shrugged off. Read by the UI test.
    private(set) var pinIgnoredCloses = 0

    private(set) var isOpen = false
    /// Tells the status item to look pressed (or not).
    var onVisibilityChange: (Bool) -> Void = { _ in }

    init(model: PanelModel, store: TaskStore, settings: AppSettings, focus: FocusTimer) {
        self.model = model
        self.store = store
        self.settings = settings

        let size = NSSize(width: Metrics.panelWidth + PanelRoot.margin * 2, height: 600 + PanelRoot.margin * 2)
        panel = FloatingPanel(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: true)
        super.init()

        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        // The card draws its own shadow, so it can follow the card as it grows and shrinks.
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.delegate = self
        panel.appearance = settings.nsAppearance

        let root = PanelRoot()
            .environmentObject(store)
            .environmentObject(model)
            .environmentObject(settings)
            .environmentObject(focus)
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        panel.contentView = hosting

        panel.cardRect = { [weak self] in self?.cardRect() ?? .zero }
        panel.onOutsideClick = { [weak self] in self?.close(automatic: true) }

        // Pinned: sit just above ordinary windows instead of above everything, so menus still cover it.
        model.$isPinned
            .receive(on: DispatchQueue.main)
            .sink { [weak self] pinned in
                self?.panel.level = pinned ? .floating : .popUpMenu
            }
            .store(in: &subscriptions)

        settings.$appearance
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.panel.appearance = self?.settings.nsAppearance }
            .store(in: &subscriptions)

        // Put the panel away when the screen locks or sleeps, or you switch to another app or Space.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification,
                     NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            workspace.publisher(for: name)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.close(automatic: true) }
                .store(in: &subscriptions)
        }
    }

    private func cardRect() -> NSRect {
        let frame = panel.frame
        let height = model.cardHeight > 0 ? model.cardHeight : frame.height - PanelRoot.margin * 2
        return NSRect(x: PanelRoot.margin, y: frame.height - PanelRoot.margin - height,
                      width: Metrics.panelWidth, height: height)
    }

    func toggle(under button: NSStatusBarButton?) {
        if isOpen {
            close()
        } else {
            open(under: button)
        }
    }

    func open(under button: NSStatusBarButton?) {
        trace("open isOpen=\(isOpen)")
        guard !isOpen else { return }
        isOpen = true
        generation += 1
        let token = generation
        position(under: button)

        model.willPresent()
        panel.alphaValue = settings.motion ? 0 : 1
        panel.orderFrontRegardless()
        if !stealth { panel.makeKey() }
        if settings.motion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                panel.animator().alphaValue = 1
            }
            // Don't count on the animation finishing (it won't while the display is asleep).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self, self.generation == token, self.isOpen else { return }
                self.panel.alphaValue = 1
            }
        }
        onVisibilityChange(true)
        installMonitors()

        // Fresh data when the panel opens, unless it was fetched in the last 30 seconds.
        store.tick()
        store.refreshIfStale(olderThan: 30)
    }

    /// `automatic` closes are the ones you didn't ask for (a click elsewhere, switching apps):
    /// a pinned panel ignores those. `force` is for the debug driver, whose off-screen panel
    /// ignores every other reason to close.
    func close(force: Bool = false, automatic: Bool = false) {
        trace("close isOpen=\(isOpen) automatic=\(automatic)")
        closeRequests += 1
        guard isOpen else { return }
        if automatic, model.isPinned, !force {
            pinIgnoredCloses += 1
            return
        }
        guard force || !stealth else { return }
        isOpen = false
        generation += 1
        let token = generation
        removeMonitors()
        model.willDismiss()
        onVisibilityChange(false)

        guard settings.motion else { return finishClosing(token) }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.11
            panel.animator().alphaValue = 0
        }
        // A timer, not the animation's completion handler: that never fires if the display is asleep.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.13) { [weak self] in
            self?.finishClosing(token)
        }
    }

    private func finishClosing(_ token: Int) {
        // Opened again before the fade finished: leave it on screen.
        guard generation == token else { return }
        trace("close finished")
        panel.orderOut(nil)
        panel.alphaValue = 1
        model.didDismiss()
    }

    /// Puts the card just under the menu bar icon, centred on it, kept on screen.
    private func position(under button: NSStatusBarButton?) {
        let margin = PanelRoot.margin
        let screen = button?.window?.screen ?? NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)

        var anchor = NSRect(x: visible.maxX - 60, y: visible.maxY, width: 30, height: 24)
        if let button, let window = button.window {
            anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        }

        // Height fits the content, up to about 600 pt (less on a short screen). Then it scrolls.
        // (The off-screen test panel is made tall instead, so every row can be clicked without scrolling.)
        let maxCard = stealth ? 2400 : max(240, min(600, visible.height - 16))
        model.maxHeight = maxCard

        let cardTop = min(anchor.minY - 4, visible.maxY - 4)
        var cardX = anchor.midX - Metrics.panelWidth / 2
        cardX = min(max(cardX, visible.minX + 8), visible.maxX - Metrics.panelWidth - 8)
        let frame = NSRect(x: cardX - margin, y: cardTop - maxCard - margin,
                           width: Metrics.panelWidth + margin * 2, height: maxCard + margin * 2)
        panel.setFrame(stealth ? frame.offsetBy(dx: -30_000, dy: -30_000) : frame, display: true)
    }

    // MARK: Events

    private func installMonitors() {
        removeMonitors()
        // A click in any other app closes the panel.
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] _ in
            DispatchQueue.main.async { self?.close(automatic: true) }
        }) { monitors.append(monitor) }

        // Arrow keys, Return, Esc and ⌘ shortcuts, before the text field sees them.
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            let used = MainActor.assumeIsolated { () -> Bool in
                guard let self, event.window === self.panel else { return false }
                return self.model.handleKey(event)
            }
            return used ? nil : event
        }) { monitors.append(monitor) }

        // ⌥ turns rows into "[x] name".
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            let held = event.modifierFlags.contains(.option)
            MainActor.assumeIsolated { self?.setOption(held) }
            return event
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            let held = event.modifierFlags.contains(.option)
            DispatchQueue.main.async { self?.setOption(held) }
        }) { monitors.append(monitor) }

        setOption(NSEvent.modifierFlags.contains(.option))
    }

    private func setOption(_ held: Bool) {
        guard model.optionHeld != held else { return }
        animate(settings.motion, .snappy(duration: 0.18)) { model.optionHeld = held }
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }

    func windowDidResignKey(_ notification: Notification) {
        trace("resigned key")
        // Another window took the keyboard (Settings, or another app).
        close(automatic: true)
    }
}

/// Prints to stderr when `NOTIONBAR_TRACE=1` is set. For chasing window-ordering problems.
func trace(_ message: @autoclosure () -> String) {
    guard ProcessInfo.processInfo.environment["NOTIONBAR_TRACE"] == "1" else { return }
    FileHandle.standardError.write(Data(("trace: " + message() + "\n").utf8))
}
