import AppKit
import Combine
import SwiftUI

/// Everything in the Settings window, saved in UserDefaults. (The token is not here: it lives in the Keychain.)
@MainActor
final class AppSettings: ObservableObject {
    enum Appearance: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
    }

    enum TextSize: String, CaseIterable, Identifiable {
        case small, regular, large
        var id: String { rawValue }
        var scale: CGFloat {
            switch self {
            case .small: return 0.92
            case .regular: return 1
            case .large: return 1.1
            }
        }
    }

    static let refreshChoices = [1, 2, 5, 10, 15, 30]
    static let leadChoices = [0, 5, 10, 15, 30, 60]
    static let focusChoices = [15, 25, 45, 60]

    private let defaults: UserDefaults

    /// Minutes between fetches from Notion.
    @Published var refreshMinutes: Int { didSet { defaults.set(refreshMinutes, forKey: "refreshMinutes") } }
    /// Open pages with `notion://` (the app) instead of `https://` (the browser).
    @Published var openInApp: Bool { didSet { defaults.set(openInApp, forKey: "openInApp") } }
    @Published var animations: Bool { didSet { defaults.set(animations, forKey: "animations") } }
    @Published var appearance: Appearance { didSet { defaults.set(appearance.rawValue, forKey: "appearance") } }
    @Published var textSize: TextSize { didSet { defaults.set(textSize.rawValue, forKey: "textSize") } }
    /// Show the time until the next timed item next to the count in the menu bar.
    @Published var showCountdown: Bool { didSet { defaults.set(showCountdown, forKey: "showCountdown") } }
    @Published var notifications: Bool { didSet { defaults.set(notifications, forKey: "notifications") } }
    /// Minutes of warning before an item is due. 0 = only at the due time.
    @Published var notifyLead: Int { didSet { defaults.set(notifyLead, forKey: "notifyLead") } }
    @Published var hotKey: HotKeyChoice { didSet { defaults.set(hotKey.rawValue, forKey: "hotKey") } }
    @Published var focusMinutes: Int { didSet { defaults.set(focusMinutes, forKey: "focusMinutes") } }
    @Published var sounds: Bool { didSet { defaults.set(sounds, forKey: "sounds") } }

    // The two Notion databases, as dashed ids. Empty until they're filled in under Settings → databases.
    @Published var tasksDatabaseID: String { didSet { defaults.set(tasksDatabaseID, forKey: "tasksDatabaseID") } }
    @Published var stepsDatabaseID: String { didSet { defaults.set(stepsDatabaseID, forKey: "stepsDatabaseID") } }
    /// Looked up from the database ids the first time they're used (see `AppDelegate.findDataSources`).
    @Published var tasksDataSourceID: String { didSet { defaults.set(tasksDataSourceID, forKey: "tasksDataSourceID") } }
    @Published var stepsDataSourceID: String { didSet { defaults.set(stepsDataSourceID, forKey: "stepsDataSourceID") } }

    /// Where the app reads from, built from the ids above.
    var notionConfig: NotionConfig {
        NotionConfig(tasksDatabase: tasksDatabaseID, tasksDataSource: tasksDataSourceID,
                     stepsDatabase: stepsDatabaseID, stepsDataSource: stepsDataSourceID)
    }

    /// Treat a task's Completion date, when it's filled in ahead of time, as the day you plan to do it:
    /// the task shows up that day instead of on its Due date.
    @Published var planByCompletionDate: Bool { didSet { defaults.set(planByCompletionDate, forKey: "planByCompletionDate") } }

    // What's folded open in the panel.
    @Published var tasksExpanded: Bool { didSet { defaults.set(tasksExpanded, forKey: "tasksExpanded") } }
    @Published var doneExpanded: Bool { didSet { defaults.set(doneExpanded, forKey: "doneExpanded") } }

    /// System Settings → Accessibility → Display → Reduce motion.
    @Published private(set) var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    /// True when animations should actually play.
    var motion: Bool { animations && !reduceMotion }

    private var observer: NSObjectProtocol?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            "refreshMinutes": 5, "openInApp": true, "animations": true, "showCountdown": false,
            "notifications": false, "notifyLead": 10, "focusMinutes": 25, "sounds": true,
            "tasksExpanded": false, "doneExpanded": false,
        ])
        let minutes = defaults.integer(forKey: "refreshMinutes")
        refreshMinutes = AppSettings.refreshChoices.contains(minutes) ? minutes : 5
        openInApp = defaults.bool(forKey: "openInApp")
        animations = defaults.bool(forKey: "animations")
        appearance = Appearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
        textSize = TextSize(rawValue: defaults.string(forKey: "textSize") ?? "") ?? .regular
        showCountdown = defaults.bool(forKey: "showCountdown")
        notifications = defaults.bool(forKey: "notifications")
        notifyLead = defaults.integer(forKey: "notifyLead")
        hotKey = HotKeyChoice(rawValue: defaults.string(forKey: "hotKey") ?? "") ?? .off
        let focus = defaults.integer(forKey: "focusMinutes")
        focusMinutes = AppSettings.focusChoices.contains(focus) ? focus : 25
        sounds = defaults.bool(forKey: "sounds")
        tasksExpanded = defaults.bool(forKey: "tasksExpanded")
        doneExpanded = defaults.bool(forKey: "doneExpanded")
        planByCompletionDate = defaults.bool(forKey: "planByCompletionDate")
        tasksDatabaseID = defaults.string(forKey: "tasksDatabaseID") ?? ""
        stepsDatabaseID = defaults.string(forKey: "stepsDatabaseID") ?? ""
        tasksDataSourceID = defaults.string(forKey: "tasksDataSourceID") ?? ""
        stepsDataSourceID = defaults.string(forKey: "stepsDataSourceID") ?? ""

        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            }
        }
    }

    /// The appearance to force on the panel, or nil to follow the system.
    var nsAppearance: NSAppearance? {
        switch appearance {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// Runs `body` inside an animation when motion is on, and plainly when it's off.
@MainActor
func animate(_ enabled: Bool, _ animation: Animation = .snappy(duration: 0.3), _ body: () -> Void) {
    if enabled {
        withAnimation(animation, body)
    } else {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, body)
    }
}
