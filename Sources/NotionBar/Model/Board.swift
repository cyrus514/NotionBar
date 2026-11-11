import Foundation

/// Which section an item's due date puts it in. Port of `bucket` in the plugin.
enum Bucket: String {
    case none      // no due date
    case overdue   // ended before today
    case today     // start ≤ today ≤ end
    case soon      // starts within the next 7 days
    case later
}

/// How a row is coloured.
enum RowState: String {
    case normal
    case overdue   // red
    case late      // orange: due today, and its time has passed
}

/// The date rules, ported one-for-one from `notion-tasks.py`.
enum Schedule {
    /// How far ahead the "upcoming" section looks.
    static let upcomingDays = 7
    /// Most rows shown under "upcoming" before "… N more".
    static let maxUpcoming = 12

    static func bucket(_ due: Due?, today: Day) -> Bucket {
        guard let due else { return .none }
        if due.end < today { return .overdue }
        if due.start <= today && today <= due.end { return .today }
        if due.start <= today.adding(upcomingDays) { return .soon }
        return .later
    }

    /// `7:30 am`
    static func clock(_ date: Date) -> String {
        clockFormatter.string(from: date).lowercased()
    }

    /// Relative date label, lowercase: `7:30 am`, `tomorrow, 7:30 am`, `yesterday, 6:00 pm`,
    /// `thursday`, `nov 7, 7:00 pm`. Port of `when_label`.
    static func whenLabel(_ due: Due?, today: Day, bareToday: Bool = false) -> String {
        guard let due else { return "no date" }
        let d = due.start
        let day: String
        if d == today {
            day = bareToday ? "" : "today"
        } else if d == today.adding(1) {
            day = "tomorrow"
        } else if d == today.adding(-1) {
            day = "yesterday"
        } else if today < d && d < today.adding(7) {
            day = weekdayFormatter.string(from: d.noon).lowercased()
        } else {
            day = monthFormatter.string(from: d.noon).lowercased() + " \(d.day)"
        }
        if let time = due.time {
            return day.isEmpty ? clock(time) : "\(day), \(clock(time))"
        }
        return day.isEmpty ? "today" : day
    }

    /// `tue`
    static func shortWeekday(_ day: Day) -> String {
        shortWeekdayFormatter.string(from: day.noon).lowercased()
    }

    /// `today · tue nov 10`
    static func todayHeader(_ today: Day) -> String {
        let weekday = shortWeekdayFormatter.string(from: today.noon).lowercased()
        let month = monthFormatter.string(from: today.noon).lowercased()
        return "today · \(weekday) \(month) \(today.day)"
    }

    /// Due date, then time. Items with no time sort after timed ones on the same day,
    /// items with no date sort last. Ties keep Notion's order (a stable sort, like Python's).
    static func sorted(_ items: [Item]) -> [Item] {
        items.enumerated().sorted { a, b in
            let ka = sortKey(a.element), kb = sortKey(b.element)
            if ka.day != kb.day { return ka.day < kb.day }
            if ka.seconds != kb.seconds { return ka.seconds < kb.seconds }
            return a.offset < b.offset
        }.map(\.element)
    }

    private static let endOfTime = Day(year: 9999, month: 12, day: 31)

    private static func sortKey(_ item: Item) -> (day: Day, seconds: Double) {
        guard let due = item.due else { return (endOfTime, .infinity) }
        guard let time = due.time else { return (due.start, .infinity) }
        let c = Day.calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: time)
        let seconds = Double((c.hour ?? 0) * 3600 + (c.minute ?? 0) * 60 + (c.second ?? 0))
            + Double(c.nanosecond ?? 0) / 1_000_000_000
        return (due.start, seconds)
    }

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.calendar = Day.calendar
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .autoupdatingCurrent
        f.dateFormat = format
        return f
    }

    private static let clockFormatter = formatter("h:mm a")
    private static let weekdayFormatter = formatter("EEEE")
    private static let shortWeekdayFormatter = formatter("EEE")
    private static let monthFormatter = formatter("MMM")
}

