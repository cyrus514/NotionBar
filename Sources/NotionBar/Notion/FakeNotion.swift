import Foundation

/// A tiny Notion that lives in memory. It answers the same requests the real API does
/// (query, update a page, create a page, who am I), starting from the JSON fixtures.
///
/// Used by `--demo`, `--selftest`, `--snapshot` and the SwiftUI previews, so the whole app,
/// including marking things done, can be tried without a token.
actor FakeNotion: Transport {
    /// A failure to inject, for trying the error screens.
    enum Failure: Sendable {
        case http(Int, String)
        case offline
    }

    struct Call: Sendable, Equatable {
        var method: String
        var path: String
        var version: String
        var body: JSONValue?
    }

    private var pages: [String: [JSONValue]]   // keyed by data source id
    private let config: NotionConfig
    /// Seconds each request takes, so loading animations are visible in the demo.
    private var latency: Double
    private var failure: Failure?
    private var failuresLeft = 0
    private var dataSourcesBroken = false
    private var timestampSortsRefused = false
    private var pageSize: Int?
    private(set) var calls: [Call] = []

    init(tasks: [JSONValue], steps: [JSONValue], config: NotionConfig = .sample, latency: Double = 0) {
        self.config = config
        self.latency = latency
        self.pages = [config.tasksDataSource: tasks, config.stepsDataSource: steps]
    }

    /// The bundled sample data. `shiftedTo` moves every date so the sample's "today"
    /// (Tue Nov 10, 2026) lands on the given day.
    static func fixtures(shiftedTo today: Day? = nil, latency: Double = 0) -> FakeNotion {
        var tasks = Fixtures.pages("tasks-query")
        var steps = Fixtures.pages("steps-query")
        if let today {
            let delta = Fixtures.referenceDay.days(to: today)
            tasks = tasks.map { shift($0, days: delta) }
            steps = steps.map { shift($0, days: delta) }
        }
        return FakeNotion(tasks: tasks, steps: steps, latency: latency)
    }

    // MARK: Knobs for tests and the demo

    func fail(with failure: Failure?, times: Int = .max) {
        self.failure = failure
        self.failuresLeft = failure == nil ? 0 : times
    }

    /// Makes `/data_sources/...` answer 400, to exercise the fallback to `/databases/...`.
    func breakDataSources(_ broken: Bool) { dataSourcesBroken = broken }

    /// Makes a sort by `last_edited_time` answer 400, to exercise the finished-today fallback.
    func refuseTimestampSorts(_ refused: Bool) { timestampSortsRefused = refused }

    /// Forces small pages of results, to exercise pagination.
    func setPageSize(_ size: Int?) { pageSize = size }

    func setLatency(_ seconds: Double) { latency = seconds }

    func resetCalls() { calls = [] }

    func page(_ id: String) -> JSONValue? {
        pages.values.joined().first { $0["id"]?.stringValue == id }
    }

    func status(of id: String) -> String? {
        page(id)?["properties"]?["Status"]?["status"]?["name"]?.stringValue
    }

    // MARK: Transport

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let method = request.httpMethod ?? "GET"
        let url = request.url ?? config.apiBase
        let path = String(url.path.dropFirst(config.apiBase.path.count))
        let version = request.value(forHTTPHeaderField: "Notion-Version") ?? ""
        let body = request.httpBody.flatMap(JSONValue.parse)
        calls.append(Call(method: method, path: path, version: version, body: body))

        if latency > 0 {
            try? await Task.sleep(nanoseconds: UInt64(latency * 1_000_000_000))
        }

        if let failure, failuresLeft > 0 {
            failuresLeft -= 1
            switch failure {
            case .offline:
                throw URLError(.notConnectedToInternet)
            case .http(let status, let message):
                return reply(url, status, error(status, message))
            }
        }

        let token = request.value(forHTTPHeaderField: "Authorization") ?? ""
        if token.isEmpty || token.hasSuffix("invalid") {
            return reply(url, 401, error(401, "API token is invalid."))
        }

        let parts = path.split(separator: "/").map(String.init)
        switch (method, parts.first, parts.count) {
        case ("POST", "data_sources", 3) where parts[2] == "query":
            if dataSourcesBroken {
                return reply(url, 400, error(400, "Invalid request URL."))
            }
            return query(url, source: parts[1], body: body)
        case ("POST", "databases", 3) where parts[2] == "query":
            let source = parts[1] == config.tasksDatabase ? config.tasksDataSource
                : parts[1] == config.stepsDatabase ? config.stepsDataSource : parts[1]
            return query(url, source: source, body: body)
        case ("PATCH", "pages", 2):
            return update(url, id: parts[1], body: body)
        case ("POST", "pages", 1):
            return create(url, body: body)
        case ("GET", "databases", 2):
            let source = parts[1] == config.tasksDatabase ? config.tasksDataSource
                : parts[1] == config.stepsDatabase ? config.stepsDataSource : nil
            guard let source else {
                return reply(url, 404, error(404, "Could not find database with ID: \(parts[1])."))
            }
            return reply(url, 200, ["object": "database", "id": .string(parts[1]),
                                    "data_sources": [["id": .string(source), "name": "sample"]]])
        case ("GET", "users", 2) where parts[1] == "me":
            return reply(url, 200, ["object": "user", "id": "fake-bot", "name": "notionbar (demo)", "type": "bot"])
        default:
            return reply(url, 400, error(400, "Invalid request URL."))
        }
    }

    // MARK: Endpoints

    private func query(_ url: URL, source: String, body: JSONValue?) -> (Data, HTTPURLResponse) {
        guard let all = pages[source] else {
            return reply(url, 404, error(404, "Could not find database with ID: \(source). Make sure the relevant pages and databases are shared with your integration."))
        }
        if timestampSortsRefused, body?["sorts"]?.arrayValue?.first?["timestamp"] != nil {
            return reply(url, 400, error(400, "body failed validation: body.sorts[0] should be a property sort."))
        }
        var matches = all
        if let filter = body?["filter"] {
            matches = matches.filter { FakeNotion.matches($0, filter) }
        }
        if let sort = body?["sorts"]?.arrayValue?.first {
            matches = FakeNotion.sort(matches, by: sort)
        }

        let size = pageSize ?? body?["page_size"]?.intValue ?? 100
        let start = Int(body?["start_cursor"]?.stringValue?.replacingOccurrences(of: "cursor-", with: "") ?? "") ?? 0
        let end = min(matches.count, start + size)
        let slice = start < end ? Array(matches[start..<end]) : []
        let more = end < matches.count
        return reply(url, 200, [
            "object": "list",
            "results": .array(slice),
            "next_cursor": more ? .string("cursor-\(end)") : .null,
            "has_more": .bool(more),
        ])
    }

    private func update(_ url: URL, id: String, body: JSONValue?) -> (Data, HTTPURLResponse) {
        for (source, list) in pages {
            guard let index = list.firstIndex(where: { $0["id"]?.stringValue == id }) else { continue }
            var page = list[index]
            var properties = page["properties"] ?? [:]
            for (name, change) in body?["properties"]?.objectValue ?? [:] {
                guard var property = properties[name] else {
                    return reply(url, 400, error(400, "\(name) is not a property that exists."))
                }
                for (key, value) in change.objectValue ?? [:] {
                    property[key] = FakeNotion.normalized(key, value)
                }
                properties[name] = property
            }
            page["properties"] = properties
            page["last_edited_time"] = .string(FakeNotion.stamp(Date()))
            pages[source]?[index] = page
            return reply(url, 200, page)
        }
        return reply(url, 404, error(404, "Could not find page with ID: \(id). Make sure the relevant pages and databases are shared with your integration."))
    }

    private func create(_ url: URL, body: JSONValue?) -> (Data, HTTPURLResponse) {
        let parent = body?["parent"]
        var source = parent?["data_source_id"]?.stringValue
        if source == nil, let database = parent?["database_id"]?.stringValue {
            source = database == config.tasksDatabase ? config.tasksDataSource
                : database == config.stepsDatabase ? config.stepsDataSource : nil
        }
        guard let source, pages[source] != nil else {
            return reply(url, 404, error(404, "Could not find database."))
        }
        let now = FakeNotion.stamp(Date())
        var properties: JSONValue = source == config.tasksDataSource
            ? ["Task name": ["type": "title", "title": []],
               "Status": ["type": "status", "status": ["name": "Not started"]],
               "Due date": ["type": "date", "date": nil],
               "Task type": ["type": "multi_select", "multi_select": []],
               "Priority": ["type": "select", "select": nil],
               "Completion date": ["type": "date", "date": nil],
               "Steps": ["type": "relation", "relation": [], "has_more": false]]
            : ["Name": ["type": "title", "title": []],
               "Status": ["type": "status", "status": ["name": "Not started"]],
               "Due date": ["type": "date", "date": nil],
               "Step type": ["type": "select", "select": nil],
               "Test / Project": ["type": "relation", "relation": [], "has_more": false]]
        for (name, change) in body?["properties"]?.objectValue ?? [:] {
            var property = properties[name] ?? [:]
            for (key, value) in change.objectValue ?? [:] {
                property[key] = FakeNotion.normalized(key, value)
            }
            properties[name] = property
        }
        let page: JSONValue = [
            "object": "page",
            "id": .string(UUID().uuidString.lowercased()),
            "created_time": .string(now),
            "last_edited_time": .string(now),
            "properties": properties,
        ]
        pages[source]?.append(page)
        return reply(url, 200, page)
    }

    // MARK: Helpers

    private func reply(_ url: URL, _ status: Int, _ body: JSONValue) -> (Data, HTTPURLResponse) {
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        return (body.data(), response)
    }

    private func error(_ status: Int, _ message: String) -> JSONValue {
        let code = status == 401 ? "unauthorized" : status == 404 ? "object_not_found" : "validation_error"
        return ["object": "error", "status": .number(Double(status)), "code": .string(code), "message": .string(message)]
    }

    /// Fills in what Notion adds to a value you send: title text gets `plain_text`,
    /// dates get an explicit `end`.
    private static func normalized(_ key: String, _ value: JSONValue) -> JSONValue {
        switch key {
        case "title":
            return .array((value.arrayValue ?? []).map { part in
                var part = part
                part["plain_text"] = part["text"]?["content"] ?? ""
                part["type"] = "text"
                return part
            })
        case "date":
            guard !value.isNull else { return .null }
            var date = value
            if date["end"] == nil { date["end"] = .null }
            return date
        default:
            return value
        }
    }

    /// The subset of Notion's filter language the app uses.
    static func matches(_ page: JSONValue, _ filter: JSONValue) -> Bool {
        if let all = filter["and"]?.arrayValue { return all.allSatisfy { matches(page, $0) } }
        if let any = filter["or"]?.arrayValue { return any.contains { matches(page, $0) } }

        if filter["timestamp"]?.stringValue == "last_edited_time" {
            guard let floor = filter["last_edited_time"]?["on_or_after"]?.stringValue.flatMap(NotionDate.parseDateTime),
                  let edited = page["last_edited_time"]?.stringValue.flatMap(NotionDate.parseDateTime) else { return false }
            return edited >= floor
        }

        guard let name = filter["property"]?.stringValue else { return true }
        let value = page["properties"]?[name]
        if let status = filter["status"] {
            let current = value?["status"]?["name"]?.stringValue
            if let other = status["does_not_equal"]?.stringValue { return current != other }
            if let same = status["equals"]?.stringValue { return current == same }
        }
        if let wanted = filter["relation"]?["contains"]?.stringValue {
            return (value?["relation"]?.arrayValue ?? []).contains { $0["id"]?.stringValue == wanted }
        }
        if let floor = NotionDate.parse(filter["date"]?["on_or_after"]?.stringValue)?.day {
            guard let start = NotionDate.parse(value?["date"]?["start"]?.stringValue)?.day else { return false }
            return start >= floor
        }
        return true
    }

    private static func sort(_ pages: [JSONValue], by sort: JSONValue) -> [JSONValue] {
        let descending = sort["direction"]?.stringValue == "descending"
        func key(_ page: JSONValue) -> Date? {
            if sort["timestamp"]?.stringValue == "last_edited_time" {
                return page["last_edited_time"]?.stringValue.flatMap(NotionDate.parseDateTime)
            }
            guard let name = sort["property"]?.stringValue,
                  let parsed = NotionDate.parse(page["properties"]?[name]?["date"]?["start"]?.stringValue) else { return nil }
            return parsed.time ?? parsed.day.startOfDay
        }
        // Stable, with empty values last, like Notion.
        return pages.enumerated().sorted { a, b in
            switch (key(a.element), key(b.element)) {
            case let (x?, y?) where x != y: return descending ? x > y : x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.offset < b.offset
            }
        }.map(\.element)
    }

    /// Moves every date on a page by whole days.
    private static func shift(_ page: JSONValue, days: Int) -> JSONValue {
        guard days != 0 else { return page }
        var page = page
        for key in ["created_time", "last_edited_time"] {
            if let value = page[key]?.stringValue, let date = NotionDate.parseDateTime(value) {
                page[key] = .string(stamp(date.addingTimeInterval(Double(days) * 86_400)))
            }
        }
        var properties = page["properties"] ?? [:]
        for (name, property) in properties.objectValue ?? [:] {
            guard var date = property["date"], !date.isNull else { continue }
            var property = property
            for edge in ["start", "end"] {
                if let value = date[edge]?.stringValue {
                    date[edge] = .string(NotionDate.shift(value, days: days))
                }
            }
            property["date"] = date
            properties[name] = property
        }
        page["properties"] = properties
        return page
    }

    /// `2026-11-10T13:05:00.000Z`, the way Notion writes created and edited times.
    private static func stamp(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
}

