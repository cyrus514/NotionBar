import AppKit

/// `NotionBar --demo --debug "open;wait:1;shot:a;done:first;wait:3;shot:b;quit" --debug-dir /tmp/x`
///
/// Drives the real, running app through a list of steps and saves what its windows are drawing.
/// It exists so the live app (not just an offscreen render) can be checked from the command line,
/// without screen-recording permission.
///
/// Steps, separated by `;`:
///   open · close · settings · quit · refresh · undo
///   wait:<seconds>
///   shot:<name>          save <name>-panel.png and <name>-icon.png, and log the window geometry
///   done:<n>             mark the n-th row on screen done (1 = first)
///   query:<text>         type into the prompt
///   option:on|off        hold / release ⌥
///   key:<keycode>[+cmd]  press a key in the panel (125 ↓, 126 ↑, 36 return, 53 esc)
///   tasks:on|off         fold tasks/ open or shut
///   fail:offline|<status>|off  make the fake Notion fail (demo mode only)
///   focus:<n>            start a focus countdown on the n-th row
///   watch:<seconds>      log every change of the menu bar icon
///   hotkey               try registering every global shortcut, then turn it off
///   click:<text>         real mouse click on the first click target whose name contains the text
///   clickat:<x>,<y>      real mouse click at a point in the card (from its top-left)
///   labels               list everything clickable, with frames
///   nolinks              record links instead of opening them
///   stealth              keep the panel off screen and unfocused for the rest of the run
///   expect:<name><op><v> check the app's state: `count=4`, `toast~done`, `card>580` (see `value`)
///   say:<text>           write a heading into the log
///   autoclose            ask the panel to close the way a click in another app would
///   latency:<seconds>    how long the fake Notion takes to answer (demo mode only)
@MainActor
final class DebugDriver {
    private unowned let app: AppDelegate
    private let folder: URL
    private var log: [String] = []
    private var passed = 0
    private var failed = 0
    private var lastOpened = "nothing"
    private var settingsRequests = 0

    init(app: AppDelegate, folder: String?) {
        self.app = app
        self.folder = URL(fileURLWithPath: folder ?? NSTemporaryDirectory())
        try? FileManager.default.createDirectory(at: self.folder, withIntermediateDirectories: true)
    }

    func run(_ script: String) {
        let steps = script.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        Task { @MainActor in
            for step in steps {
                await perform(step)
            }
            flush()
        }
    }

    private func note(_ text: String) {
        log.append(text)
        flush()
    }

    private func flush() {
        try? log.joined(separator: "\n").appending("\n")
            .write(to: folder.appendingPathComponent("debug.log"), atomically: true, encoding: .utf8)
    }

    private func rows() -> [Item] {
        let board = app.panelModel.visibleBoard
        return (board.overdue + board.dueToday + board.upcoming).map(\.item)
    }