/// Everything the panel shows, worked out from the unfinished items and the current time.
/// Port of `render` in the plugin, minus the drawing.
struct Board: Equatable {
    /// One item as it appears in a section.
    struct Row: Identifiable, Equatable {
        /// Unique across the panel: an item can appear in a section and again under its task.
        let id: String
        let item: Item
        let state: RowState
        /// The pieces of the `└` line, joined with ` · ` when drawn.
        let detail: [String]
        /// A short note on how urgent it is: `3d late`, `2h late`, `in 45m`. Nil when there's nothing to add.
        var badge: String?

        var detailText: String { detail.joined(separator: " · ") }
    }

    /// One day of the week-ahead strip.
    struct DayLoad: Identifiable, Equatable {
        let day: Day
        /// Tasks and steps that start that day.
        let count: Int
        var id: Day { day }
    }

    /// A task under `tasks/`, with its unfinished steps.
    struct TaskGroup: Identifiable, Equatable {
        let id: String
        let task: Item
        let state: RowState
        /// `due tomorrow · 4 steps`
        let detail: [String]
        let steps: [Row]
        /// Steps already finished, out of `totalSteps`.
        let doneSteps: Int
        let totalSteps: Int

        var detailText: String { detail.joined(separator: " · ") }
    }

    var today: Day
    var header: String
    var overdue: [Row] = []
    var dueToday: [Row] = []
    var upcoming: [Row] = []
    /// Upcoming steps beyond the first `Schedule.maxUpcoming`.
    var upcomingHidden = 0
    var tasks: [TaskGroup] = []
    /// Today and the six days after it, with how much is due on each.
    var week: [DayLoad] = []
    /// The next timed item that hasn't come due yet, for the menu bar countdown.
    var nextDue: Date?
    var nextDueName: String = ""

    /// The number next to the menu bar icon.
    var count: Int { overdue.count + dueToday.count }
    var hasOverdue: Bool { !overdue.isEmpty }
    var lateCount: Int { dueToday.filter { $0.state == .late }.count }
    var isEmpty: Bool { overdue.isEmpty && dueToday.isEmpty && upcoming.isEmpty && tasks.isEmpty }

    static func empty(now: Date = Date()) -> Board {
        let today = Day(now)
        return Board(today: today, header: Schedule.todayHeader(today))
    }

    static func build(tasks: [Item], steps: [Item], now: Date) -> Board {
        let today = Day(now)
        var board = Board(today: today, header: Schedule.todayHeader(today))
        let everything = tasks + steps

        board.overdue = Schedule.sorted(everything.filter { Schedule.bucket($0.due, today: today) == .overdue })
            .map { row($0, section: "overdue", today: today, now: now, state: .overdue) }

        board.dueToday = Schedule.sorted(everything.filter { Schedule.bucket($0.due, today: today) == .today })
            .map { item in
                let late = item.due?.time.map { $0 < now } ?? false
                return row(item, section: "today", today: today, now: now, state: late ? .late : .normal, bareToday: true)
            }

        // Only steps go under "upcoming".
        let soon = Schedule.sorted(steps.filter { Schedule.bucket($0.due, today: today) == .soon })
        board.upcoming = soon.prefix(Schedule.maxUpcoming)
            .map { row($0, section: "upcoming", today: today, now: now, state: .normal) }
        board.upcomingHidden = max(0, soon.count - Schedule.maxUpcoming)

        board.tasks = Schedule.sorted(tasks).map { task in
            let own = Schedule.sorted(steps.filter { $0.parentID == task.id })
            let state: RowState = Schedule.bucket(task.due, today: today) == .overdue ? .overdue : .normal
            var detail = [task.due == nil ? "no due date"
                          : (task.isPlanned ? "planned " : "due ") + Schedule.whenLabel(task.due, today: today)]
            if task.isPlanned, let deadline = task.deadline {
                detail.append("due " + Schedule.whenLabel(deadline, today: today))
            }
            if !own.isEmpty {
                detail.append("\(own.count) step\(own.count == 1 ? "" : "s")")
            }
            let total = max(task.relatedStepCount, own.count)
            return TaskGroup(
                id: "task|" + task.id,
                task: task,
                state: state,
                detail: detail,
                steps: own.map { step in
                    let bucket = Schedule.bucket(step.due, today: today)
                    var stepState: RowState = bucket == .overdue ? .overdue : .normal
                    if bucket == .today, let time = step.due?.time, time < now { stepState = .late }
                    return row(step, section: "task|" + task.id, today: today, now: now, state: stepState, context: false)
                },
                doneSteps: total - own.count,
                totalSteps: total
            )
        }

        board.week = (0..<7).map { offset in
            let day = today.adding(offset)
            return DayLoad(day: day, count: everything.filter { $0.due?.start == day }.count)
        }

        if let next = everything
            .compactMap({ item in item.due?.time.map { (time: $0, name: item.name) } })
            .filter({ $0.time > now })
            .min(by: { $0.time < $1.time }) {
            board.nextDue = next.time
            board.nextDueName = next.name
        }
        return board
    }

