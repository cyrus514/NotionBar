import AppKit
import Combine
import SwiftUI

/// Builds the app's pieces and connects them: the store, the menu bar icon, the panel,
/// the Settings window, notifications, the global shortcut and the focus timer.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let options: LaunchOptions

    private(set) var settings: AppSettings!
    private var tokens: TokenStore!
    private(set) var store: TaskStore!
    private(set) var focus: FocusTimer!
    private var loginItem: LoginItem!
    private var notifier: Notifier!
    private(set) var hotKey: HotKey!
    private(set) var panelModel: PanelModel!
    private(set) var panel: PanelController!
    private(set) var statusItem: StatusItemController!
    private var settingsWindow: NSWindow?
    private(set) var fake: FakeNotion?
    private var subscriptions = Set<AnyCancellable>()

    init(options: LaunchOptions) {
        self.options = options
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let path = options.snapshot {
            Snapshot.runAndExit(path: path, options: options)
            return
        }
        if let folder = options.makeIcon {
            AppIcon.writeAndExit(to: folder)
            return
        }
        guard !alreadyRunning() else {
            NSApp.terminate(nil)
            return
        }
        build()
    }

    /// A second copy would put a second icon in the menu bar.
    private func alreadyRunning() -> Bool {
        guard !options.demo, let id = Bundle.main.bundleIdentifier else { return false }
        let me = NSRunningApplication.current
        return NSRunningApplication.runningApplications(withBundleIdentifier: id).contains { $0 != me }
    }

    private func build() {
        // Demo mode keeps its own settings and never touches the Keychain or the saved copy of your list.
        let defaults = options.demo ? (UserDefaults(suiteName: "local.notionbar.NotionBar.demo") ?? .standard) : .standard
        settings = AppSettings(defaults: defaults)
        tokens = TokenStore(demo: options.demo)
        focus = FocusTimer()
        loginItem = LoginItem()
        notifier = Notifier()

        if options.demo {
            let fake = FakeNotion.fixtures(shiftedTo: Day(Date()), latency: 0.7)
            self.fake = fake
            store = TaskStore(settings: settings) { NotionClient(token: "demo", transport: fake, config: .sample) }
        } else {
            let tokens = tokens!
            Log.isEnabled = true
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
            Log.write("launched NotionBar \(version) on macOS \(ProcessInfo.processInfo.operatingSystemVersionString); token: \(tokens.source.rawValue)")
            let settings = settings!
            store = TaskStore(settings: settings, cache: .standard, whyNoToken: {
                if tokens.source == .keychainLocked { return .keychainLocked }
                if !tokens.hasToken { return .missingToken }
                return .missingDatabases
            }) {
                // No token yet: look again. The Keychain may be readable now (screen unlocked, question
                // answered), or ~/.notion-menubar-token may have been created since launch.
                if !tokens.hasToken { tokens.load() }
                let config = settings.notionConfig
                guard config.isComplete else { return nil }
                return tokens.token.map { NotionClient(token: $0, config: config) }
            }
        }

        ClickTargets.enabled = options.debugScript != nil
        panelModel = PanelModel(store: store, settings: settings, focus: focus)
        if !options.demo {
            panelModel.config = { [weak self] in self?.settings.notionConfig ?? NotionConfig() }
        }
        panel = PanelController(model: panelModel, store: store, settings: settings, focus: focus)
        statusItem = StatusItemController(store: store, settings: settings, focus: focus)

        statusItem.onClick = { [weak self] in self?.togglePanel() }
        statusItem.makeMenu = { [weak self] in self?.contextMenu() ?? NSMenu() }
        panel.onVisibilityChange = { [weak self] visible in self?.statusItem.setHighlighted(visible) }
        panelModel.close = { [weak self] in self?.panel.close() }
        panelModel.openSettings = { [weak self] in self?.showSettings() }
        panelModel.quit = { NSApp.terminate(nil) }

        hotKey = HotKey { [weak self] in self?.togglePanel() }
        if !hotKey.set(settings.hotKey) { settings.hotKey = .off }

        installEditMenu()
        setUpNotifications()
        setUpFocus()

        store.start()
        Task { await findDataSources() }

        if let script = options.debugScript {
            DebugDriver(app: self, folder: options.debugDir).run(script)
        }

        if options.showPanel {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.togglePanel() }
        } else if !options.demo, tokens.source != .keychainLocked,
                  !tokens.hasToken || !settings.notionConfig.isComplete {
            // First launch, with a token or the databases still to fill in: go straight to where they go.
            // (Not when a token is saved and the Keychain just hasn't released it yet.)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.showSettings() }
        }
    }

    /// The app never shows a menu bar of its own, but text fields find ⌘C, ⌘V, ⌘X, ⌘A and ⌘Z
    /// through the Edit menu, so one has to exist for pasting the token in Settings to work.
    private func installEditMenu() {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let app = NSMenu(title: "NotionBar")
        app.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        app.addItem(withTitle: "Quit NotionBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let main = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = app
        main.addItem(appItem)
        let editItem = NSMenuItem()
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    /// Looks up each database's data source (what Notion's newer endpoints want) and saves it.
    /// Until that succeeds the older database endpoint is used, which works just as well here.
    private func findDataSources() async {
        guard !options.demo, let token = tokens.token else { return }
        let config = settings.notionConfig
        guard config.isComplete else { return }
        let client = NotionClient(token: token, config: config)
        if config.tasksDataSource.isEmpty, let found = await client.dataSource(forDatabase: config.tasksDatabase) {
            settings.tasksDataSourceID = found
            Log.write("found the task tracker's data source")
        }
        if config.stepsDataSource.isEmpty, let found = await client.dataSource(forDatabase: config.stepsDatabase) {
            settings.stepsDataSourceID = found
            Log.write("found the steps database's data source")
        }
    }

    var isSettingsVisible: Bool { settingsWindow?.isVisible ?? false }

    func togglePanel() {
        panel.toggle(under: statusItem.button)
    }

    // MARK: Right-click menu

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("Refresh", #selector(refreshNow), key: "r"))
        menu.addItem(item("Settings…", #selector(openSettingsFromMenu), key: ","))
        let login = item("Launch at Login", #selector(toggleLoginItem))
        loginItem.refresh()
        login.state = loginItem.isEnabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(item("Quit NotionBar", #selector(quit), key: "q"))
        return menu
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func refreshNow() {
        Task { await store.refresh() }
    }

    @objc private func openSettingsFromMenu() {
        showSettings()
    }

    @objc private func toggleLoginItem() {
        loginItem.toggle()
        if let note = loginItem.note {
            store.show(.error, "launch at login: \(note)")
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: Settings window

    func showSettings() {
        panel.close()
        if settingsWindow == nil {
            var actions = SettingsActions()
            actions.testConnection = { [weak self] typed in
                guard let self else { return (false, "") }
                let token = typed.isEmpty ? (self.tokens.token ?? "") : typed
                guard !token.isEmpty else { return (false, "no token yet") }
                let transport: any Transport = self.fake ?? URLSessionTransport.shared
                let config = self.fake == nil ? self.settings.notionConfig : NotionConfig.sample
                guard config.isComplete else { return (false, "add your two databases below first") }
                return await NotionClient(token: token, transport: transport, config: config).testConnection()
            }
            actions.tokenChanged = { [weak self] in
                Task {
                    await self?.findDataSources()
                    await self?.store.refresh()
                }
            }
            actions.databasesChanged = { [weak self] in
                Task {
                    await self?.findDataSources()
                    await self?.store.refresh()
                }
            }
            actions.enableNotifications = { [weak self] in
                await self?.notifier.requestPermission() ?? false
            }
            actions.setHotKey = { [weak self] choice in
                self?.hotKey.set(choice) ?? false
            }

            let view = Themed {
                SettingsView(actions: actions, notificationsAvailable: self.notifier.isAvailable)
            }
            .environmentObject(settings)
            .environmentObject(tokens)
            .environmentObject(loginItem)

            let hosting = NSHostingController(rootView: view)
            hosting.sizingOptions = .preferredContentSize
            let window = NSWindow(contentViewController: hosting)
            window.title = "NotionBar Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
        settingsWindow?.orderFrontRegardless()
    }

    // MARK: Notifications and focus

    private func setUpNotifications() {
        notifier.activate()
        notifier.onOpen = { [weak self] page in
            guard let self else { return }
            if let page {
                self.panelModel.openPage(page)
            } else {
                self.panel.open(under: self.statusItem.button)
            }
        }
        notifier.onMarkDone = { [weak self] page in
            guard let self, let item = (self.store.tasks + self.store.steps).first(where: { $0.id == page }) else { return }
            self.store.markDone(item)
        }

        // Re-plan the alerts whenever the list or the notification settings change.
        Publishers.CombineLatest4(store.$steps, store.$tasks, settings.$notifications, settings.$notifyLead)
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { [weak self] steps, tasks, enabled, lead in
                guard let self else { return }
                if enabled {
                    self.notifier.schedule(tasks + steps, now: Date(), leadMinutes: lead)
                } else {
                    self.notifier.cancelAll()
                }
            }
            .store(in: &subscriptions)
    }

    private func setUpFocus() {
        focus.onComplete = { [weak self] session in
            guard let self else { return }
            self.statusItem.celebrate()
            if self.settings.sounds { NSSound(named: "Glass")?.play() }
            if self.settings.notifications { self.notifier.focusFinished(session) }
            self.store.show(.done, "\(session.minutes) min of focus done · \(session.item.name)")
        }
    }
}
