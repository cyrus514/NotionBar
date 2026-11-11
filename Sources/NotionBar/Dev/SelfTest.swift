import Foundation

/// `NotionBar --selftest`: checks the date rules, the Notion calls and the store against
/// the bundled fixtures, with no network and no token. Exits 0 when everything passes.
@MainActor
enum SelfTest {
    private static var passed = 0
    private static var failed = 0

    static func runAndExit() -> Never {
        // The fixtures were captured in Eastern time; pin it so the checks hold on any Mac.
        NSTimeZone.default = TimeZone(identifier: "America/Toronto") ?? .current
        Task { @MainActor in
            await run()
            print("\n\(passed) passed, \(failed) failed")
            exit(failed == 0 ? 0 : 1)
        }
        while true { RunLoop.main.run(mode: .default, before: .distantFuture) }
    }

    private static func check(_ condition: Bool, _ name: String) {
        if condition {
            passed += 1
        } else {
            failed += 1
            print("FAIL  \(name)")
        }
    }

    private static func equal<T: Equatable>(_ got: T, _ want: T, _ name: String) {
        if got == want {
            passed += 1
        } else {
            failed += 1
            print("FAIL  \(name)\n      got:  \(got)\n      want: \(want)")
        }
    }

    private static func section(_ name: String) {
        print("• \(name)")
    }

