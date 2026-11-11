import Foundation

/// How the app was started. Everything except plain launch is for trying things without a token.
struct LaunchOptions {
    /// `--demo`: run against the bundled sample data instead of Notion.
    var demo = false
    /// `--show`: open the panel as soon as the app starts.
    var showPanel = false
    /// `--selftest`: run the built-in checks and exit.
    var selfTest = false
    /// `--dump`: print the sections as plain text and exit.
    var dump = false
    /// `--snapshot <file.png>`: draw the panel to an image and exit.
    var snapshot: String?
    /// `--state <name>`: which panel state to draw (see `Snapshot.states`).
    var state = "default"
    /// `--dark` / `--light`
    var dark: Bool?
    /// `--now <ISO date-time>`: pretend it's this moment (dump and snapshot).
    var now: Date?
    /// `--fixtures <folder>`: read `tasks-query.json` and `steps-query.json` from here.
    var fixtures: String?
    /// `--make-icon <folder>`: write the app icon PNGs and exit.
    var makeIcon: String?
    /// `--tall`: let the snapshot's panel grow past 600 pt, to see a long list in one image.
    var tall = false
    /// `--plan`: with `--dump`, schedule tasks by their Completion date when they have one.
    var plan = false
    /// `--debug "<steps>"`: drive the running app from a script (see `DebugDriver`).
    var debugScript: String?
    /// `--debug-dir <folder>`: where the debug script writes its images and log.
    var debugDir: String?

    init(_ arguments: [String] = Array(CommandLine.arguments.dropFirst())) {
        var index = 0
        func value() -> String? {
            index += 1
            return index < arguments.count ? arguments[index] : nil
        }
        while index < arguments.count {
            switch arguments[index] {
            case "--demo": demo = true
            case "--show": showPanel = true
            case "--selftest": selfTest = true
            case "--dump": dump = true
            case "--tall": tall = true
            case "--plan": plan = true
            case "--debug": debugScript = value()
            case "--debug-dir": debugDir = value()
            case "--dark": dark = true
            case "--light": dark = false
            case "--snapshot": snapshot = value()
            case "--state": state = value() ?? "default"
            case "--now": now = value().flatMap(NotionDate.parseDateTime)
            case "--fixtures": fixtures = value()
            case "--make-icon": makeIcon = value()
            default: break
            }
            index += 1
        }
        if ProcessInfo.processInfo.environment["NOTIONBAR_DEMO"] == "1" { demo = true }
    }
}

/// `NotionBar --dump`: prints the same sections the panel shows, one row per line.
/// `scripts/compare_with_plugin.py` prints the Python plugin's output in the same shape,
/// so the two can be diffed.
@MainActor
enum Dump {
    static func runAndExit(_ options: LaunchOptions) -> Never {
        Task { @MainActor in
            let fake: FakeNotion
            if let folder = options.fixtures {
                func pages(_ name: String) -> [JSONValue] {
                    let url = URL(fileURLWithPath: folder).appendingPathComponent(name + ".json")
                    return (try? Data(contentsOf: url)).flatMap(JSONValue.parse)?["results"]?.arrayValue ?? []
                }
                fake = FakeNotion(tasks: pages("tasks-query"), steps: pages("steps-query"))
            } else {
                fake = FakeNotion.fixtures()
            }
            let client = NotionClient(token: "dump", transport: fake, config: .sample)
            do {
                let built = ItemBuilder.build(tasks: try await client.openTasks(), steps: try await client.openSteps(),
                                              planByCompletionDate: options.plan)
                print(text(Board.build(tasks: built.tasks, steps: built.steps, now: options.now ?? Fixtures.referenceNow)))
                exit(0)
            } catch {
                print("error: \(error)")
                exit(1)
            }
        }
        while true { RunLoop.main.run(mode: .default, before: .distantFuture) }
    }

    static func text(_ board: Board) -> String {
        var lines = ["count=\(board.count) overdue=\(board.hasOverdue)"]
        // The plugin doesn't tag steps as "in progress", and under tasks/ it only knows overdue or not.
        func line(_ row: Board.Row, nested: Bool = false) -> String {
            let detail = row.item.kind == .step ? row.detail.filter { $0 != "in progress" } : row.detail
            let state = nested && row.state == .late ? RowState.normal : row.state
            return "\(nested ? "  " : "")\(state.rawValue) | \(row.item.name) | \(detail.joined(separator: " · "))"
        }
        if !board.overdue.isEmpty {
            lines.append("[overdue (\(board.overdue.count))]")
            lines += board.overdue.map { line($0) }
        }
        lines.append("[\(board.header)]")
        lines += board.dueToday.isEmpty ? ["nothing due today"] : board.dueToday.map { line($0) }
        if !board.upcoming.isEmpty {
            lines.append("[upcoming]")
            lines += board.upcoming.map { line($0) }
            if board.upcomingHidden > 0 { lines.append("more=\(board.upcomingHidden)") }
        }
        lines.append("[tasks/ (\(board.tasks.count))]")
        for group in board.tasks {
            lines.append("\(group.state.rawValue) | \(group.task.name) | \(group.detailText)")
            lines += group.steps.map { line($0, nested: true) }
        }
        if board.tasks.isEmpty { lines.append("everything's done") }
        return lines.joined(separator: "\n")
    }
}
