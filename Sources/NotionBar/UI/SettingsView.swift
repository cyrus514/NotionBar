import SwiftUI

/// What the Settings window can ask the rest of the app to do.
struct SettingsActions {
    /// Checks a token against Notion. An empty string means "the saved one".
    var testConnection: (String) async -> (ok: Bool, text: String) = { _ in (false, "") }
    /// A new token was saved: fetch with it.
    var tokenChanged: () -> Void = {}
    /// The database ids changed: look up their data sources and fetch.
    var databasesChanged: () -> Void = {}
    /// Turns notifications on (asking macOS for permission). Returns false if that was refused.
    var enableNotifications: () async -> Bool = { false }
    /// Tries to register the global shortcut. Returns false if macOS refused it.
    var setHotKey: (HotKeyChoice) -> Bool = { _ in true }
}

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var tokens: TokenStore
    @EnvironmentObject private var loginItem: LoginItem
    @Environment(\.theme) private var theme

    var actions: SettingsActions
    var notificationsAvailable = true

    @ViewState private var tokenText = ""
    @ViewState private var testing = false
    @ViewState private var testResult: (ok: Bool, text: String)?
    @ViewState private var tasksDatabaseText = ""
    @ViewState private var stepsDatabaseText = ""
    @ViewState private var databaseNote: String?
    @ViewState private var notificationNote: String?
    @ViewState private var hotKeyNote: String?

    /// The window never grows taller than this: on a small laptop screen the rest scrolls.
    var maxHeight: CGFloat = 660

    var body: some View {
        ScrollView(.vertical) {
            content
        }
        .frame(width: 480, height: maxHeight)
        .onAppear {
            loginItem.refresh()
            tasksDatabaseText = settings.tasksDatabaseID
            stepsDatabaseText = settings.stepsDatabaseID
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            section("notion") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        SecureField("", text: $tokenText, prompt: Text(tokens.hasToken ? "•••••••• (saved)" : "ntn_…"))
                            .textFieldStyle(.roundedBorder)
                            .font(Mono.font(12))
                            .onSubmit(saveToken)
                            .accessibilityLabel("Notion token")
                        Button("Save", action: saveToken)
                            .disabled(tokenText.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    note(tokenStatus)
                    HStack(spacing: 10) {
                        Button(testing ? "Testing…" : "Test connection", action: test)
                            .disabled(testing || (!tokens.hasToken && tokenText.isEmpty))
                        if let testResult {
                            Label(testResult.text, systemImage: testResult.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .font(Mono.font(11))
                                .foregroundStyle(testResult.ok ? theme.success : theme.overdue)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            section("databases") {
                VStack(alignment: .leading, spacing: 8) {
                    databaseField("Task Tracker", text: $tasksDatabaseText)
                    databaseField("Steps", text: $stepsDatabaseText)
                    HStack(spacing: 10) {
                        Button("Save", action: saveDatabases)
                            .disabled(tasksDatabaseText == settings.tasksDatabaseID && stepsDatabaseText == settings.stepsDatabaseID)
                        note(databaseNote ?? "paste each database's link or id · connect your integration to both (••• → connections)")
                    }
                }
            }

            section("refresh") {
                row("Fetch from Notion every") {
                    Picker("", selection: $settings.refreshMinutes) {
                        ForEach(AppSettings.refreshChoices, id: \.self) { Text("\($0) min").tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                row("Open pages in the Notion app", note: "off = open in the browser") {
                    Toggle("", isOn: $settings.openInApp).labelsHidden().toggleStyle(.switch)
                }
                row("Show tasks on their completion date",
                    note: "a task with a completion date filled in pops up that day, not on its due date") {
                    Toggle("", isOn: $settings.planByCompletionDate).labelsHidden().toggleStyle(.switch)
                }
            }

            section("look") {
                row("Animations", note: settings.reduceMotion ? "reduce motion is on in system settings, so they stay off" : nil) {
                    Toggle("", isOn: $settings.animations).labelsHidden().toggleStyle(.switch)
                }
                row("Appearance") {
                    Picker("", selection: $settings.appearance) {
                        ForEach(AppSettings.Appearance.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.segmented).fixedSize()
                }
                row("Text size") {
                    Picker("", selection: $settings.textSize) {
                        ForEach(AppSettings.TextSize.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.segmented).fixedSize()
                }
            }

            section("menu bar") {
                row("Show time until the next due item", note: "e.g. 5 · 45m") {
                    Toggle("", isOn: $settings.showCountdown).labelsHidden().toggleStyle(.switch)
                }
                row("Shortcut to open the panel", note: hotKeyNote) {
                    Picker("", selection: Binding(get: { settings.hotKey }, set: setHotKey)) {
                        ForEach(HotKeyChoice.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                row("Launch at login", note: loginItem.note ?? (loginItem.isAvailable ? nil : "works once the .app is built")) {
                    Toggle("", isOn: Binding(get: { loginItem.isEnabled }, set: { loginItem.set($0) }))
                        .labelsHidden().toggleStyle(.switch)
                }
            }

            section("alerts and focus") {
                row("Notify me when something is due",
                    note: notificationNote ?? (notificationsAvailable
                        ? "at the due time · things with no time: one summary at 7:30 am"
                        : "works once the .app is built")) {
                    Toggle("", isOn: Binding(get: { settings.notifications }, set: setNotifications))
                        .labelsHidden().toggleStyle(.switch)
                }
                row("Heads-up before it's due") {
                    Picker("", selection: $settings.notifyLead) {
                        ForEach(AppSettings.leadChoices, id: \.self) { minutes in
                            Text(minutes == 0 ? "none" : "\(minutes) min").tag(minutes)
                        }
                    }
                    .labelsHidden().fixedSize().disabled(!settings.notifications)
                }
                row("Focus countdown length", note: "right-click a row → focus") {
                    Picker("", selection: $settings.focusMinutes) {
                        ForEach(AppSettings.focusChoices, id: \.self) { Text("\($0) min").tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                row("Play a sound when focus ends") {
                    Toggle("", isOn: $settings.sounds).labelsHidden().toggleStyle(.switch)
                }
            }

            section("if something looks wrong") {
                row("Diagnostics log", note: "what was asked of notion and what came back · never the token") {
                    Button("Show log") {
                        if FileManager.default.fileExists(atPath: Log.url.path) {
                            NSWorkspace.shared.activateFileViewerSelecting([Log.url])
                        } else {
                            NSWorkspace.shared.open(Log.url.deletingLastPathComponent())
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 8)
        .padding(.bottom, 20)
        .frame(width: 480)
        // Tucked in the top-right corner, level with the first heading.
        .overlay(alignment: .topTrailing) {
            CoffeeLink()
                .padding(.top, 17)
                .padding(.trailing, 20)
        }
    }

    // MARK: Pieces

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("// " + title)
                .font(Mono.font(12, bold: true))
                .foregroundStyle(theme.comment)
                .padding(.top, 14)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func row<Control: View>(_ label: String, note text: String? = nil,
                                    @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(Mono.font(12))
                if let text { note(text) }
            }
            Spacer(minLength: 8)
            control()
        }
        .accessibilityElement(children: .combine)
    }

    private func databaseField(_ label: String, text: Binding<String>) -> some View {
        HStack(spacing: 8) {
            Text(label).font(Mono.font(12)).frame(width: 96, alignment: .leading)
            TextField("", text: text, prompt: Text("https://www.notion.so/… or the 32-character id"))
                .textFieldStyle(.roundedBorder)
                .font(Mono.font(11))
                .onSubmit(saveDatabases)
                .accessibilityLabel("\(label) database link or id")
        }
    }

    private func note(_ text: String) -> some View {
        Text("// " + text)
            .font(Mono.font(11))
            .foregroundStyle(theme.detail)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var tokenStatus: String {
        switch tokens.source {
        case .none: return "no token saved yet · make one at notion.so/profile/integrations"
        case .keychain: return "saved in your keychain"
        case .importedFromFile: return "imported from ~/.notion-menubar-token into your keychain"
        case .file: return "read from ~/.notion-menubar-token (the keychain refused the copy)"
        case .demo: return "demo mode: sample data, no token needed"
        case .keychainLocked: return "a token is saved, but macos hasn't let notionbar read it yet · allow it when asked"
        }
    }

    // MARK: Actions

    private func saveToken() {
        let typed = tokenText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return }
        if tokens.set(typed) {
            tokenText = ""
            testResult = nil
            actions.tokenChanged()
            test()
        } else {
            testResult = (false, "couldn't save to the keychain")
        }
    }

    /// Accepts a link or an id for each database, and keeps the id.
    private func saveDatabases() {
        guard let tasks = NotionConfig.normalizeID(tasksDatabaseText) else {
            databaseNote = "the task tracker entry doesn't contain a notion database id"
            return
        }
        guard let steps = NotionConfig.normalizeID(stepsDatabaseText) else {
            databaseNote = "the steps entry doesn't contain a notion database id"
            return
        }
        guard tasks != steps else {
            databaseNote = "those are the same database: steps needs its own"
            return
        }
        if tasks != settings.tasksDatabaseID {
            settings.tasksDatabaseID = tasks
            settings.tasksDataSourceID = ""
        }
        if steps != settings.stepsDatabaseID {
            settings.stepsDatabaseID = steps
            settings.stepsDataSourceID = ""
        }
        tasksDatabaseText = tasks
        stepsDatabaseText = steps
        databaseNote = "saved"
        actions.databasesChanged()
    }

    private func test() {
        testing = true
        testResult = nil
        let typed = tokenText.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            let result = await actions.testConnection(typed)
            testResult = result
            testing = false
        }
    }

    private func setNotifications(_ enabled: Bool) {
        guard enabled else {
            settings.notifications = false
            notificationNote = nil
            return
        }
        Task {
            if await actions.enableNotifications() {
                settings.notifications = true
                notificationNote = nil
            } else {
                settings.notifications = false
                notificationNote = "allow NotionBar in System Settings → Notifications"
            }
        }
    }

    private func setHotKey(_ choice: HotKeyChoice) {
        if actions.setHotKey(choice) {
            settings.hotKey = choice
            hotKeyNote = nil
        } else {
            settings.hotKey = .off
            hotKeyNote = "\(choice.label) is taken by another app"
        }
    }
}

/// A small "buy me a coffee" link, for anyone who'd like to thank the author.
struct CoffeeLink: View {
    @Environment(\.theme) private var theme
    @ViewState private var hovering = false

    var body: some View {
        Button {
            NSWorkspace.shared.open(Links.coffee)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "cup.and.saucer.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color(hex: 0xE6A700))
                Text("buy me a coffee")
                    .font(Mono.font(11))
                    .foregroundStyle(hovering ? theme.text : theme.detail)
                    .underline(hovering)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("like NotionBar? buy its author a coffee · opens buymeacoffee.com")
        .accessibilityLabel("Buy me a coffee")
    }
}
