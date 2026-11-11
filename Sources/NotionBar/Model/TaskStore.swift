import AppKit
import Combine
import Network
import SwiftUI

/// The app's state: what's unfinished in Notion, when it was last fetched, and what went wrong.
/// The panel and the menu bar icon both draw from this.
@MainActor
final class TaskStore: ObservableObject {
    /// Why the list couldn't be loaded.
    enum Failure: Equatable {
        case missingToken
        /// A token is saved, but macOS hasn't let the app read it from the Keychain yet.
        case keychainLocked
        /// The two database ids haven't been filled in under Settings yet.
        case missingDatabases
        case unauthorized(String)
        case notFound(String)
        case other(String)

        /// The `//` hint under the error.
        var hint: String? {
            switch self {
            case .missingToken: return "paste your notion token in settings"
            case .keychainLocked: return "macos will ask to let notionbar use its saved token: choose always allow"
            case .missingDatabases: return "paste your two notion database links in settings → databases"
            case .unauthorized: return "your notion token isn't valid"
            case .notFound: return "add the integration to both databases (••• → connections)"
            case .other: return nil
            }
        }

        var message: String {
            switch self {
            case .missingToken: return "no token yet"
            case .keychainLocked: return "your token is saved, but the keychain hasn't handed it over yet"
            case .missingDatabases: return "no databases chosen yet"
            case .unauthorized(let text), .notFound(let text), .other(let text): return text
            }
        }

        /// True when the fix is in the Settings window.
        var needsSettings: Bool {
            switch self {
            case .missingToken, .unauthorized, .missingDatabases: return true
            case .keychainLocked, .notFound, .other: return false
            }
        }
    }

    /// The short message that slides up from the bottom of the panel.
    struct Toast: Identifiable, Equatable {
        enum Kind { case done, info, error }
        let id = UUID()
        var kind: Kind
        var text: String
        var canUndo = false
    }

    enum Event {
        /// A step or task was just marked done (before Notion has confirmed).
        case markedDone
        /// Notion refused, and the row was put back.
        case markFailed
        /// A fetch finished and the list is fresh.
        case refreshed
    }

    // MARK: Published state

    @Published private(set) var tasks: [Item] = []
    @Published private(set) var steps: [Item] = []
    /// Finished today, newest first.
    @Published private(set) var finished: [Item] = []
    @Published private(set) var board: Board
    @Published private(set) var isLoading = false
    /// True once there is something to show (from Notion or from the saved copy).
    @Published private(set) var hasData = false
    @Published private(set) var failure: Failure?
    /// Notion can't be reached; the list on screen is the last one that loaded.
    @Published private(set) var isOffline = false
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var now: Date
    /// Rows that have been ticked and are about to slide away.
    @Published private(set) var completing: Set<String> = []
    @Published var toast: Toast?

    let events = PassthroughSubject<Event, Never>()

    // MARK: Wiring

    private let settings: AppSettings
    private let makeClient: () -> NotionClient?
    /// Why there's no client: no token at all, or one the Keychain won't release yet.
    private let whyNoToken: () -> Failure
    private let clock: () -> Date
    private let cache: Cache?

    private var refreshTimer: Timer?
    private var minuteTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var subscriptions = Set<AnyCancellable>()
    private var lastAttempt: Date?
    private var network: NWPathMonitor?
    private var activity: NSObjectProtocol?
    private var toastTimer: Task<Void, Never>?

    /// Writes to Notion that haven't finished yet. Fetches wait for these, so a refresh
    /// can't bring back a row that is in the middle of being marked done.
    private var writesInFlight = 0
    private var refreshWhenWritesFinish = false
    /// Fetch again shortly after a write lands. Turned off by the self-test, which fetches by hand.
    var refreshesAfterWrites = true
    var isWriting: Bool { writesInFlight > 0 }
    /// Rows to leave out of fetched results for a few seconds after marking them done,
    /// in case Notion's query hasn't caught up with the change yet.
    private var hidden: [String: Date] = [:]

    private struct Undo {
        var receipt: DoneReceipt
        var steps: [Item]
    }
    private var undo: Undo?

    var canUndo: Bool { undo != nil }
    var motion: Bool { settings.motion }

    init(settings: AppSettings,
         clock: @escaping () -> Date = Date.init,
         cache: Cache? = nil,
         whyNoToken: @escaping () -> Failure = { .missingToken },
         client: @escaping () -> NotionClient?) {
        self.settings = settings
        self.clock = clock
        self.cache = cache
        self.makeClient = client
        self.whyNoToken = whyNoToken
        let now = clock()
        self.now = now
        self.board = Board.empty(now: now)
        restoreFromCache()
    }