    /// Title line + `└` detail line for one item. Port of `item` in the plugin.
    private static func row(_ item: Item, section: String, today: Day, now: Date, state: RowState,
                            context: Bool = true, bareToday: Bool = false) -> Row {
        var detail = [Schedule.whenLabel(item.due, today: today, bareToday: bareToday)]
        switch item.kind {
        case .step:
            if !item.stepType.isEmpty { detail.append(item.stepType.lowercased()) }
            if context && !item.parentName.isEmpty { detail.append(item.parentName) }
        case .task:
            if !item.types.isEmpty { detail.append(item.types.joined(separator: ", ")) }
            // Shown on its planned day: say when it's actually due.
            if item.isPlanned, let deadline = item.deadline {
                detail.append("due " + Schedule.whenLabel(deadline, today: today))
            }
        }
        if item.isInProgress { detail.append("in progress") }
        // An overdue step listed with its task's name already has a full line (and its date says
        // how late it is), so the badge is kept for rows with room: today's timed rows, tasks,
        // and steps shown under their task.
        let crowded = state == .overdue && item.kind == .step && context && !item.parentName.isEmpty
        return Row(id: section + "|" + item.id, item: item, state: state, detail: detail,
                   badge: crowded ? nil : badge(item.due, today: today, now: now))
    }

    /// `3d late` for something overdue, `2h late` or `in 45m` for something timed today.
    static func badge(_ due: Due?, today: Day, now: Date) -> String? {
        guard let due else { return nil }
        if due.end < today {
            return "\(due.end.days(to: today))d late"
        }
        guard due.start == today, let time = due.time else { return nil }
        let seconds = time.timeIntervalSince(now)
        if seconds > 0 { return "in " + span(Int((seconds / 60).rounded(.up))) }
        // How late matters less to the minute than how soon: whole hours once it's past one.
        let late = Int((-seconds / 60).rounded(.down))
        if late == 0 { return "now" }
        return (late < 60 ? "\(late)m" : "\(late / 60)h") + " late"
    }

    /// `45m`, `1h 20m`, `5h`
    static func span(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60, rest = minutes % 60
        // Three hours or more away: the nearest hour is plenty.
        if hours >= 3 { return "\((minutes + 30) / 60)h" }
        return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
    }

    // MARK: Filtering (the prompt at the top of the panel)

    /// Keeps only rows that match every word typed and, when a day is picked in the week strip,
    /// that are due that day. With nothing typed and no day picked, the board comes back unchanged.
    func filtered(by query: String, day: Day? = nil) -> Board {
        let words = Board.words(in: query)
        guard !words.isEmpty || day != nil else { return self }
        func keep(_ item: Item) -> Bool {
            if let day, item.due?.start != day { return false }
            return Board.matches(item, words)
        }
        var out = self
        out.overdue = overdue.filter { keep($0.item) }
        out.dueToday = dueToday.filter { keep($0.item) }
        out.upcoming = upcoming.filter { keep($0.item) }
        out.upcomingHidden = 0
        out.tasks = tasks.compactMap { group in
            if keep(group.task) { return group }
            let steps = group.steps.filter { keep($0.item) }
            guard !steps.isEmpty else { return nil }
            return TaskGroup(id: group.id, task: group.task, state: group.state, detail: group.detail,
                             steps: steps, doneSteps: group.doneSteps, totalSteps: group.totalSteps)
        }
        return out
    }

    static func words(in query: String) -> [String] {
        query.lowercased().split(whereSeparator: { $0 == " " }).map(String.init)
    }

    static func matches(_ item: Item, _ words: [String]) -> Bool {
        let haystack = ([item.name, item.parentName, item.stepType, item.status] + item.types)
            .joined(separator: " ").lowercased()
        return words.allSatisfy { haystack.contains($0) }
    }
}