/// The JSON files in `Resources/`: real-shaped replies to the two database queries.
enum Fixtures {
    /// The day the sample data was captured: Tue Nov 10, 2026.
    static let referenceDay = Day(year: 2026, month: 11, day: 10)

    /// 9:15 that morning, local time: after the 7:30 step (so it shows as late).
    static var referenceNow: Date {
        Day.calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 9, minute: 15)) ?? Date()
    }

    static func data(_ name: String) -> Data {
        for url in candidates(name) {
            if let data = try? Data(contentsOf: url) { return data }
        }
        return Data(#"{"object":"list","results":[],"has_more":false,"next_cursor":null}"#.utf8)
    }

    /// The `results` array of a fixture, as raw JSON pages.
    static func pages(_ name: String) -> [JSONValue] {
        JSONValue.parse(data(name))?["results"]?.arrayValue ?? []
    }

    private static func candidates(_ name: String) -> [URL] {
        var urls: [URL] = []
        // Inside the built .app.
        if let url = Bundle.main.url(forResource: name, withExtension: "json") { urls.append(url) }
        if let url = Bundle.main.url(forResource: name, withExtension: "json", subdirectory: "Resources") { urls.append(url) }
        // Running straight from the source tree (`swift run`, Xcode previews of the package).
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/\(name).json")
        urls.append(source)
        return urls
    }
}
