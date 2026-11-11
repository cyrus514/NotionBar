import AppKit
import SwiftUI

/// `NotionBar --snapshot out.png [--state name] [--dark]`: draws the panel to a PNG using the
/// bundled sample data. It's how the UI can be checked without Xcode previews or a token.
///
/// States: default, tasks, option, filter, add, addstep, day, pinned, done, toast, focus, empty,
/// error, notfound, notoken, offline, loading, menubar, settings.
@MainActor
enum Snapshot {
    static let states = ["hero", "default", "tasks", "option", "filter", "add", "addstep", "day", "pinned", "done", "toast",
                         "focus", "empty", "error", "notfound", "notoken", "offline", "loading", "menubar", "settings"]

    /// Everything a panel needs, built on sample data and frozen at the sample's "now".
    struct Scene {
        var settings: AppSettings
        var store: TaskStore
        var focus: FocusTimer
        var model: PanelModel
        var fake: FakeNotion
    }

    static func scene(state: String, now: Date = Fixtures.referenceNow) async -> Scene {
        let suite = "local.notionbar.NotionBar.snapshot"
        UserDefaults().removePersistentDomain(forName: suite)
        let settings = AppSettings(defaults: UserDefaults(suiteName: suite) ?? .standard)
        settings.animations = false

        let fake = state == "empty" ? FakeNotion(tasks: [], steps: []) : FakeNotion.fixtures()
        var hasToken = true
        switch state {
        case "error": await fake.fail(with: .http(401, "API token is invalid."))
        case "notfound": await fake.fail(with: .http(404, "Could not find database with ID: aaaaaaaa-0000-4000-8000-000000000002. Make sure the relevant pages and databases are shared with your integration."))
        case "notoken": hasToken = false
        default: break
        }

        let store = TaskStore(settings: settings, clock: { now }) {
            hasToken ? NotionClient(token: "snapshot", transport: fake, config: .sample) : nil
        }
        store.refreshesAfterWrites = false
        if state != "loading" { await store.refresh() }

        let focus = FocusTimer()
        let model = PanelModel(store: store, settings: settings, focus: focus)
        model.solidBackground = true
        model.willPresent()

        switch state {
        case "tasks":
            settings.tasksExpanded = true
            if let science = store.board.tasks.first(where: { !$0.steps.isEmpty }) {
                model.expandedTasks = [science.id]
            }
        case "option":
            model.optionHeld = true
        case "filter":
            model.query = "flash"
        case "add":
            model.query = "+ read chapter 4 friday 7pm #hw !high"
        case "done":
            settings.doneExpanded = true
            model.selection = store.board.dueToday.first?.id
        case "toast":
            if let first = store.board.overdue.first?.item {
                store.markDone(first)
                for _ in 0..<200 where store.isWriting { try? await Task.sleep(nanoseconds: 5_000_000) }
            }
        case "focus":
            if let first = store.board.dueToday.first?.item { focus.start(first, minutes: 25) }
        case "day":
            model.dayFilter = store.board.today.adding(1)
        case "pinned":
            model.isPinned = true
        case "addstep":
            settings.tasksExpanded = true
            if let science = store.board.tasks.first(where: { !$0.steps.isEmpty }) {
                model.expandedTasks = [science.id]
                model.beginAddStep(science.task)
                model.query = "+ make cue cards tomorrow 7pm #prepare"
            }
        case "offline":
            await fake.fail(with: .offline)
            await store.refresh()
        default:
            break
        }
        return Scene(settings: settings, store: store, focus: focus, model: model, fake: fake)
    }

