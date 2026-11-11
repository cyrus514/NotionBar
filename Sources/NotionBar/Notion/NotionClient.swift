import Foundation

/// Sends one HTTP request. The real one uses URLSession; `FakeNotion` answers from memory
/// so the app can run with no token (demo mode, self-test, previews).
protocol Transport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionTransport: Transport {
    static let shared = URLSessionTransport()

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 40
        config.waitsForConnectivity = false
        config.httpCookieStorage = nil
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NotionError.badResponse("not an http response")
        }
        return (data, http)
    }
}

/// What marking a task or step done changed, so it can be undone.
struct DoneReceipt: Equatable {
    var item: Item
    /// Steps that were finished along with a task, with the status each one had before.
    var cascaded: [CascadedStep] = []
    /// Set when the task itself was finished but some of its steps couldn't be.
    var cascadeFailure: String?

    struct CascadedStep: Equatable {
        var id: String
        var previousStatus: String
    }
}

/// The Notion calls the app makes. Ported from `api`, `query_all` and `mark_done` in the plugin.
struct NotionClient: Sendable {
    let token: String
    var transport: any Transport = URLSessionTransport.shared
    var config: NotionConfig

    static let notDone: JSONValue = ["property": "Status", "status": ["does_not_equal": "Done"]]
    static let done: JSONValue = ["property": "Status", "status": ["equals": "Done"]]
    static let byDue: JSONValue = [["property": "Due date", "direction": "ascending"]]

    // MARK: Reading

    /// Every unfinished task, soonest first.
    func openTasks() async throws -> [NotionPage] {
        try await queryAll(dataSource: config.tasksDataSource, database: config.tasksDatabase,
                           body: ["filter": NotionClient.notDone, "sorts": NotionClient.byDue])
    }

    /// Every unfinished step, soonest first.
    func openSteps() async throws -> [NotionPage] {
        try await queryAll(dataSource: config.stepsDataSource, database: config.stepsDatabase,
                           body: ["filter": NotionClient.notDone, "sorts": NotionClient.byDue])
    }

    /// What was finished today, in both databases. This is how the panel knows what you got done,
    /// including things finished in Notion itself.
    ///
    /// A task counts when its completion date is today (or, if it has none, when it was edited today).
    /// A step counts when it was last edited today: steps have no completion date.
    func finished(since: Date, today: Day) async throws -> (tasks: [NotionPage], steps: [NotionPage]) {
        async let tasks = recentlyFinished(dataSource: config.tasksDataSource, database: config.tasksDatabase, today: today)
        async let steps = recentlyFinished(dataSource: config.stepsDataSource, database: config.stepsDatabase, today: today)
        let all = try await (tasks: tasks, steps: steps)

        func editedToday(_ page: NotionPage) -> Bool {
            guard let edited = page.lastEditedTime.flatMap(NotionDate.parseDateTime) else { return false }
            return edited >= since
        }
        return (
            all.tasks.filter { page in
                let completed = NotionDate.parse(page.properties["Completion date"]?.date?.start)?.day
                if completed == today { return true }
                // A completion date in the past means it was finished on an earlier day.
                if let completed, completed < today { return false }
                // None, or one in the future (a planned day that was beaten): go by when it was last edited.
                return editedToday(page)
            },
            all.steps.filter(editedToday)
        )
    }

    /// The Done pages edited most recently. Which of them were finished today is decided by the
    /// caller from each page's own dates, so this doesn't lean on Notion's date-filter rules.
    private func recentlyFinished(dataSource: String, database: String, today: Day) async throws -> [NotionPage] {
        do {
            return try await queryAll(dataSource: dataSource, database: database, body: [
                "filter": NotionClient.done,
                "sorts": [["timestamp": "last_edited_time", "direction": "descending"]],
                "page_size": 30,
            ], firstPageOnly: true)
        } catch let error as NotionError {
            guard case .http(let status, _) = error, status == 400 else { throw error }
            // Notion refused that request. Ask a plainer question instead: everything Done that was due lately.
            Log.write("finished-today: sorted query refused (\(error.message)); falling back to a due-date window")
            return try await queryAll(dataSource: dataSource, database: database, body: [
                "filter": ["and": [
                    NotionClient.done,
                    ["property": "Due date", "date": ["on_or_after": .string(today.adding(-30).iso)]],
                ]],
            ])
        }
    }