    // MARK: Lifecycle

    /// Starts the timers and does the first fetch.
    func start() {
        // A menu bar app has no window, so macOS would otherwise "nap" it and let its timers run
        // late. The count and the late/overdue colours have to change on the minute.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Keeps the menu bar count and due times current")

        scheduleRefreshTimer()
        scheduleMinuteTimer()

        // Switching how tasks are scheduled regroups everything: fetch again.
        settings.$planByCompletionDate.dropFirst().removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor in await self?.refresh() }
            }
            .store(in: &subscriptions)

        settings.$refreshMinutes.dropFirst().removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor in self?.scheduleRefreshTimer() }
            }
            .store(in: &subscriptions)

        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.tick()
                self.scheduleMinuteTimer()
                // Give Wi-Fi a moment to reconnect after waking.
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await self.refresh()
            }
        })
        // Screen back on or unlocked: anything that was waiting on you (the Keychain question) can go ahead.
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.failure != nil || self.isStale(olderThan: 60) else { return }
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    await self.refresh()
                }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            // Midnight: regroup the rows now, and fetch so "finished today" starts over.
            Task { @MainActor in
                self?.tick()
                await self?.refresh()
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSNotification.Name.NSSystemTimeZoneDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reparse() }
        })

        // Back online: fetch straight away instead of waiting for the next timer.
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in
                guard let self, self.isOffline else { return }
                await self.refresh()
            }
        }
        monitor.start(queue: DispatchQueue.global(qos: .utility))
        network = monitor

        Task { await refresh() }
    }

    private func scheduleRefreshTimer() {
        refreshTimer?.invalidate()
        let interval = TimeInterval(max(1, settings.refreshMinutes) * 60)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    /// Redraws on every minute boundary so late and overdue states change on time, with no fetch.
    private func scheduleMinuteTimer() {
        minuteTimer?.invalidate()
        let next = Day.calendar.nextDate(after: Date(), matching: DateComponents(second: 0), matchingPolicy: .nextTime)
            ?? Date().addingTimeInterval(60)
        let timer = Timer(fire: next.addingTimeInterval(0.05), interval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        minuteTimer = timer
    }

    /// Re-reads the clock and regroups the rows.
    func tick() {
        now = clock()
        rebuild()
    }

    private func rebuild() {
        let next = Board.build(tasks: tasks, steps: steps, now: now)
        if next != board { board = next }
    }

    // MARK: Fetching

    /// True when the last fetch attempt was longer ago than `seconds`.
    func isStale(olderThan seconds: TimeInterval) -> Bool {
        guard let lastAttempt else { return true }
        return Date().timeIntervalSince(lastAttempt) > seconds
    }

    func refreshIfStale(olderThan seconds: TimeInterval = 30) {
        guard isStale(olderThan: seconds) else { return }
        Task { await refresh() }
    }

    /// Fetches both databases from Notion.
    func refresh() async {
        guard !isLoading else { return }
        guard writesInFlight == 0 else {
            refreshWhenWritesFinish = true
            return
        }
        guard let client = makeClient() else {
            failure = whyNoToken()
            isOffline = false
            return
        }

        isLoading = true
        lastAttempt = Date()
        tick()
        let today = Day(now)
        let started = Date()

        do {
            async let taskPages = client.openTasks()
            async let stepPages = client.openSteps()
            let fetched = try await (tasks: taskPages, steps: stepPages)
            // After the main lists, not alongside them: four requests at once is over Notion's
            // three-a-second allowance, and this is the part that can wait.
            let done = await TaskStore.finishedToday(client, since: today.startOfDay, today: today)

            // A write started while we were waiting: this reply may predate it, so fetch again after.
            guard writesInFlight == 0 else {
                isLoading = false
                refreshWhenWritesFinish = true
                return
            }
            now = clock()
            animate(motion && hasData) {
                apply(tasks: fetched.tasks, steps: fetched.steps, done: done)
            }
            failure = nil
            isOffline = false
            hasData = true
            lastUpdated = Date()
            cache?.save(Cache.File(savedAt: Date(), tasks: fetched.tasks, steps: fetched.steps,
                                   doneTasks: done.tasks, doneSteps: done.steps))
            isLoading = false
            Log.write(String(format: "refresh ok: %d tasks, %d steps open; %d tasks, %d steps finished today (%.2fs)",
                             fetched.tasks.count, fetched.steps.count, done.tasks.count, done.steps.count,
                             Date().timeIntervalSince(started)))
            events.send(.refreshed)
        } catch {
            let problem = (error as? NotionError) ?? .network(error.localizedDescription)
            Log.write("refresh failed: \(problem.message)")
            if problem.isNetwork && hasData {
                // Keep showing the last list, greyed out.
                isOffline = true
                failure = nil
            } else if problem.isUnauthorized {
                failure = .unauthorized(problem.message)
            } else if problem.isNotFound {
                failure = .notFound(problem.message)
            } else if problem == .missingToken {
                failure = whyNoToken()
            } else {
                failure = .other(problem.message)
            }
            isLoading = false
        }
    }

    /// What was finished today. Failing here only hides the done/ section; it never blocks the list.
    private static func finishedToday(_ client: NotionClient, since: Date, today: Day) async -> (tasks: [NotionPage], steps: [NotionPage]) {
        do {
            return try await client.finished(since: since, today: today)
        } catch {
            Log.write("finished-today query failed: \(describe(error))")
            return ([], [])
        }
    }

    private func apply(tasks taskPages: [NotionPage], steps stepPages: [NotionPage],
                       done: (tasks: [NotionPage], steps: [NotionPage])) {
        let rightNow = Date()
        hidden = hidden.filter { $0.value > rightNow }

        let built = ItemBuilder.build(tasks: taskPages, steps: stepPages,
                                      planByCompletionDate: settings.planByCompletionDate)
        tasks = built.tasks.filter { hidden[$0.id] == nil }
        steps = built.steps.filter { hidden[$0.id] == nil }

        // Finished today: what Notion reports, plus anything just ticked here that Notion hasn't listed yet.
        var names: [String: String] = [:]
        for page in taskPages + done.tasks {
            names[page.id] = page.title(preferring: "Task name")
        }
        var fresh: [Item] = []
        for (index, page) in done.steps.enumerated() {
            var item = ItemBuilder.step(from: page, order: index)
            item.parentName = item.parentID.flatMap { names[$0] } ?? ""
            fresh.append(item)
        }
        for (index, page) in done.tasks.enumerated() {
            fresh.append(ItemBuilder.task(from: page, order: done.steps.count + index))
        }
        let reported = Set(fresh.map(\.id))
        let stillOpen = Set(tasks.map(\.id) + steps.map(\.id))
        let pending = finished.filter { hidden[$0.id] != nil && !reported.contains($0.id) && !stillOpen.contains($0.id) }
        finished = pending + fresh.filter { !stillOpen.contains($0.id) }

        rebuild()
    }

    /// Shows the last list that loaded, straight away, while the first fetch is still running.
    private func restoreFromCache() {
        guard let file = cache?.load() else { return }
        let sameDay = Day(file.savedAt) == Day(now)
        apply(tasks: file.tasks, steps: file.steps,
              done: sameDay ? (file.doneTasks, file.doneSteps) : ([], []))
        hasData = true
        lastUpdated = file.savedAt
    }

    /// The time zone changed: work the days out again from the saved pages.
    private func reparse() {
        tick()
        if let file = cache?.load() {
            apply(tasks: file.tasks, steps: file.steps, done: (file.doneTasks, file.doneSteps))
        }
    }

    // MARK: Marking done

    /// Marks a step or task done: the row is ticked, slides away, and Notion is updated.
    /// If Notion refuses, the row comes back and an error is shown.
    func markDone(_ item: Item) {
        guard !completing.contains(item.id) else { return }
        guard let client = makeClient() else {
            show(.error, "no token yet")
            return
        }
        completing.insert(item.id)
        writesInFlight += 1

        Task {
            // Let the tick and strike-through play before the row leaves.
            if motion { try? await Task.sleep(nanoseconds: 420_000_000) }

            let removedSteps = item.kind == .task ? steps.filter { $0.parentID == item.id } : []
            let expiry = Date().addingTimeInterval(12)
            hidden[item.id] = expiry
            for step in removedSteps { hidden[step.id] = expiry }

            animate(motion, .easeIn(duration: 0.3)) {
                remove(item, with: removedSteps)
                var done = item
                done.status = "Done"
                finished.insert(done, at: 0)
                completing.remove(item.id)
                rebuild()
            }
            events.send(.markedDone)

            do {
                let receipt = try await client.markDone(item, today: Day(clock()))
                Log.write("marked done: \(item.kind.rawValue) \(item.id)" + (receipt.cascaded.isEmpty ? "" : " + \(receipt.cascaded.count) steps")
                          + (receipt.cascadeFailure.map { " (steps failed: \($0))" } ?? ""))
                undo = Undo(receipt: receipt, steps: removedSteps)
                if let problem = receipt.cascadeFailure {
                    show(.error, "task done, but some steps weren't: \(problem)")
                } else {
                    show(.done, "done · \(item.name)", canUndo: true)
                }
            } catch {
                hidden[item.id] = nil
                for step in removedSteps { hidden[step.id] = nil }
                animate(motion) {
                    restore(item, with: removedSteps)
                    rebuild()
                }
                Log.write("mark done failed: \(item.kind.rawValue) \(item.id): \(TaskStore.describe(error))")
                show(.error, "couldn't mark done · \(TaskStore.describe(error))")
                events.send(.markFailed)
            }
            writeFinished()
        }
    }

    /// Takes back the last mark-done.
    func undoLast() {
        guard let undo, let client = makeClient() else { return }
        self.undo = nil
        dismissToast()
        writesInFlight += 1

        let item = undo.receipt.item
        hidden[item.id] = nil
        for step in undo.steps { hidden[step.id] = nil }
        animate(motion) {
            restore(item, with: undo.steps)
            rebuild()
        }

        Task {
            do {
                try await client.undo(undo.receipt)
                Log.write("undone: \(item.kind.rawValue) \(item.id)")
                show(.info, "undone · \(item.name)")
            } catch {
                Log.write("undo failed: \(item.id): \(TaskStore.describe(error))")
                show(.error, "couldn't undo · \(TaskStore.describe(error))")
            }
            writeFinished()
        }
    }

    /// Reopens something from the done/ list.
    func reopen(_ item: Item) {
        guard let client = makeClient() else { return }
        writesInFlight += 1
        hidden[item.id] = nil
        var open = item
        open.status = "Not started"
        animate(motion) {
            restore(open, with: [])
            rebuild()
        }
        Task {
            do {
                try await client.reopen(item)
                Log.write("reopened: \(item.kind.rawValue) \(item.id)")
                show(.info, "reopened · \(item.name)")
            } catch {
                Log.write("reopen failed: \(item.id): \(TaskStore.describe(error))")
                animate(motion) {
                    remove(open, with: [])
                    finished.insert(item, at: 0)
                    rebuild()
                }
                show(.error, "couldn't reopen · \(TaskStore.describe(error))")
            }
            writeFinished()
        }
    }

    private func remove(_ item: Item, with extraSteps: [Item]) {
        let gone = Set([item.id] + extraSteps.map(\.id))
        tasks.removeAll { gone.contains($0.id) }
        steps.removeAll { gone.contains($0.id) }
    }

    private func restore(_ item: Item, with extraSteps: [Item]) {
        finished.removeAll { $0.id == item.id }
        for restored in [item] + extraSteps {
            switch restored.kind {
            case .task:
                if !tasks.contains(where: { $0.id == restored.id }) { tasks.append(restored) }
            case .step:
                if !steps.contains(where: { $0.id == restored.id }) { steps.append(restored) }
            }
        }
        // Back to Notion's order (soonest due first), which is what the sort treats as the tie-breaker.
        tasks = Schedule.sorted(tasks)
        steps = Schedule.sorted(steps)
    }

    // MARK: Other edits

    /// Moves the due date to another day, keeping the time of day (and the length, for a range).
    func reschedule(_ item: Item, to day: Day) {
        let moved: Due?
        if let due = item.due {
            moved = due.shifted(days: due.start.days(to: day))
        } else {
            moved = Due(start: day.iso, end: nil)
        }
        guard let moved, moved != item.due else { return }
        // With "show tasks on their completion date" on, moving a task moves the day it's planned for
        // and leaves its deadline alone.
        let planning = settings.planByCompletionDate && item.kind == .task
        edit(item, change: {
            if planning, !$0.isPlanned {
                $0.deadline = $0.due
                $0.isPlanned = true
            }
            $0.due = moved
        }, failure: "couldn't move") { client in
            try await client.setDate(pageID: item.id, property: planning ? "Completion date" : "Due date",
                                     start: moved.rawStart, end: moved.rawEnd)
        }
        show(.info, "moved to \(Schedule.whenLabel(moved, today: Day(now))) · \(item.name)")
    }

    /// Switches between `Not started` and `In progress`.
    func setInProgress(_ item: Item, _ inProgress: Bool) {
        let status = inProgress ? "In progress" : "Not started"
        guard item.status != status else { return }
        edit(item, change: { $0.status = status }, failure: "couldn't update") { client in
            try await client.setStatus(pageID: item.id, to: status)
        }
    }

    /// Adds a task typed into the prompt.
    func add(_ draft: QuickAddDraft) {
        guard draft.isValid else { return }
        guard let client = makeClient() else {
            show(.error, "no token yet")
            return
        }
        writesInFlight += 1
        show(.info, "creating · \(draft.title)")
        Task {
            do {
                try await client.createTask(title: draft.title, due: draft.dueString,
                                            types: draft.types, priority: draft.priority)
                Log.write("created a task (due \(draft.dueString ?? "none"))")
                show(.done, "created · \(draft.title)")
            } catch {
                Log.write("create failed: \(TaskStore.describe(error))")
                show(.error, "couldn't create · \(TaskStore.describe(error))")
            }
            writeFinished(refreshAfter: 0.4)
        }
    }

    /// Adds a step to a task, typed into the prompt after `$ add-step`.
    func addStep(_ draft: QuickAddDraft, to task: Item) {
        guard draft.isValid else { return }
        guard let client = makeClient() else {
            show(.error, "no token yet")
            return
        }
        writesInFlight += 1
        show(.info, "creating · \(draft.title)")
        Task {
            do {
                try await client.createStep(title: draft.title, due: draft.dueString,
                                            stepType: draft.stepType, parentID: task.id)
                Log.write("created a step under \(task.id) (due \(draft.dueString ?? "none"))")
                show(.done, "step added · \(draft.title)")
            } catch {
                Log.write("create step failed: \(TaskStore.describe(error))")
                show(.error, "couldn't add the step · \(TaskStore.describe(error))")
            }
            writeFinished(refreshAfter: 0.4)
        }
    }

    /// Changes a row here first, then in Notion; puts it back if Notion refuses.
    private func edit(_ item: Item, change: (inout Item) -> Void, failure: String,
                      send: @escaping (NotionClient) async throws -> Void) {
        guard let client = makeClient() else {
            show(.error, "no token yet")
            return
        }
        writesInFlight += 1
        animate(motion) {
            replace(item.id) { change(&$0) }
            rebuild()
        }
        Task {
            do {
                try await send(client)
                Log.write("edited: \(item.kind.rawValue) \(item.id)")
            } catch {
                Log.write("edit failed (\(failure)): \(item.id): \(TaskStore.describe(error))")
                animate(motion) {
                    replace(item.id) { $0 = item }
                    rebuild()
                }
                show(.error, "\(failure) · \(TaskStore.describe(error))")
            }
            writeFinished()
        }
    }

    private func replace(_ id: String, _ change: (inout Item) -> Void) {
        if let index = tasks.firstIndex(where: { $0.id == id }) { change(&tasks[index]) }
        if let index = steps.firstIndex(where: { $0.id == id }) { change(&steps[index]) }
    }

    private func writeFinished(refreshAfter delay: Double = 1.5) {
        writesInFlight = max(0, writesInFlight - 1)
        guard writesInFlight == 0 else { return }
        refreshWhenWritesFinish = false
        guard refreshesAfterWrites else { return }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await refresh()
        }
    }

    // MARK: Toasts

    func show(_ kind: Toast.Kind, _ text: String, canUndo: Bool = false) {
        let next = Toast(kind: kind, text: text, canUndo: canUndo)
        animate(motion) { toast = next }
        toastTimer?.cancel()
        toastTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((kind == .error ? 7 : 5) * 1_000_000_000))
            guard !Task.isCancelled, let self, self.toast?.id == next.id else { return }
            self.dismissToast()
        }
    }

    func dismissToast() {
        toastTimer?.cancel()
        animate(motion) { toast = nil }
    }

    private static func describe(_ error: Error) -> String {
        (error as? NotionError)?.message ?? error.localizedDescription
    }
}

/// The last list that loaded, saved to disk so the panel has something to show at launch and offline.
struct Cache {
    struct File: Codable, Sendable {
        var savedAt: Date
        var tasks: [NotionPage]
        var steps: [NotionPage]
        var doneTasks: [NotionPage]
        var doneSteps: [NotionPage]
    }

    let url: URL

    /// `~/Library/Application Support/NotionBar/cache.json`
    static var standard: Cache {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return Cache(url: base.appendingPathComponent("NotionBar/cache.json"))
    }

    func load() -> File? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(File.self, from: data)
    }

    func save(_ file: File) {
        let url = url
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(file) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }
}
