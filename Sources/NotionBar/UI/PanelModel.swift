import AppKit
import Combine
import SwiftUI

/// What the panel is doing right now: what's typed in the prompt, which row the keyboard is on,
/// what's folded open, whether ⌥ is held. (What's *in* the list lives in `TaskStore`.)
@MainActor
final class PanelModel: ObservableObject {
    /// Drives the open and close animation.
    @Published private(set) var isPresented = false
    /// Goes up by one every time the panel opens, so rows can replay their entrance.
    @Published private(set) var presentCount = 0
    /// ⌥ is down: every row turns into `[x] name` and a click marks it done.
    @Published var optionHeld = false
    /// The prompt. Plain text filters the list; text starting with `+` adds a task.
    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            selection = nil
            // Deleting the "+" backs out of adding a step.
            if !QuickAdd.isAddCommand(query), addStepParent != nil { addStepParent = nil }
        }
    }
    /// The row the arrow keys are on.
    @Published var selection: String?
    /// A day picked in the week strip: only what's due that day is shown.
    @Published var dayFilter: Day?
    /// Pinned open: the panel stays up while you work in other apps, until you unpin or press esc.
    @Published var isPinned = false
    /// Set after `$ add-step`: the next thing typed after `+` becomes a step of this task.
    @Published var addStepParent: Item?
    /// Goes up by one when the last thing due is ticked off, to set off the little celebration.
    @Published private(set) var celebration = 0
    @Published var expandedTasks: Set<String> = []
    /// Tallest the card may get before the list scrolls.
    @Published var maxHeight: CGFloat = 600
    /// Draw an opaque background (used when rendering to an image, where there's no blur).
    @Published var solidBackground = false
    /// How tall the card is right now. Not published: it's only read when a click needs hit-testing.
    var cardHeight: CGFloat = 0

    let store: TaskStore
    let settings: AppSettings
    let focus: FocusTimer
    /// Where the footer's `$ open task-tracker` and `$ open steps` point. Set by the app delegate.
    var config: () -> NotionConfig = { .sample }

    /// Opens a Notion link. Swapped out by the debug driver so click tests don't launch Notion.
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }

    // Set by the app delegate.
    var close: () -> Void = {}
    var openSettings: () -> Void = {}
    var quit: () -> Void = {}

    private var settingsChanges: AnyCancellable?
    private var doneEvents: AnyCancellable?

    init(store: TaskStore, settings: AppSettings, focus: FocusTimer) {
        self.store = store
        self.settings = settings
        self.focus = focus
        // Some of what this model reports comes from Settings (whether tasks/ and done/ are open).
        // Views watch this model, not Settings, so pass every settings change on: without this,
        // clicking a folder flipped the setting but nothing redrew.
        settingsChanges = settings.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        // Ticking off the last thing that was due deserves a moment.
        doneEvents = store.events.sink { [weak self] event in
            guard let self, case .markedDone = event, self.store.board.count == 0 else { return }
            self.celebration += 1
        }
    }

    // MARK: Showing and hiding

    func willPresent() {
        selection = nil
        presentCount += 1
        isPresented = true
    }

    /// The panel has started closing: play the exit.
    func willDismiss() {
        isPresented = false
        optionHeld = false
    }

    /// The panel is off screen: reset it for next time.
    func didDismiss() {
        isPresented = false
        optionHeld = false
        query = ""
        selection = nil
        dayFilter = nil
        addStepParent = nil
        isPinned = false
    }

    // MARK: Prompt

    var isAdding: Bool { QuickAdd.isAddCommand(query) }
    var isSearching: Bool { !isAdding && !query.trimmingCharacters(in: .whitespaces).isEmpty }
    /// Something is narrowing the list: text in the prompt, or a day picked in the week strip.
    var isFiltering: Bool { isSearching || dayFilter != nil }
    var filterText: String { isSearching ? query : "" }
    var draft: QuickAddDraft? { isAdding ? QuickAdd.parse(query) : nil }

    /// The board, narrowed by the prompt and the picked day.
    var visibleBoard: Board { store.board.filtered(by: filterText, day: dayFilter) }

    var visibleFinished: [Item] {
        // What's finished belongs to today, so it's hidden while looking at another day.
        if let dayFilter, dayFilter != store.board.today { return [] }
        let words = Board.words(in: filterText)
        return words.isEmpty ? store.finished : store.finished.filter { Board.matches($0, words) }
    }

    /// `today`, `tomorrow`, `thursday`: the picked day in words.
    var dayFilterLabel: String? {
        dayFilter.flatMap { Due(start: $0.iso, end: nil) }.map { Schedule.whenLabel($0, today: store.board.today) }
    }

    func toggleDay(_ day: Day) {
        animate(settings.motion) {
            dayFilter = dayFilter == day ? nil : day
            selection = nil
        }
    }

    func togglePin() {
        animate(settings.motion, .snappy(duration: 0.2)) { isPinned.toggle() }
    }

    /// `$ add-step` on a task: the prompt now adds a step to it.
    func beginAddStep(_ task: Item) {
        addStepParent = task
        query = "+ "
    }

    /// `tasks/` is open when you opened it, and always while filtering (so matches are visible).
    var tasksOpen: Bool { settings.tasksExpanded || isFiltering }
    var doneOpen: Bool { settings.doneExpanded || isFiltering }

    /// A task is unfolded when you unfolded it, and always while searching (the match may be one of its steps).
    func isTaskOpen(_ group: Board.TaskGroup) -> Bool {
        expandedTasks.contains(group.id) || isSearching
    }

    func toggleTasks() {
        animate(settings.motion) { settings.tasksExpanded.toggle() }
    }

    func toggleDone() {
        animate(settings.motion) { settings.doneExpanded.toggle() }
    }

    func toggle(_ group: Board.TaskGroup) {
        animate(settings.motion) {
            if expandedTasks.contains(group.id) {
                expandedTasks.remove(group.id)
            } else {
                expandedTasks.insert(group.id)
            }
        }
    }

    // MARK: Opening things

    func pageURL(_ id: String) -> URL {
        let compact = id.replacingOccurrences(of: "-", with: "")
        let web = URL(string: "https://www.notion.so/" + compact)!
        guard settings.openInApp, let app = URL(string: "notion://www.notion.so/" + compact),
              NSWorkspace.shared.urlForApplication(toOpen: app) != nil else { return web }
        return app
    }

    func open(_ item: Item) {
        openPage(item.id)
    }

    func openPage(_ id: String) {
        openURL(pageURL(id))
        // A pinned panel stays put: that's what the pin is for.
        if !isPinned { close() }
    }

    func copyLink(_ item: Item) {
        let compact = item.id.replacingOccurrences(of: "-", with: "")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("https://www.notion.so/" + compact, forType: .string)
        store.show(.info, "link copied")
    }

    /// A click on a row: open it, or mark it done when ⌥ is held.
    func click(_ item: Item) {
        if optionHeld {
            store.markDone(item)
        } else {
            open(item)
        }
    }

    func submitDraft() {
        guard let draft, draft.isValid else { return }
        if let parent = addStepParent {
            store.addStep(draft, to: parent)
        } else {
            store.add(draft)
        }
        addStepParent = nil
        query = ""
    }

    // MARK: Keyboard

    static let tasksFolderID = "folder|tasks"
    static let doneFolderID = "folder|done"

    /// Every row the arrow keys can land on, top to bottom, as currently shown.
    var navigationOrder: [String] {
        guard store.failure == nil, store.hasData else { return [] }
        let board = visibleBoard
        var ids = board.overdue.map(\.id) + board.dueToday.map(\.id) + board.upcoming.map(\.id)
        ids.append(PanelModel.tasksFolderID)
        if tasksOpen {
            for group in board.tasks {
                ids.append(group.id)
                if isTaskOpen(group) { ids += group.steps.map(\.id) }
            }
        }
        let finished = visibleFinished
        if !finished.isEmpty {
            ids.append(PanelModel.doneFolderID)
            if doneOpen { ids += finished.map { "done|" + $0.id } }
        }
        return ids
    }

    private func moveSelection(_ delta: Int) {
        let order = navigationOrder
        guard !order.isEmpty else { return }
        guard let current = selection, let index = order.firstIndex(of: current) else {
            selection = delta > 0 ? order.first : order.last
            return
        }
        selection = order[min(max(index + delta, 0), order.count - 1)]
    }

    private func group(for id: String) -> Board.TaskGroup? {
        visibleBoard.tasks.first { $0.id == id }
    }

    /// The unfinished item behind a row id.
    private func item(for id: String) -> Item? {
        let board = visibleBoard
        if let row = (board.overdue + board.dueToday + board.upcoming).first(where: { $0.id == id }) { return row.item }
        if let group = group(for: id) { return group.task }
        return board.tasks.flatMap(\.steps).first { $0.id == id }?.item
    }

    private func activateSelection() {
        // With a filter typed and nothing selected, Return goes to the first match.
        guard let id = selection ?? (isSearching ? navigationOrder.first { !$0.hasPrefix("folder|") } : nil) else { return }
        if id == PanelModel.tasksFolderID { return toggleTasks() }
        if id == PanelModel.doneFolderID { return toggleDone() }
        if id.hasPrefix("done|") {
            if let item = store.finished.first(where: { "done|" + $0.id == id }) { open(item) }
            return
        }
        if let group = group(for: id), !isSearching { return toggle(group) }
        if let item = item(for: id) { click(item) }
    }

    private func markSelectionDone() {
        guard let id = selection, let item = item(for: id) else { return }
        // Move to the neighbour first so the keyboard isn't left on a row that's leaving.
        let order = navigationOrder
        if let index = order.firstIndex(of: id) {
            selection = index + 1 < order.count ? order[index + 1] : (index > 0 ? order[index - 1] : nil)
        }
        store.markDone(item)
    }

    /// Handles a key press while the panel is open. Returns true when the key was used.
    func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command)
        let control = flags.contains(.control)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

        switch event.keyCode {
        case 53:   // esc: clear what was typed, then the picked day, then close
            if !query.isEmpty {
                query = ""
            } else if dayFilter != nil {
                dayFilter = nil
            } else {
                isPinned = false
                close()
            }
            return true
        case 125:  // ↓
            moveSelection(1)
            return true
        case 126:  // ↑
            moveSelection(-1)
            return true
        case 36, 76:  // return, enter
            if isAdding {
                submitDraft()
            } else if command {
                markSelectionDone()
            } else {
                activateSelection()
            }
            return true
        case 124, 123:  // → ←
            // Only when nothing is typed, so the arrows still move the cursor in the prompt.
            guard query.isEmpty, let id = selection else { return false }
            let open = event.keyCode == 124
            if id == PanelModel.tasksFolderID {
                if tasksOpen != open { toggleTasks() }
            } else if id == PanelModel.doneFolderID {
                if doneOpen != open { toggleDone() }
            } else if let group = group(for: id) {
                if isTaskOpen(group) != open { toggle(group) }
            } else {
                return false
            }
            return true
        default:
            break
        }

        if control, key == "n" { moveSelection(1); return true }
        if control, key == "p" { moveSelection(-1); return true }

        guard command else { return false }
        // A menu-bar-only app has no visible Edit menu, so route the editing shortcuts by hand.
        let editing: [String: Selector] = [
            "v": #selector(NSText.paste(_:)), "c": #selector(NSText.copy(_:)),
            "x": #selector(NSText.cut(_:)), "a": #selector(NSText.selectAll(_:)),
        ]
        if let action = editing[key] {
            return NSApp.sendAction(action, to: nil, from: nil)
        }
        switch key {
        case "r":
            Task { await store.refresh() }
            return true
        case ",":
            openSettings()
            return true
        case "q":
            quit()
            return true
        case "n":
            query = "+ "
            return true
        case "p":
            togglePin()
            return true
        case "d":
            markSelectionDone()
            return true
        case "z" where query.isEmpty && store.canUndo:
            store.undoLast()
            return true
        default:
            return false
        }
    }

    // MARK: Snoozing

    struct SnoozeOption: Identifiable {
        let id: String
        let label: String
        let day: Day
    }

    /// Where a row can be moved to from its right-click menu.
    func snoozeOptions() -> [SnoozeOption] {
        let today = store.board.today
        // Days until next Monday (1 = Sunday … 7 = Saturday).
        let untilMonday = (9 - today.weekday) % 7 == 0 ? 7 : (9 - today.weekday) % 7
        return [
            SnoozeOption(id: "today", label: "today", day: today),
            SnoozeOption(id: "tomorrow", label: "tomorrow", day: today.adding(1)),
            SnoozeOption(id: "2d", label: "in 2 days", day: today.adding(2)),
            SnoozeOption(id: "monday", label: "next monday", day: today.adding(untilMonday)),
            SnoozeOption(id: "week", label: "in a week", day: today.adding(7)),
        ]
    }
}