    /// Queries every page of a database. Uses the newer data-source endpoint, and falls back
    /// to the older database endpoint if that one fails with anything other than a 401.
    /// `firstPageOnly` stops after one page (used by "Test connection", which only needs to know it works).
    func queryAll(dataSource: String, database: String, body: JSONValue,
                  firstPageOnly: Bool = false) async throws -> [NotionPage] {
        var results: [NotionPage] = []
        var cursor: String?
        // No data source id saved: go straight to the database endpoint.
        var useLegacy = dataSource.isEmpty
        while true {
            var page = body
            if let cursor { page["start_cursor"] = .string(cursor) }
            let data: Data
            if useLegacy {
                data = try await call("POST", "/databases/\(database)/query", body: page, version: config.legacyVersion)
            } else {
                do {
                    data = try await call("POST", "/data_sources/\(dataSource)/query", body: page, version: config.version)
                } catch let error as NotionError {
                    // A bad token or no connection will fail the same way on the old endpoint.
                    if error.isUnauthorized || error.isNetwork { throw error }
                    Log.write("data-source query refused (\(error.message)); trying the database endpoint")
                    useLegacy = true
                    continue
                }
            }
            let list: NotionList
            do {
                list = try JSONDecoder().decode(NotionList.self, from: data)
            } catch {
                throw NotionError.badResponse("couldn't read the list of pages")
            }
            results.append(contentsOf: list.results)
            guard !firstPageOnly, list.hasMore, let next = list.nextCursor else { return results }
            cursor = next
        }
    }

    /// Checks the token and that both databases can be read. Returns a line to show in Settings.
    func testConnection() async -> (ok: Bool, text: String) {
        let name: String
        do {
            name = try await whoAmI()
        } catch let error as NotionError {
            if error.isUnauthorized { return (false, "your notion token isn't valid") }
            return (false, error.message)
        } catch {
            return (false, error.localizedDescription)
        }
        var missing: [String] = []
        for (label, source, database) in [("task tracker", config.tasksDataSource, config.tasksDatabase),
                                          ("steps", config.stepsDataSource, config.stepsDatabase)] {
            do {
                _ = try await queryAll(dataSource: source, database: database, body: ["page_size": 1], firstPageOnly: true)
            } catch {
                missing.append(label)
            }
        }
        if missing.isEmpty { return (true, "connected as \(name) · both databases readable") }
        return (false, "connected as \(name), but can't read: \(missing.joined(separator: ", ")). add the integration to it (••• → connections)")
    }

    /// The integration's name. Used by "Test connection".
    func whoAmI() async throws -> String {
        let data = try await call("GET", "/users/me", body: nil, version: config.version)
        let user = try? JSONDecoder().decode(NotionUser.self, from: data)
        return user?.name ?? "integration"
    }

    // MARK: Writing

    func update(pageID: String, properties: JSONValue) async throws {
        _ = try await call("PATCH", "/pages/\(pageID)", body: ["properties": properties], version: config.version)
    }

    func setStatus(pageID: String, to status: String) async throws {
        try await update(pageID: pageID, properties: ["Status": ["status": ["name": .string(status)]]])
    }

    /// Marks a step or task Done. A task also gets today's date as its completion date,
    /// and its leftover steps are finished too.
    func markDone(_ item: Item, today: Day) async throws -> DoneReceipt {
        var properties: JSONValue = ["Status": ["status": ["name": "Done"]]]
        if item.kind == .task {
            properties["Completion date"] = ["date": ["start": .string(today.iso)]]
        }
        try await update(pageID: item.id, properties: properties)

        var receipt = DoneReceipt(item: item)
        guard item.kind == .task else { return receipt }
        // The task is done from here on: a failure below is reported, not thrown.
        do {
            let leftovers = try await queryAll(
                dataSource: config.stepsDataSource, database: config.stepsDatabase,
                body: ["filter": ["and": [
                    NotionClient.notDone,
                    ["property": "Test / Project", "relation": ["contains": .string(item.id)]],
                ]]])
            for step in leftovers {
                let previous = step.properties["Status"]?.status?.name ?? "Not started"
                try await setStatus(pageID: step.id, to: "Done")
                receipt.cascaded.append(.init(id: step.id, previousStatus: previous))
            }
        } catch let error as NotionError {
            receipt.cascadeFailure = error.message
        } catch {
            receipt.cascadeFailure = error.localizedDescription
        }
        return receipt
    }

    /// Puts back what `markDone` changed.
    func undo(_ receipt: DoneReceipt) async throws {
        try await reopen(receipt.item, status: receipt.item.status)
        for step in receipt.cascaded {
            try await setStatus(pageID: step.id, to: step.previousStatus)
        }
    }

    /// Sets a finished item back to unfinished. A task's completion date is cleared, or put back
    /// to the day it was planned for when it had one.
    func reopen(_ item: Item, status: String = "Not started") async throws {
        let restored = (status.isEmpty || status == "Done") ? "Not started" : status
        var properties: JSONValue = ["Status": ["status": ["name": .string(restored)]]]
        if item.kind == .task {
            if item.isPlanned, let planned = item.due {
                var date: JSONValue = ["start": .string(planned.rawStart)]
                if let end = planned.rawEnd { date["end"] = .string(end) }
                properties["Completion date"] = ["date": date]
            } else {
                properties["Completion date"] = ["date": .null]
            }
        }
        try await update(pageID: item.id, properties: properties)
    }