    private static func waitForWrites(_ store: TaskStore) async {
        for _ in 0..<400 where store.isWriting {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private static func due(_ start: String, _ end: String? = nil) -> Due? {
        Due(start: start, end: end)
    }

    private static func run() async {
        dates()
        labels()
        sorting()
        quickAdd()
        await fixturesBoard()
        await notionCalls()
        await storeFlows()
        token()
        if CommandLine.arguments.contains("--network") { await network() }
    }

    // MARK: Token

    /// The Keychain round trip and the first-launch import, under a throwaway account name
    /// and a temporary file, so the real token is never touched.
    private static func token() {
        section("token (keychain + first-launch import)")
        let account = "selftest-token"
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("notionbar-selftest-token")
        defer {
            Keychain.delete(account: account)
            try? FileManager.default.removeItem(at: file)
        }
        Keychain.delete(account: account)
        try? FileManager.default.removeItem(at: file)

        let empty = TokenStore(file: file, account: account)
        check(!empty.hasToken && empty.source == .none, "nothing saved and no file → no token")
        equal(Keychain.lookup(account: account), .missing, "the keychain says plainly that nothing is saved")

        try? "  ntn_selftest_from_file\n".write(to: file, atomically: true, encoding: .utf8)
        let imported = TokenStore(file: file, account: account)
        equal(imported.token, "ntn_selftest_from_file", "first launch imports the file (trimmed)")
        equal(imported.source, .importedFromFile, "…and says where it came from")
        equal(Keychain.read(account: account), "ntn_selftest_from_file", "…and it is now in the keychain")
        equal(Keychain.lookup(account: account), .found("ntn_selftest_from_file"), "…where a lookup finds it")

        try? FileManager.default.removeItem(at: file)
        let next = TokenStore(file: file, account: account)
        equal(next.source, .keychain, "next launch reads the keychain, file or no file")
        equal(next.token, "ntn_selftest_from_file", "…with the same token")

        check(next.set(" ntn_selftest_replaced "), "a new token from settings saves")
        equal(Keychain.read(account: account), "ntn_selftest_replaced", "…replacing the old one (trimmed)")
        check(next.set(""), "an empty token removes it")
        check(Keychain.read(account: account) == nil && !next.hasToken, "…from the keychain too")
    }

    /// `--selftest --network`: one real request to Notion with a made-up token.
    /// Proves the real transport works and that Notion's 401 is recognised.
    private static func network() async {
        section("network (real api.notion.com, made-up token)")
        let client = NotionClient(token: "ntn_notionbar_selftest_not_a_real_token", config: .sample)
        do {
            _ = try await client.openTasks()
            check(false, "a made-up token is rejected")
        } catch let error as NotionError {
            check(error.isUnauthorized, "notion answers 401 for a made-up token (got: \(error.message))")
        } catch {
            check(false, "unexpected error: \(error.localizedDescription)")
        }
        let result = await client.testConnection()
        equal(result.text, "your notion token isn't valid", "test connection reports it plainly")
    }

    // MARK: Date rules

    private static func dates() {
        section("dates")
        let today = Day(year: 2026, month: 11, day: 10)

        let dateOnly = NotionDate.parse("2026-11-10")
        equal(dateOnly?.day, today, "date-only parses to the day")
        check(dateOnly?.time == nil, "date-only has no time")

        let timed = NotionDate.parse("2026-11-10T19:30:00.000-05:00")
        equal(timed?.day, today, "datetime with offset parses to the local day")
        equal(timed?.time.map(Schedule.clock), "7:30 pm", "datetime keeps its local time")

        let zulu = NotionDate.parse("2026-11-11T02:00:00.000Z")
        equal(zulu?.day, today, "a Z time is converted to the local day (9 pm the day before)")
        equal(zulu?.time.map(Schedule.clock), "9:00 pm", "a Z time is converted to local time")

        let noFraction = NotionDate.parse("2026-11-10T07:30:00-05:00")
        equal(noFraction?.time.map(Schedule.clock), "7:30 am", "datetime without milliseconds")

        check(NotionDate.parse(nil) == nil && NotionDate.parse("") == nil, "empty date is nil")

        equal(today.adding(1).iso, "2026-11-11", "day arithmetic")
        equal(Day(year: 2026, month: 10, day: 31).adding(1).iso, "2026-11-01", "day arithmetic across months (and the DST change)")
        equal(today.days(to: Day(year: 2026, month: 11, day: 7)), -3, "days between")

        // Buckets
        equal(Schedule.bucket(nil, today: today), .none, "no date → none")
        equal(Schedule.bucket(due("2026-11-09"), today: today), .overdue, "yesterday → overdue")
        equal(Schedule.bucket(due("2026-11-10"), today: today), .today, "today → today")
        equal(Schedule.bucket(due("2026-11-08", "2026-11-12"), today: today), .today, "range around today → today")
        equal(Schedule.bucket(due("2026-11-05", "2026-11-09"), today: today), .overdue, "range that ended → overdue")
        equal(Schedule.bucket(due("2026-11-11"), today: today), .soon, "tomorrow → soon")
        equal(Schedule.bucket(due("2026-11-17"), today: today), .soon, "7 days out → soon")
        equal(Schedule.bucket(due("2026-11-18"), today: today), .later, "8 days out → later")

        // Moving dates
        equal(NotionDate.shift("2026-11-07", days: 4), "2026-11-11", "shift keeps a date-only value date-only")
        equal(NotionDate.shift("2026-11-07T19:00:00.000-05:00", days: 4), "2026-11-11T19:00:00.000-05:00", "shift keeps the time of day")
        equal(NotionDate.shift("2026-10-30T19:00:00.000-04:00", days: 3), "2026-11-02T19:00:00.000-05:00", "shift across DST keeps the wall-clock time")
        let range = due("2026-11-08T09:00:00.000-05:00", "2026-11-09T17:00:00.000-05:00")?.shifted(days: 2)
        equal(range?.start.iso, "2026-11-10", "shifted range start")
        equal(range?.end.iso, "2026-11-11", "shifted range end")
    }

    private static func labels() {
        section("labels")
        let today = Day(year: 2026, month: 11, day: 10)
        func label(_ start: String, bare: Bool = false) -> String {
            Schedule.whenLabel(due(start), today: today, bareToday: bare)
        }
        equal(label("2026-11-10T07:30:00.000-05:00", bare: true), "7:30 am", "today section, with a time")
        equal(label("2026-11-10", bare: true), "today", "today section, no time")
        equal(label("2026-11-10T16:00:00.000-05:00"), "today, 4:00 pm", "today outside the today section")
        equal(label("2026-11-11T07:30:00.000-05:00"), "tomorrow, 7:30 am", "tomorrow with a time")
        equal(label("2026-11-11"), "tomorrow", "tomorrow")
        equal(label("2026-11-09T18:00:00.000-05:00"), "yesterday, 6:00 pm", "yesterday with a time")
        equal(label("2026-11-12"), "thursday", "weekday within 6 days")
        equal(label("2026-11-16"), "monday", "weekday 6 days out")
        equal(label("2026-11-17"), "nov 17", "a week out uses the date")
        equal(label("2026-11-07T19:00:00.000-05:00"), "nov 7, 7:00 pm", "older date with a time")
        equal(label("2026-11-08T19:00:00.000-05:00"), "nov 8, 7:00 pm", "two days ago uses the date, like the plugin")
        equal(Schedule.whenLabel(nil, today: today), "no date", "no date")
        equal(Schedule.todayHeader(today), "today · tue nov 10", "today header")
        equal(Schedule.clock(NotionDate.parseDateTime("2026-11-10T12:05:00.000-05:00")!), "12:05 pm", "noon hour")
        equal(Schedule.clock(NotionDate.parseDateTime("2026-11-10T00:05:00.000-05:00")!), "12:05 am", "midnight hour")
    }

    private static func sorting() {
        section("sorting")
        func item(_ name: String, _ start: String?) -> Item {
            Item(id: name, kind: .step, name: name, due: start.flatMap { Due(start: $0, end: nil) }, status: "Not started")
        }
        let sorted = Schedule.sorted([
            item("no date", nil),
            item("untimed a", "2026-11-10"),
            item("late timed", "2026-11-10T20:00:00.000-05:00"),
            item("early timed", "2026-11-10T07:30:00.000-05:00"),
            item("untimed b", "2026-11-10"),
            item("day before", "2026-11-09"),
        ]).map(\.name)
        equal(sorted, ["day before", "early timed", "late timed", "untimed a", "untimed b", "no date"],
              "date, then time; untimed after timed; ties keep their order; no date last")
    }

    private static func quickAdd() {
        section("quick add")
        check(QuickAdd.isAddCommand("+ essay"), "+ starts a new task")
        check(!QuickAdd.isAddCommand("essay"), "plain text is a filter")

        let plain = QuickAdd.parse("+ read chapter 4 #hw !high")
        equal(plain.title, "read chapter 4", "title without tags")
        equal(plain.types, ["homework"], "#hw → homework")
        equal(plain.priority, "High", "!high → High")
        check(plain.day == nil && plain.dueString == nil, "no date words → no due date")

        let today = Day(Date())
        let tomorrow = QuickAdd.parse("+ math worksheet tomorrow #homework")
        equal(tomorrow.title, "math worksheet", "date words are cut from the title")
        equal(tomorrow.day, today.adding(1), "tomorrow → the next day")
        check(tomorrow.time == nil, "no time given → date only")
        equal(tomorrow.dueString, today.adding(1).iso, "date-only due string")

        let timed = QuickAdd.parse("+ essay draft due tomorrow at 5pm #project")
        equal(timed.title, "essay draft", "dangling 'due' is dropped")
        equal(timed.time.map(Schedule.clock), "5:00 pm", "time is picked up")
        equal(timed.types, ["project"], "#project")
        check(timed.dueString?.contains("T17:00:00") ?? false, "timed due string")

        check(!QuickAdd.parse("+   ").isValid, "empty title is not valid")

        let step = QuickAdd.parse("+ make cue cards #prac")
        equal(step.stepType, "Prac", "#prac sets the step type")
        equal(step.title, "make cue cards", "…and stays out of the title")
        equal(QuickAdd.parse("+ outline #prep").stepType, "Prepare", "#prep → Prepare")
    }

    // MARK: Fixtures → board

    private static func makeStore(_ fake: FakeNotion, now: Date = Fixtures.referenceNow,
                                  planByCompletionDate: Bool = false) -> TaskStore {
        let suite = "notionbar.selftest"
        UserDefaults().removePersistentDomain(forName: suite)
        let settings = AppSettings(defaults: UserDefaults(suiteName: suite) ?? .standard)
        settings.animations = false
        settings.planByCompletionDate = planByCompletionDate
        let store = TaskStore(settings: settings, clock: { now }) {
            NotionClient(token: "selftest", transport: fake, config: .sample)
        }
        store.refreshesAfterWrites = false
        return store
    }

    private static func fixturesBoard() async {
        section("fixtures → board (Tue Nov 10 2026, 9:15 am)")
        let store = makeStore(FakeNotion.fixtures())
        await store.refresh()
        let board = store.board

        check(store.failure == nil && store.hasData, "loads without an error")
        equal(board.header, "today · tue nov 10", "header")
        equal(board.overdue.map(\.item.name), [
            "Do the study guide",
            "Make flashcards for bones and muscle names",
            "Do timed practice test on muscles and bones",
        ], "overdue rows")
        check(board.overdue.allSatisfy { $0.state == .overdue }, "overdue rows are red")
        equal(board.overdue.first?.detailText, "nov 7, 7:00 pm · prepare · Science muscles and bones test", "overdue detail line")
        equal(board.overdue.last?.detailText, "yesterday, 6:00 pm · prac · Science muscles and bones test", "yesterday detail line")

        equal(board.dueToday.map(\.item.name), ["Final skim of science notes and pack for test", "math homework"], "today rows, timed first")
        equal(board.dueToday.first?.state, .late, "7:30 am step is late at 9:15")
        equal(board.dueToday.first?.detailText, "7:30 am · do · Science muscles and bones test", "late detail line")
        equal(board.dueToday.last?.state, .normal, "homework with no time is not late")
        equal(board.dueToday.last?.detailText, "today · homework", "task detail line")

        equal(board.upcoming.map(\.item.name), ["write all of analysis part"], "upcoming holds only steps")
        equal(board.upcoming.first?.detailText, "tomorrow · do · english analysis", "upcoming detail line")

        equal(board.tasks.map(\.task.name), ["math homework", "Science muscles and bones test", "english analysis"], "tasks/ sorted by due date")
        equal(board.tasks.map(\.detailText), ["due today", "due tomorrow · 4 steps", "due friday · 1 step"], "tasks/ detail lines")
        equal(board.tasks[1].steps.count, 4, "science test has 4 unfinished steps")
        equal(board.tasks[1].doneSteps, 1, "…and 1 finished")
        equal(board.tasks[1].totalSteps, 5, "…out of 5")
        equal(board.tasks[1].steps.first?.detailText, "nov 7, 7:00 pm · prepare", "steps under a task don't repeat the task name")

        equal(board.count, 5, "menu bar count = overdue + today")
        check(board.hasOverdue, "something is overdue")
        equal(store.finished.map(\.name), ["Read chapter 6 and take notes"], "finished today")
        check(!store.tasks.contains { $0.name == "French vocab quiz" }, "done tasks are filtered out")

        // Before 7:30 nothing is late; the next day the today rows become overdue.
        let early = Board.build(tasks: store.tasks, steps: store.steps, now: Fixtures.referenceNow.addingTimeInterval(-2 * 3600))
        equal(early.dueToday.first?.state, .normal, "at 7:15 am the step is not late yet")
        equal(early.nextDueName, "Final skim of science notes and pack for test", "next timed item")
        let nextDay = Board.build(tasks: store.tasks, steps: store.steps, now: Fixtures.referenceNow.addingTimeInterval(24 * 3600))
        equal(nextDay.overdue.count, 5, "the next morning, yesterday's rows are overdue")

        // Time badges
        equal(board.overdue.map(\.badge), [nil, nil, nil], "overdue steps shown with their task's name carry no badge (no room)")
        equal(board.dueToday.first?.badge, "1h late", "a timed row that's past due says how late")
        equal(board.dueToday.last?.badge, nil, "no time, no badge")
        equal(board.tasks[1].steps.map(\.badge), ["3d late", "2d late", "1d late", "1h late"], "steps under their task have room for it")
        equal(early.dueToday.first?.badge, "in 15m", "before it's due, it counts down")
        let at = { (clock: String) in NotionDate.parseDateTime("2026-11-10T\(clock):00.000-05:00")! }
        let fourPM = Due(start: "2026-11-10T16:00:00.000-05:00", end: nil)
        equal(Board.badge(fourPM, today: board.today, now: at("14:15")), "in 1h 45m", "under three hours away: hours and minutes")
        equal(Board.badge(fourPM, today: board.today, now: at("09:15")), "in 7h", "further off: whole hours")
        equal(Board.badge(fourPM, today: board.today, now: at("16:00")), "now", "on the dot")
        equal(Board.badge(fourPM, today: board.today, now: at("16:40")), "40m late", "minutes late")

        // Week strip and day filter
        equal(board.week.map(\.count), [2, 2, 0, 1, 0, 0, 0], "week strip counts what starts each day")
        equal(board.week.first?.day, board.today, "…starting today")
        let tomorrow = board.filtered(by: "", day: board.today.adding(1))
        equal(tomorrow.overdue.count + tomorrow.dueToday.count, 0, "picking tomorrow hides overdue and today")
        equal(tomorrow.upcoming.map(\.item.name), ["write all of analysis part"], "…and keeps what's due that day")
        equal(tomorrow.tasks.map(\.task.name), ["Science muscles and bones test", "english analysis"], "…with the tasks due then, or holding a step due then")
        equal(board.filtered(by: "english", day: board.today.adding(1)).tasks.count, 1, "a day and typed text narrow together")

        let filtered = board.filtered(by: "flash")
        equal(filtered.overdue.map(\.item.name), ["Make flashcards for bones and muscle names"], "filter keeps matching rows")
        equal(filtered.tasks.map(\.task.name), ["Science muscles and bones test"], "filter keeps the task whose step matches")
        equal(board.filtered(by: "english do").upcoming.count, 1, "every word must match (name, parent or type)")
    }

    // MARK: Notion calls

    private static func notionCalls() async {
        section("notion calls")
        let config = NotionConfig.sample

        // Pagination
        let paged = FakeNotion.fixtures()
        await paged.setPageSize(2)
        let client = NotionClient(token: "selftest", transport: paged, config: .sample)
        let steps = try? await client.openSteps()
        equal(steps?.count, 5, "pagination collects every page")
        let pageCalls = await paged.calls
        equal(pageCalls.count, 3, "5 results at 2 per page = 3 requests")
        equal(pageCalls.first?.path, "/data_sources/\(config.stepsDataSource)/query", "uses the data-source endpoint")
        equal(pageCalls.first?.version, "2025-09-03", "with the current API version")
        equal(pageCalls.first?.body?["filter"], NotionClient.notDone, "filter: Status != Done")
        equal(pageCalls.first?.body?["sorts"], NotionClient.byDue, "sort: Due date ascending")
        equal(pageCalls.last?.body?["start_cursor"]?.stringValue, "cursor-4", "next page uses start_cursor")

        // Database ids from whatever gets pasted into Settings
        equal(NotionConfig.normalizeID("aaaaaaaa00004000800000000000000f"), "aaaaaaaa-0000-4000-8000-00000000000f", "a bare 32-character id gets its dashes")
        equal(NotionConfig.normalizeID(" AAAAAAAA-0000-4000-8000-00000000000F "), "aaaaaaaa-0000-4000-8000-00000000000f", "a dashed id is tidied")
        equal(NotionConfig.normalizeID("https://www.notion.so/myspace/Task-Tracker-aaaaaaaa00004000800000000000000f?v=bbbbbbbb00004000800000000000000e&pvs=4"),
              "aaaaaaaa-0000-4000-8000-00000000000f", "a link gives the database id, not the view id")
        check(NotionConfig.normalizeID("https://www.notion.so/just-a-page") == nil, "text with no id is refused")
        check(!NotionConfig().isComplete && NotionConfig.sample.isComplete, "an empty config knows it isn't ready")

        // With no data source id saved, the database endpoint is used from the start
        let plain = FakeNotion.fixtures()
        var databasesOnly = NotionConfig.sample
        databasesOnly.tasksDataSource = ""
        databasesOnly.stepsDataSource = ""
        let viaDatabases = NotionClient(token: "selftest", transport: plain, config: databasesOnly)
        let plainTasks = try? await viaDatabases.openTasks()
        equal(plainTasks?.count, 3, "works with only the database ids")
        let plainCalls = await plain.calls
        equal(plainCalls.map(\.path), ["/databases/\(config.tasksDatabase)/query"], "…in one request, on the database endpoint")
        let found = await viaDatabases.dataSource(forDatabase: config.tasksDatabase)
        equal(found, config.tasksDataSource, "the data source can be looked up from the database id")
        try? await viaDatabases.createTask(title: "made via database", due: nil, types: [], priority: nil)
        let plainCreated = (try? await viaDatabases.openTasks())?.contains { $0.title(preferring: "Task name") == "made via database" }
        equal(plainCreated, true, "creating works with only the database ids")

        // Fallback to the old endpoint
        let legacy = FakeNotion.fixtures()
        await legacy.breakDataSources(true)
        let tasks = try? await NotionClient(token: "selftest", transport: legacy, config: .sample).openTasks()
        equal(tasks?.count, 3, "falls back to the database endpoint")
        let legacyCalls = await legacy.calls
        equal(legacyCalls.last?.path, "/databases/\(config.tasksDatabase)/query", "fallback path")
        equal(legacyCalls.last?.version, "2022-06-28", "fallback API version")

        // 401: no fallback
        let unauthorized = FakeNotion.fixtures()
        do {
            _ = try await NotionClient(token: "invalid", transport: unauthorized, config: .sample).openTasks()
            check(false, "a bad token throws")
        } catch {
            check((error as? NotionError)?.isUnauthorized ?? false, "a bad token is a 401")
        }
        let unauthorizedCalls = await unauthorized.calls
        equal(unauthorizedCalls.count, 1, "a 401 doesn't try the old endpoint")

        // Offline
        let offline = FakeNotion.fixtures()
        await offline.fail(with: .offline)
        do {
            _ = try await NotionClient(token: "selftest", transport: offline, config: .sample).openTasks()
            check(false, "offline throws")
        } catch {
            check((error as? NotionError)?.isNetwork ?? false, "no connection is a network error")
        }

        // 404
        let missing = FakeNotion.fixtures()
        await missing.fail(with: .http(404, "Could not find database with ID: x."))
        do {
            _ = try await NotionClient(token: "selftest", transport: missing, config: .sample).openTasks()
            check(false, "404 throws")
        } catch {
            check((error as? NotionError)?.isNotFound ?? false, "404 is 'not found'")
        }

        // Mark a step done
        let fake = FakeNotion.fixtures()
        let notion = NotionClient(token: "selftest", transport: fake, config: .sample)
        let built = ItemBuilder.build(tasks: (try? await notion.openTasks()) ?? [], steps: (try? await notion.openSteps()) ?? [])
        guard let guide = built.steps.first(where: { $0.name == "Do the study guide" }),
              let science = built.tasks.first(where: { $0.name == "Science muscles and bones test" }) else {
            check(false, "fixtures contain the sample rows")
            return
        }
        await fake.resetCalls()
        _ = try? await notion.markDone(guide, today: Fixtures.referenceDay)
        let stepCalls = await fake.calls
        equal(stepCalls.count, 1, "a step is one request")
        equal(stepCalls.first?.method, "PATCH", "PATCH")
        equal(stepCalls.first?.path, "/pages/\(guide.id)", "to /pages/{id}")
        equal(stepCalls.first?.body, ["properties": ["Status": ["status": ["name": "Done"]]]], "body sets Status to Done")
        let guideStatus = await fake.status(of: guide.id)
        equal(guideStatus, "Done", "the step is Done in (fake) Notion")

        // Mark a task done: completion date + its leftover steps
        await fake.resetCalls()
        let receipt = try? await notion.markDone(science, today: Fixtures.referenceDay)
        let taskCalls = await fake.calls
        equal(taskCalls.first?.body, ["properties": [
            "Status": ["status": ["name": "Done"]],
            "Completion date": ["date": ["start": "2026-11-10"]],
        ]], "a task also gets today's completion date")
        equal(taskCalls.dropFirst().first?.body?["filter"], ["and": [
            NotionClient.notDone,
            ["property": "Test / Project", "relation": ["contains": .string(science.id)]],
        ]], "then its unfinished steps are queried")
        equal(receipt?.cascaded.count, 3, "the 3 leftover steps are finished too")
        equal(taskCalls.filter { $0.method == "PATCH" }.count, 4, "1 task + 3 steps patched")
        let leftover = (try? await notion.openSteps())?.count
        equal(leftover, 1, "only the english step is left")

        // Undo puts everything back
        if let receipt {
            try? await notion.undo(receipt)
            let status = await fake.status(of: science.id)
            equal(status, "In progress", "undo restores the task's old status")
            let completion = await fake.page(science.id)?["properties"]?["Completion date"]?["date"]
            equal(completion, .null, "undo clears the completion date")
            let reopened = (try? await notion.openSteps())?.count
            equal(reopened, 4, "undo reopens the cascaded steps")
        }

        // Create
        try? await notion.createTask(title: "new thing", due: "2026-11-12", types: ["homework"], priority: "Low")
        let created = (try? await notion.openTasks())?.first { $0.title(preferring: "Task name") == "new thing" }
        check(created != nil, "created task comes back from a query")
        equal(created?.properties["Due date"]?.date?.start, "2026-11-12", "created task keeps its due date")

        // Create a step under a task
        try? await notion.createStep(title: "new step", due: "2026-11-12", stepType: "Prac", parentID: science.id)
        let newStep = (try? await notion.openSteps())?.first { $0.title(preferring: "Name") == "new step" }
        check(newStep != nil, "created step comes back from a query")
        equal(newStep?.properties["Test / Project"]?.relation?.first?.id, science.id, "…linked to its task")
        equal(newStep?.properties["Step type"]?.select?.name, "Prac", "…with its step type")

        let name = try? await notion.whoAmI()
        check(name != nil, "who-am-i answers")

        // "Show tasks on their completion date": a completion date filled in ahead of time is the planned day
        let planner = FakeNotion.fixtures()
        let planning = NotionClient(token: "selftest", transport: planner, config: .sample)
        if let english = ItemBuilder.build(tasks: (try? await planning.openTasks()) ?? [], steps: []).tasks.first(where: { $0.name == "english analysis" }) {
            // english analysis is due Fri Nov 13. Plan it for today (Tue Nov 10).
            try? await planning.setDate(pageID: english.id, property: "Completion date", start: "2026-11-10", end: nil)
            let pages = (tasks: (try? await planning.openTasks()) ?? [], steps: (try? await planning.openSteps()) ?? [])

            let byDue = ItemBuilder.build(tasks: pages.tasks, steps: pages.steps)
            let dueBoard = Board.build(tasks: byDue.tasks, steps: byDue.steps, now: Fixtures.referenceNow)
            check(!dueBoard.dueToday.contains { $0.item.id == english.id }, "setting off: the task waits for its due date")

            let byPlan = ItemBuilder.build(tasks: pages.tasks, steps: pages.steps, planByCompletionDate: true)
            let planBoard = Board.build(tasks: byPlan.tasks, steps: byPlan.steps, now: Fixtures.referenceNow)
            let row = planBoard.dueToday.first { $0.item.id == english.id }
            check(row != nil, "setting on: it pops up on its completion date")
            equal(row?.detailText, "today · project · due friday", "…and still says when it's due")
            equal(planBoard.count, dueBoard.count + 1, "…and counts in the menu bar that day")
            equal(planBoard.week.map(\.count), [3, 2, 0, 0, 0, 0, 0], "…and moves in the week strip (off friday, onto today)")
            equal(planBoard.tasks.first { $0.task.id == english.id }?.detailText, "planned today · due friday · 1 step", "tasks/ shows both dates")
            equal(planBoard.tasks.map(\.task.name), ["math homework", "english analysis", "Science muscles and bones test"],
                  "…sorted by the planned day (ahead of the science test, due tomorrow)")
            let nextDay = Board.build(tasks: byPlan.tasks, steps: byPlan.steps, now: Fixtures.referenceNow.addingTimeInterval(24 * 3600))
            check(nextDay.overdue.contains { $0.item.id == english.id }, "the day after its planned day, it's overdue")

            // Marking it done writes today's date; undo puts the planned day back
            if let planned = byPlan.tasks.first(where: { $0.id == english.id }) {
                try? await planning.setDate(pageID: english.id, property: "Completion date", start: "2026-11-12", end: nil)
                var later = planned
                later.due = Due(start: "2026-11-12", end: nil)
                let receipt = try? await planning.markDone(later, today: Fixtures.referenceDay)
                let written = await planner.page(english.id)?["properties"]?["Completion date"]?["date"]?["start"]?.stringValue
                equal(written, "2026-11-10", "marking done records the day it was actually finished")
                let beaten = try? await planning.finished(since: Fixtures.referenceDay.startOfDay, today: Fixtures.referenceDay)
                check(beaten?.tasks.contains { $0.id == english.id } ?? false, "…and it counts as finished today")
                if let receipt { try? await planning.undo(receipt) }
                let restored = await planner.page(english.id)?["properties"]?["Completion date"]?["date"]?["start"]?.stringValue
                equal(restored, "2026-11-12", "undo puts the planned day back instead of wiping it")
            }
        } else {
            check(false, "the sample has the english analysis task")
        }

        // Finished today
        let fresh = FakeNotion.fixtures()
        let reader = NotionClient(token: "selftest", transport: fresh, config: .sample)
        let midnight = Fixtures.referenceDay.startOfDay
        let done = try? await reader.finished(since: midnight, today: Fixtures.referenceDay)
        equal(done?.steps.map { $0.title(preferring: "Name") }, ["Read chapter 6 and take notes"], "a step edited today counts as finished today")
        equal(done?.tasks.count, 0, "a task completed last week doesn't")
        let doneCalls = await fresh.calls
        equal(doneCalls.first?.body, [
            "filter": ["property": "Status", "status": ["equals": "Done"]],
            "sorts": [["timestamp": "last_edited_time", "direction": "descending"]],
            "page_size": 30,
        ], "asks for the most recently edited Done pages")
        equal(doneCalls.count, 2, "one request per database")

        // A task finished today is recognised by its completion date
        if let math = ItemBuilder.build(tasks: (try? await reader.openTasks()) ?? [], steps: []).tasks.first(where: { $0.name == "math homework" }) {
            _ = try? await reader.markDone(math, today: Fixtures.referenceDay)
            let after = try? await reader.finished(since: midnight, today: Fixtures.referenceDay)
            equal(after?.tasks.map { $0.title(preferring: "Task name") }, ["math homework"], "a task with today's completion date counts")
            let tomorrow = try? await reader.finished(since: Fixtures.referenceDay.adding(1).startOfDay, today: Fixtures.referenceDay.adding(1))
            equal(tomorrow?.tasks.count, 0, "…but not tomorrow")
        }

        // If Notion refuses the sorted query, the plainer one still finds them
        await fresh.refuseTimestampSorts(true)
        let fallback = try? await reader.finished(since: midnight, today: Fixtures.referenceDay)
        equal(fallback?.steps.map { $0.title(preferring: "Name") }, ["Read chapter 6 and take notes"], "fallback query finds the same step")
        equal(fallback?.tasks.count, 1, "…and the same task")
    }

    // MARK: Store

    private static func storeFlows() async {
        section("store")
        let fake = FakeNotion.fixtures()
        let store = makeStore(fake)
        await store.refresh()
        guard let guide = store.steps.first(where: { $0.name == "Do the study guide" }),
              let science = store.tasks.first(where: { $0.name == "Science muscles and bones test" }) else {
            check(false, "store loaded the sample rows")
            return
        }

        // Step done
        store.markDone(guide)
        await waitForWrites(store)
        equal(store.board.count, 4, "count drops after marking a step done")
        check(store.finished.first?.id == guide.id, "the step moves to finished")
        check(store.canUndo, "the mark-done can be undone")
        await store.refresh()
        equal(store.board.overdue.count, 2, "still gone after a fresh fetch")
        equal(store.board.tasks.first { $0.task.id == science.id }?.doneSteps, 2, "task progress counts the finished step")

        // Undo
        store.undoLast()
        await waitForWrites(store)
        await store.refresh()
        equal(store.board.count, 5, "undo brings the row back")
        check(!store.finished.contains { $0.id == guide.id }, "…and takes it out of finished")

        // A failed write puts the row back
        await fake.fail(with: .http(500, "Internal server error"), times: 1)
        store.markDone(guide)
        await waitForWrites(store)
        equal(store.board.count, 5, "a failed mark-done puts the row back")
        equal(store.toast?.kind, .error, "…and shows an error")
        check(!store.finished.contains { $0.id == guide.id }, "…and it isn't listed as finished")
        let stillOpen = await fake.status(of: guide.id)
        equal(stillOpen, "Not started", "…and Notion is unchanged")

        // Task done takes its steps with it
        store.markDone(science)
        await waitForWrites(store)
        equal(store.board.count, 1, "a task takes its steps out of every section")
        equal(store.board.tasks.map(\.task.name), ["math homework", "english analysis"], "the task leaves tasks/")
        store.undoLast()
        await waitForWrites(store)
        await store.refresh()
        equal(store.board.count, 5, "undoing a task brings its steps back")

        // Reopen something from done/
        if let readNotes = store.finished.first(where: { $0.name == "Read chapter 6 and take notes" }) {
            store.reopen(readNotes)
            await waitForWrites(store)
            await store.refresh()
            check(store.steps.contains { $0.id == readNotes.id }, "reopen puts a finished step back in the list")
            check(!store.finished.contains { $0.id == readNotes.id }, "…and out of done/")
            equal(store.board.overdue.count, 4, "…where it's overdue again")
            if let again = store.steps.first(where: { $0.id == readNotes.id }) {
                store.markDone(again)
                await waitForWrites(store)
                await store.refresh()
                equal(store.board.overdue.count, 3, "and it can be finished again")
            }
        } else {
            check(false, "the sample has a step finished today")
        }

        // Add a step to a task
        let before = store.steps.count
        store.addStep(QuickAdd.parse("+ cue cards #prepare"), to: science)
        await waitForWrites(store)
        await store.refresh()
        equal(store.steps.count, before + 1, "adding a step puts it in the list")
        check(store.board.tasks.first { $0.task.id == science.id }?.steps.contains { $0.item.name == "cue cards" } ?? false, "…under its task")
        if let added = store.steps.first(where: { $0.name == "cue cards" }) {
            // (Tidy up so the checks below see the sample as it was.)
            store.markDone(added)
            await waitForWrites(store)
            await store.refresh()
        }

        // With planning on, moving a task moves its completion date and leaves the due date alone
        let planFake = FakeNotion.fixtures()
        let planStore = makeStore(planFake, planByCompletionDate: true)
        await planStore.refresh()
        if let math = planStore.tasks.first(where: { $0.name == "math homework" }) {
            planStore.reschedule(math, to: Fixtures.referenceDay.adding(1))
            await waitForWrites(planStore)
            let page = await planFake.page(math.id)
            equal(page?["properties"]?["Completion date"]?["date"]?["start"]?.stringValue, "2026-11-11", "move writes the completion date")
            equal(page?["properties"]?["Due date"]?["date"]?["start"]?.stringValue, "2026-11-10", "…and doesn't touch the due date")
            await planStore.refresh()
            check(!planStore.board.dueToday.contains { $0.item.id == math.id }, "…so it leaves today")
            equal(planStore.board.tasks.first { $0.task.id == math.id }?.detailText, "planned tomorrow · due today", "…and shows both dates")
        }

        // Reschedule and status
        store.reschedule(guide, to: Fixtures.referenceDay.adding(1))
        await waitForWrites(store)
        await store.refresh()
        let moved = store.steps.first { $0.id == guide.id }
        equal(moved?.due?.rawStart, "2026-11-11T19:00:00.000-05:00", "snooze keeps the time of day")
        equal(store.board.overdue.count, 2, "the snoozed row leaves overdue")
        equal(store.board.upcoming.first?.item.id, guide.id, "…and shows under upcoming")

        store.setInProgress(guide, true)
        await waitForWrites(store)
        let started = await fake.status(of: guide.id)
        equal(started, "In progress", "start sets In progress")

        // Errors
        await fake.fail(with: .offline)
        await store.refresh()
        check(store.isOffline && store.failure == nil, "offline keeps the last list")
        check(!store.board.isEmpty, "…with its rows")

        await fake.fail(with: .http(401, "API token is invalid."))
        await store.refresh()
        equal(store.failure, .unauthorized("HTTP 401 API token is invalid."), "401 → token error")
        equal(store.failure?.hint, "your notion token isn't valid", "401 hint")

        await fake.fail(with: .http(404, "Could not find database with ID: x."))
        await store.refresh()
        equal(store.failure?.hint, "add the integration to both databases (••• → connections)", "404 hint")
        check(TaskStore.Failure.missingDatabases.needsSettings, "missing databases sends you to settings")
        check(!TaskStore.Failure.keychainLocked.needsSettings && TaskStore.Failure.missingToken.needsSettings,
              "a locked keychain asks you to allow it, not to paste the token again")

        await fake.fail(with: nil)
        await store.refresh()
        check(store.failure == nil && !store.isOffline, "recovers on the next good fetch")

        let empty = makeStore(FakeNotion.fixtures())
        let offlineFirst = FakeNotion.fixtures()
        await offlineFirst.fail(with: .offline)
        let cold = makeStore(offlineFirst)
        await cold.refresh()
        check(cold.failure != nil && !cold.isOffline, "offline with nothing saved shows the error")
        _ = empty
    }
}