    private func perform(_ step: String) async {
        let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
        let name = parts.first ?? ""
        let argument = parts.count > 1 ? parts[1] : ""
        switch name {
        case "open":
            app.panel.open(under: app.statusItem.button)
        case "close":
            app.panel.close(force: true)
        case "autoclose":
            // What a click in another app does: an automatic request to close.
            app.panel.close(automatic: true)
        case "stealth":
            // Test off screen and without taking the keyboard, so a run doesn't disturb whoever is at the Mac.
            app.panel.stealth = true
        case "settings":
            app.showSettings()
        case "refresh":
            await app.store.refresh()
        case "undo":
            app.store.undoLast()
        case "quit":
            if passed + failed > 0 {
                note("\(passed) passed, \(failed) failed")
                print("\(passed) passed, \(failed) failed")
            }
            flush()
            exit(failed == 0 ? 0 : 1)
        case "wait":
            try? await Task.sleep(nanoseconds: UInt64((Double(argument) ?? 1) * 1_000_000_000))
        case "done":
            let list = rows()
            let index = (Int(argument) ?? 1) - 1
            if list.indices.contains(index) {
                note("done → \(list[index].name)")
                app.store.markDone(list[index])
            }
        case "focus":
            let list = rows()
            let index = (Int(argument) ?? 1) - 1
            if list.indices.contains(index) { app.focus.start(list[index], minutes: app.settings.focusMinutes) }
        case "query":
            app.panelModel.query = argument
        case "option":
            app.panelModel.optionHeld = argument == "on"
        case "tasks":
            app.settings.tasksExpanded = argument == "on"
        case "key":
            let pieces = argument.split(separator: "+")
            let code = UInt16(pieces.first ?? "") ?? 0
            let flags: NSEvent.ModifierFlags = pieces.contains("cmd") ? .command : []
            if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                            windowNumber: app.panel.panel.windowNumber, context: nil,
                                            characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code) {
                let used = app.panelModel.handleKey(event)
                note("key \(argument) used=\(used) selection=\(app.panelModel.selection ?? "nil")")
            }
        case "fail":
            switch argument {
            case "offline": await app.fake?.fail(with: .offline)
            case "401": await app.fake?.fail(with: .http(401, "API token is invalid."))
            case "404": await app.fake?.fail(with: .http(404, "Could not find database with ID: x."))
            case "off": await app.fake?.fail(with: nil)
            default:
                if let status = Int(argument) {
                    await app.fake?.fail(with: .http(status, "Something went wrong on Notion's side."))
                } else {
                    note("FAIL  unknown failure: \(argument)")
                    failed += 1
                }
            }
        case "watch":
            // Log every change of the menu bar icon for a while, with timestamps.
            let start = Date()
            var last = ""
            while Date().timeIntervalSince(start) < (Double(argument) ?? 3) {
                let state = app.statusItem.debugState
                if state != last {
                    note(String(format: "  icon +%.2fs  %@", Date().timeIntervalSince(start), state))
                    last = state
                }
                try? await Task.sleep(nanoseconds: 30_000_000)
            }
        case "click", "rightclick":
            // A real mouse click, sent through the window like one from the trackpad, on the
            // first thing in the panel whose accessibility label contains the text.
            await click(argument, right: name == "rightclick")
        case "clickat":
            // clickat:<x>,<y> in card coordinates (0,0 = top-left of the card).
            let numbers = argument.split(separator: ",").compactMap { Double($0) }
            if numbers.count == 2 {
                let frame = app.panel.panel.frame
                let point = NSPoint(x: PanelRoot.margin + numbers[0], y: frame.height - PanelRoot.margin - numbers[1])
                await press(at: point, right: false)
                note("clickat \(argument) → window \(point)")
            }
        case "labels":
            // List the click targets on screen right now.
            for name in ClickTargets.frames.keys.sorted() {
                let frame = ClickTargets.frames[name] ?? .zero
                note(String(format: "  target  %@  (%.0f, %.0f, %.0f×%.0f)", name, frame.minX, frame.minY, frame.width, frame.height))
            }
        case "nolinks":
            // Record links and Settings requests instead of acting on them, so click tests
            // don't launch Notion or put a window on screen.
            app.panelModel.openURL = { [weak self] url in
                self?.lastOpened = url.absoluteString
                self?.note("would open \(url.absoluteString)")
            }
            app.panelModel.openSettings = { [weak self] in
                self?.settingsRequests += 1
                self?.note("would open settings")
            }
        case "latency":
            await app.fake?.setLatency(Double(argument) ?? 0)
        case "expect":
            expect(argument)
        case "say":
            note("— \(argument)")
        case "hotkey":
            // Register each shortcut in turn, then switch it off again.
            for choice in HotKeyChoice.allCases where choice != .off {
                note("hotkey \(choice.label) registered=\(app.hotKey.set(choice))")
            }
            note("hotkey off=\(app.hotKey.set(.off))")
        case "shot":
            shot(argument.isEmpty ? "shot" : argument)
        default:
            note("unknown step: \(step)")
        }
    }

    // MARK: Checking

    /// The app's state by name, as text, for `expect:`.
    private func value(_ name: String) -> String? {
        let board = app.store.board
        let model: PanelModel = app.panelModel
        switch name {
        case "count": return "\(board.count)"
        case "overdue": return "\(board.overdue.count)"
        case "today": return "\(board.dueToday.count)"
        case "upcoming": return "\(board.upcoming.count)"
        case "tasks": return "\(board.tasks.count)"
        case "finished": return "\(app.store.finished.count)"
        case "rows": return "\(model.navigationOrder.count)"
        case "tasksOpen": return "\(model.tasksOpen)"
        case "doneOpen": return "\(model.doneOpen)"
        case "expanded": return "\(model.expandedTasks.count)"
        case "card": return "\(Int(model.cardHeight))"
        case "toast": return app.store.toast?.text ?? "nil"
        case "failure": return app.store.failure.map { "\($0)" } ?? "nil"
        case "offline": return "\(app.store.isOffline)"
        case "loading": return "\(app.store.isLoading)"
        case "opened": return lastOpened
        case "settingsRequests": return "\(settingsRequests)"
        case "closeRequests": return "\(app.panel.closeRequests)"
        case "outsideClicks": return "\(app.panel.panel.outsideClicks)"
        case "pinIgnored": return "\(app.panel.pinIgnoredCloses)"
        case "pinned": return "\(model.isPinned)"
        case "dayFilter": return model.dayFilter?.iso ?? "nil"
        case "addingStep": return "\(model.addStepParent != nil)"
        case "steps": return "\(app.store.steps.count)"
        case "celebration": return "\(model.celebration)"
        case "query": return model.query
        case "selection": return model.selection ?? "nil"
        case "option": return "\(model.optionHeld)"
        case "focus": return "\(app.focus.isRunning)"
        case "focusDone": return "\(app.focus.completed != nil)"
        case "settings": return "\(app.isSettingsVisible)"
        case "panel": return app.panel.isOpen ? "open" : "closed"
        case "icon": return app.statusItem.debugState
        default: return nil
        }
    }

    /// `expect:count=4` · `expect:toast~done` (contains) · `expect:card>580` · `expect:card<600`
    private func expect(_ text: String) {
        guard let index = text.firstIndex(where: { "=~<>".contains($0) }) else {
            failed += 1
            return note("FAIL  bad expectation: \(text)")
        }
        let name = String(text[..<index])
        let wanted = String(text[text.index(after: index)...])
        guard let actual = value(name) else {
            failed += 1
            return note("FAIL  unknown value: \(name)")
        }
        let ok: Bool
        switch text[index] {
        case "=": ok = actual == wanted
        case "~": ok = actual.localizedCaseInsensitiveContains(wanted)
        case ">": ok = (Double(actual) ?? -.infinity) > (Double(wanted) ?? .infinity)
        default: ok = (Double(actual) ?? .infinity) < (Double(wanted) ?? -.infinity)
        }
        if ok {
            passed += 1
            note("ok    \(text)")
        } else {
            failed += 1
            note("FAIL  \(text)   (is: \(actual))")
        }
    }

    // MARK: Clicking

    /// The centre of a named click target (see `ClickTargets`), in window coordinates.
    private func target(_ text: String) -> (name: String, point: NSPoint)? {
        let height = app.panel.panel.contentView?.bounds.height ?? 0
        let names = ClickTargets.frames.keys.sorted()
        guard let name = names.first(where: { $0 == text }) ?? names.first(where: { $0.localizedCaseInsensitiveContains(text) }),
              let frame = ClickTargets.frames[name] else { return nil }
        return (name, NSPoint(x: frame.midX, y: height - frame.midY))
    }

    private func click(_ text: String, right: Bool) async {
        guard let target = target(text) else {
            note("click \(text): NOT FOUND")
            return
        }
        note("click \(text) → \(target.name) at \(Int(target.point.x)),\(Int(target.point.y))")
        await press(at: target.point, right: right)
    }

    private func press(at point: NSPoint, right: Bool) async {
        let panel = app.panel.panel
        func send(_ type: NSEvent.EventType) {
            guard let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: app.panelModel.optionHeld ? .option : [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp || type == .rightMouseUp ? 0 : 1) else { return }
            NSApp.sendEvent(event)
        }
        send(.mouseMoved)
        try? await Task.sleep(nanoseconds: 40_000_000)
        send(right ? .rightMouseDown : .leftMouseDown)
        try? await Task.sleep(nanoseconds: 60_000_000)
        send(right ? .rightMouseUp : .leftMouseUp)
        try? await Task.sleep(nanoseconds: 120_000_000)
    }

    private func shot(_ name: String) {
        let panel = app.panel.panel
        let board = app.store.board
        note("""
        [\(name)] panel visible=\(panel.isVisible) key=\(panel.isKeyWindow) alpha=\(panel.alphaValue) frame=\(panel.frame) \
        card=\(Int(app.panelModel.cardHeight)) presented=\(app.panelModel.isPresented) \
        responder=\(panel.firstResponder.map { String(describing: type(of: $0)) } ?? "nil")
        [\(name)] store count=\(board.count) overdue=\(board.overdue.count) today=\(board.dueToday.count) \
        upcoming=\(board.upcoming.count) tasks=\(board.tasks.count) finished=\(app.store.finished.count) \
        loading=\(app.store.isLoading) offline=\(app.store.isOffline) failure=\(String(describing: app.store.failure)) \
        toast=\(app.store.toast?.text ?? "nil")
        """)
        if let view = panel.contentView {
            save(view, to: name + "-panel.png", background: nil)
        }
        if let button = app.statusItem.button {
            let frame = button.window.map { $0.convertToScreen(button.convert(button.bounds, to: nil)) } ?? .zero
            let dark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            note("[\(name)] icon frame=\(frame) dark=\(dark) screen=\(button.window?.screen?.frame ?? .zero)")
            // The menu bar itself can't be captured, so put a bar-like colour behind the icon.
            save(button, to: name + "-icon.png", background: dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.9, alpha: 1))
        }
    }

    private func save(_ view: NSView, to file: String, background: NSColor?) {
        guard view.bounds.width > 0, view.bounds.height > 0,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            note("couldn't capture \(file)")
            return
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        var output = bitmap
        if let background, let filled = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: bitmap.pixelsWide, pixelsHigh: bitmap.pixelsHigh,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
           let context = NSGraphicsContext(bitmapImageRep: filled) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            let rect = NSRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
            background.setFill()
            rect.fill()
            bitmap.draw(in: rect)
            NSGraphicsContext.restoreGraphicsState()
            output = filled
        }
        if let png = output.representation(using: .png, properties: [:]) {
            try? png.write(to: folder.appendingPathComponent(file))
        }
    }
}