    /// Changes a date property (the due date unless told otherwise). Pass the strings the way Notion writes them.
    func setDate(pageID: String, property: String = "Due date", start: String, end: String?) async throws {
        var date: JSONValue = ["start": .string(start)]
        if let end { date["end"] = .string(end) }
        try await update(pageID: pageID, properties: [property: ["date": date]])
    }

    /// Adds a new task to the Task Tracker.
    func createTask(title: String, due: String?, types: [String], priority: String?) async throws {
        var properties: JSONValue = [
            "Task name": ["title": [["text": ["content": .string(title)]]]],
            "Status": ["status": ["name": "Not started"]],
        ]
        if let due { properties["Due date"] = ["date": ["start": .string(due)]] }
        if !types.isEmpty {
            properties["Task type"] = ["multi_select": .array(types.map { ["name": .string($0)] })]
        }
        if let priority { properties["Priority"] = ["select": ["name": .string(priority)]] }

        try await createPage(dataSource: config.tasksDataSource, database: config.tasksDatabase, properties: properties)
    }

    /// Adds a new step to the Steps database, linked to its task.
    func createStep(title: String, due: String?, stepType: String?, parentID: String) async throws {
        var properties: JSONValue = [
            "Name": ["title": [["text": ["content": .string(title)]]]],
            "Status": ["status": ["name": "Not started"]],
            "Test / Project": ["relation": [["id": .string(parentID)]]],
        ]
        if let due { properties["Due date"] = ["date": ["start": .string(due)]] }
        if let stepType { properties["Step type"] = ["select": ["name": .string(stepType)]] }

        try await createPage(dataSource: config.stepsDataSource, database: config.stepsDatabase, properties: properties)
    }

    /// Creates a page under the data source, or under the database when there is no data source id
    /// (or the newer endpoint refuses).
    private func createPage(dataSource: String, database: String, properties: JSONValue) async throws {
        if !dataSource.isEmpty {
            do {
                _ = try await call("POST", "/pages", body: [
                    "parent": ["type": "data_source_id", "data_source_id": .string(dataSource)],
                    "properties": properties,
                ], version: config.version)
                return
            } catch let error as NotionError {
                if error.isUnauthorized || error.isNetwork { throw error }
            }
        }
        _ = try await call("POST", "/pages", body: [
            "parent": ["database_id": .string(database)],
            "properties": properties,
        ], version: config.legacyVersion)
    }

    /// The data source behind a database, so the newer endpoints can be used. Nil if it can't be found.
    func dataSource(forDatabase database: String) async -> String? {
        guard let data = try? await call("GET", "/databases/\(database)", body: nil, version: config.version) else { return nil }
        return JSONValue.parse(data)?["data_sources"]?.arrayValue?.first?["id"]?.stringValue
    }

    // MARK: Plumbing

    /// One request. Throws `NotionError` for anything but a 2xx answer.
    private func call(_ method: String, _ path: String, body: JSONValue?, version: String,
                      retriesLeft: Int = 1) async throws -> Data {
        guard !token.isEmpty else { throw NotionError.missingToken }
        guard let url = URL(string: config.apiBase.absoluteString + path) else {
            throw NotionError.badResponse("bad url")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue(version, forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body?.data()

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch let error as NotionError {
            throw error
        } catch let error as URLError {
            throw NotionError.network(NotionClient.describe(error))
        } catch {
            throw NotionError.network(error.localizedDescription)
        }

        if (200..<300).contains(response.statusCode) { return data }

        // Rate limited: wait as long as Notion asks (a few seconds at most), then try once more.
        if response.statusCode == 429, retriesLeft > 0 {
            let wait = Double(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 1
            try? await Task.sleep(nanoseconds: UInt64(min(max(wait, 0.2), 5) * 1_000_000_000))
            return try await call(method, path, body: body, version: version, retriesLeft: retriesLeft - 1)
        }

        let message = (try? JSONDecoder().decode(NotionErrorBody.self, from: data))?.message ?? ""
        throw NotionError.http(status: response.statusCode, message: message)
    }

    private static func describe(_ error: URLError) -> String {
        switch error.code {
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff: return "no internet"
        case .timedOut: return "timed out"
        case .cannotFindHost, .dnsLookupFailed: return "can't find api.notion.com"
        case .cannotConnectToHost, .networkConnectionLost: return "connection lost"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate:
            return "secure connection failed"
        default: return error.localizedDescription
        }
    }
}
