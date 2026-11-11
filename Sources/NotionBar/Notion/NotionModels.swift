import Foundation

/// The two Notion databases the app reads. They are set in Settings and saved on this Mac,
/// never in the source. The integration must be connected to both (in Notion: ••• → Connections).
struct NotionConfig: Sendable, Equatable {
    /// Task Tracker: tests, homework, projects.
    var tasksDatabase = ""
    /// Its data source, for the newer API. Empty = use the older database endpoint.
    var tasksDataSource = ""
    /// Steps database: Prepare / Do / Prac steps, each related to a task.
    var stepsDatabase = ""
    var stepsDataSource = ""

    var apiBase = URL(string: "https://api.notion.com/v1")!
    /// Current API, with data sources.
    var version = "2025-09-03"
    /// Older API, used when there is no data source id or the newer endpoint refuses.
    var legacyVersion = "2022-06-28"

    /// Both databases have been filled in.
    var isComplete: Bool { !tasksDatabase.isEmpty && !stepsDatabase.isEmpty }

    /// Made-up ids for the bundled sample data (demo mode, self-test, snapshots, previews).
    static let sample = NotionConfig(
        tasksDatabase: "aaaaaaaa-0000-4000-8000-000000000001",
        tasksDataSource: "aaaaaaaa-0000-4000-8000-000000000002",
        stepsDatabase: "bbbbbbbb-0000-4000-8000-000000000001",
        stepsDataSource: "bbbbbbbb-0000-4000-8000-000000000002")

    /// Pulls a database id out of whatever was pasted: a bare id, with or without dashes,
    /// or a Notion link such as `https://www.notion.so/Task-Tracker-3cd0…16c?v=…`.
    /// Returns it in the dashed form the API uses, or nil if there is no id in the text.
    static func normalizeID(_ text: String) -> String? {
        // Ignore anything after "?" (a link's view id is also 32 hex digits).
        let head = text.split(separator: "?", maxSplits: 1).first.map(String.init) ?? text
        let hex = head.lowercased().filter { $0.isHexDigit || $0 == "-" }.replacingOccurrences(of: "-", with: "")
        guard hex.count >= 32 else { return nil }
        // In a link the id is the last 32 hex digits of the path.
        let id = Array(hex.suffix(32))
        let parts = [id[0..<8], id[8..<12], id[12..<16], id[16..<20], id[20..<32]]
        return parts.map { String($0) }.joined(separator: "-")
    }
}

// MARK: - Responses

/// The reply to a query: one page of results.
struct NotionList: Codable, Sendable {
    var results: [NotionPage]
    var hasMore: Bool
    var nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case results
        case hasMore = "has_more"
        case nextCursor = "next_cursor"
    }

    init(results: [NotionPage], hasMore: Bool = false, nextCursor: String? = nil) {
        self.results = results
        self.hasMore = hasMore
        self.nextCursor = nextCursor
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // One odd page shouldn't sink the whole list: skip anything that won't decode.
        results = try c.decode([Lossy<NotionPage>].self, forKey: .results).compactMap(\.value)
        hasMore = (try? c.decode(Bool.self, forKey: .hasMore)) ?? false
        nextCursor = try? c.decodeIfPresent(String.self, forKey: .nextCursor)
    }
}

/// Decodes to nil instead of throwing.
struct Lossy<T: Codable & Sendable>: Codable, Sendable {
    let value: T?

    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }

    func encode(to encoder: Encoder) throws {
        try value?.encode(to: encoder)
    }
}

struct NotionPage: Codable, Identifiable, Sendable {
    var id: String
    var properties: [String: NotionProperty]
    var lastEditedTime: String?

    enum CodingKeys: String, CodingKey {
        case id, properties
        case lastEditedTime = "last_edited_time"
    }

    /// The page title: the named property if it's there, otherwise whichever property is the title.
    func title(preferring name: String) -> String {
        let parts = properties[name]?.title ?? properties.values.first(where: { $0.type == "title" })?.title ?? []
        return ItemBuilder.clean(parts.map { $0.plainText ?? "" }.joined())
    }

    func due(_ name: String) -> Due? {
        guard let date = properties[name]?.date else { return nil }
        return Due(start: date.start, end: date.end)
    }
}

/// One property value. Notion puts the value under a key named after its type,
/// so every kind the app cares about is optional here and the rest are ignored.
struct NotionProperty: Codable, Sendable {
    var type: String?
    var title: [NotionRichText]?
    var status: NotionOption?
    var select: NotionOption?
    var multiSelect: [NotionOption]?
    var date: NotionDateValue?
    var relation: [NotionReference]?

    enum CodingKeys: String, CodingKey {
        case type, title, status, select, date, relation
        case multiSelect = "multi_select"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try? c.decodeIfPresent(String.self, forKey: .type)
        title = try? c.decodeIfPresent([NotionRichText].self, forKey: .title)
        status = try? c.decodeIfPresent(NotionOption.self, forKey: .status)
        select = try? c.decodeIfPresent(NotionOption.self, forKey: .select)
        multiSelect = try? c.decodeIfPresent([NotionOption].self, forKey: .multiSelect)
        date = try? c.decodeIfPresent(NotionDateValue.self, forKey: .date)
        relation = try? c.decodeIfPresent([NotionReference].self, forKey: .relation)
    }
}

struct NotionRichText: Codable, Sendable {
    var plainText: String?

    enum CodingKeys: String, CodingKey {
        case plainText = "plain_text"
    }
}

/// A status, select or multi-select option.
struct NotionOption: Codable, Sendable {
    var name: String
}

struct NotionDateValue: Codable, Sendable {
    var start: String?
    var end: String?
}

struct NotionReference: Codable, Sendable {
    var id: String
}

/// The body Notion sends with an error status.
struct NotionErrorBody: Codable {
    var status: Int?
    var code: String?
    var message: String?
}

struct NotionUser: Codable {
    var name: String?
    var type: String?
}

// MARK: - Errors

enum NotionError: Error, Equatable {
    /// No token saved yet.
    case missingToken
    /// Notion answered with an error status.
    case http(status: Int, message: String)
    /// The request never got an answer (offline, DNS, timeout…).
    case network(String)
    /// The answer wasn't what we expected.
    case badResponse(String)

    var isUnauthorized: Bool {
        if case .http(let status, _) = self { return status == 401 }
        return false
    }

    var isNotFound: Bool {
        if case .http(let status, let message) = self {
            return status == 404 || message.contains("Could not find")
        }
        return false
    }

    var isNetwork: Bool {
        if case .network = self { return true }
        return false
    }

    /// One line, safe to show. Never includes the token.
    var message: String {
        switch self {
        case .missingToken: return "no token yet"
        case .http(let status, let message): return message.isEmpty ? "HTTP \(status)" : "HTTP \(status) \(message)"
        case .network(let reason): return "can't reach notion (\(reason))"
        case .badResponse(let reason): return "unexpected reply from notion (\(reason))"
        }
    }
}