    static func runAndExit(path: String, options: LaunchOptions) {
        Task { @MainActor in
            let dark = options.dark ?? false
            let names = options.state.split(separator: ",").map(String.init)
            let scene = await scene(state: names.first ?? "default", now: options.now ?? Fixtures.referenceNow)
            var size: NSSize
            var view: AnyView
            /// The panels in the picture. When there are any, the picture is trimmed to fit them.
            var panels: [Scene] = []
            let backdrop = LinearGradient(
                colors: dark ? [Color(hex: 0x1A1F29), Color(hex: 0x2E3441)] : [Color(hex: 0xDDE5EF), Color(hex: 0xBFCBDA)],
                startPoint: .topLeading, endPoint: .bottomTrailing)

            switch options.state {
            case "menubar":
                size = NSSize(width: 660, height: 132)
                view = AnyView(MenuBarSheet())
            case "hero":
                // The README's opening picture: the same list in dark (tasks/ unfolded) and in light.
                let unfolded = await Snapshot.scene(state: "tasks", now: options.now ?? Fixtures.referenceNow)
                panels = [unfolded, scene]
                let width = Metrics.panelWidth + PanelRoot.margin * 2
                size = NSSize(width: width * 2 + 40, height: 1150)
                for each in panels { each.model.maxHeight = 1090 }
                view = AnyView(
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(Array(panels.enumerated()), id: \.offset) { index, each in
                            PanelRoot()
                                .environmentObject(each.store)
                                .environmentObject(each.model)
                                .environmentObject(each.settings)
                                .environmentObject(each.focus)
                                .frame(width: width)
                                .environment(\.colorScheme, index == 0 ? .dark : .light)
                        }
                    }
                    .padding(.horizontal, 20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .background(LinearGradient(colors: [Color(hex: 0x10141C), Color(hex: 0x27405E), Color(hex: 0x8FA6BF)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing))
                )
            case "settings":
                size = NSSize(width: 480, height: 860)
                let tokens = TokenStore(demo: true)
                view = AnyView(
                    Themed { SettingsView(actions: SettingsActions()) }
                        .environmentObject(scene.settings)
                        .environmentObject(tokens)
                        .environmentObject(LoginItem())
                        .frame(maxHeight: .infinity, alignment: .top)
                        .background(Color(nsColor: .windowBackgroundColor))
                )
            default:
                panels = [scene]
                size = NSSize(width: Metrics.panelWidth + PanelRoot.margin * 2, height: options.tall ? 1150 : 700)
                scene.model.maxHeight = options.tall ? 1090 : 600
                view = AnyView(
                    PanelRoot()
                        .environmentObject(scene.store)
                        .environmentObject(scene.model)
                        .environmentObject(scene.settings)
                        .environmentObject(scene.focus)
                        // Something desktop-like behind the card, so its edge and shadow can be judged.
                        .background(backdrop)
                )
            }

            // Several states at once ("--state filter,add,done"): one panel per state, side by side.
            if names.count > 1 {
                var scenes = [scene]
                defer { panels = scenes }
                for name in names.dropFirst() {
                    scenes.append(await Snapshot.scene(state: name, now: options.now ?? Fixtures.referenceNow))
                }
                let width = Metrics.panelWidth + PanelRoot.margin * 2
                size = NSSize(width: width * CGFloat(scenes.count), height: options.tall ? 1150 : 700)
                view = AnyView(
                    HStack(spacing: 0) {
                        ForEach(Array(scenes.enumerated()), id: \.offset) { _, each in
                            PanelRoot()
                                .environmentObject(each.store)
                                .environmentObject(each.model)
                                .environmentObject(each.settings)
                                .environmentObject(each.focus)
                                .frame(width: width)
                        }
                    }
                    .background(backdrop)
                )
                for each in scenes { each.model.maxHeight = options.tall ? 1090 : 600 }
            }

            let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: size),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let hosting = NSHostingView(rootView: view)
            hosting.sizingOptions = []
            hosting.frame = NSRect(origin: .zero, size: size)
            window.contentView = hosting
            window.orderFrontRegardless()

            // Let SwiftUI lay out, measure the list and settle.
            for _ in 0..<12 {
                hosting.layoutSubtreeIfNeeded()
                try? await Task.sleep(nanoseconds: 60_000_000)
            }

            // Trim the picture to the tallest panel, so there's no empty backdrop underneath.
            if let tallest = panels.map(\.model.cardHeight).max(), tallest > 0 {
                size.height = min(size.height, tallest + PanelRoot.margin * 2)
                window.setContentSize(size)
                hosting.frame = NSRect(origin: .zero, size: size)
                for _ in 0..<4 {
                    hosting.layoutSubtreeIfNeeded()
                    try? await Task.sleep(nanoseconds: 60_000_000)
                }
            }

            guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
                print("couldn't make a bitmap")
                exit(1)
            }
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                print("couldn't encode the png")
                exit(1)
            }
            do {
                try png.write(to: URL(fileURLWithPath: path))
                print("wrote \(path)  \(bitmap.pixelsWide)×\(bitmap.pixelsHigh)  state=\(options.state) \(dark ? "dark" : "light")")
                exit(0)
            } catch {
                print("couldn't write \(path): \(error.localizedDescription)")
                exit(1)
            }
        }
    }
}

/// Every look the menu bar icon has, side by side on a light and a dark bar.
private struct MenuBarSheet: View {
    private static let looks: [(String, String, Color?, String)] = [
        ("nothing overdue", "checklist", nil, "2"),
        ("overdue", "exclamationmark.circle", nil, "5"),
        ("pulse", "exclamationmark.circle.fill", Tint.red, "5"),
        ("all done", "checkmark.circle", nil, ""),
        ("marked done", "checkmark.circle.fill", Tint.green, "5"),
        ("loading", "hourglass", nil, "5"),
        ("error", "exclamationmark.triangle", nil, ""),
        ("countdown", "checklist", nil, "2 · 45m"),
        ("focus", "timer", nil, "24:59"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            bar(dark: false)
            bar(dark: true)
        }
    }

    private func bar(dark: Bool) -> some View {
        HStack(spacing: 12) {
            ForEach(MenuBarSheet.looks, id: \.0) { look in
                VStack(spacing: 4) {
                    StatusIconView(model: model(look))
                    Text(look.0).font(.system(size: 8)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(dark ? Color(hex: 0x1E222A) : Color(hex: 0xE8ECF1))
        .environment(\.colorScheme, dark ? .dark : .light)
    }

    private func model(_ look: (String, String, Color?, String)) -> StatusIconModel {
        let model = StatusIconModel()
        model.symbol = look.1
        model.tint = look.2
        model.text = look.3
        model.motion = false
        return model
    }
}
