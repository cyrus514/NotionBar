import Foundation

/// A new task typed into the prompt, e.g. `+ read chapter 4 tomorrow 5pm #homework !high`.
struct QuickAddDraft: Equatable {
    var title: String = ""
    var day: Day?
    /// Set when the text included a time of day.
    var time: Date?
    var types: [String] = []
    var priority: String?
    /// `Prepare`, `Do` or `Prac`, when adding a step (`#prepare`, `#do`, `#prac`).
    var stepType: String?

    var isValid: Bool { !title.isEmpty }

    /// The due date the way Notion wants it: date-only, or date and time with the local offset.
    var dueString: String? {
        if let time { return NotionDate.string(from: time) }
        return day?.iso
    }

    /// One line describing what will be created, for the preview under the prompt.
    func summary(today: Day, asStep: Bool = false) -> String {
        if asStep {
            var parts = [Due(start: dueString, end: nil).map { Schedule.whenLabel($0, today: today) } ?? "no due date"]
            if let stepType { parts.append(stepType.lowercased()) }
            return parts.joined(separator: " · ")
        }
        var parts: [String] = []
        if let due = Due(start: dueString, end: nil) {
            parts.append("due " + Schedule.whenLabel(due, today: today))
        } else {
            parts.append("no due date")
        }
        if !types.isEmpty { parts.append(types.joined(separator: ", ")) }
        if let priority { parts.append("!" + priority.lowercased()) }
        return parts.joined(separator: " · ")
    }
}

enum QuickAdd {
    /// True when the prompt text is a new task rather than a filter.
    static func isAddCommand(_ text: String) -> Bool {
        text.hasPrefix("+")
    }

    private static let typeAliases: [String: String] = [
        "homework": "homework", "hw": "homework",
        "test": "test", "quiz": "test", "exam": "test",
        "project": "project", "proj": "project",
        "personal": "personal", "me": "personal",
    ]

    private static let stepAliases: [String: String] = [
        "prepare": "Prepare", "prep": "Prepare",
        "do": "Do",
        "prac": "Prac", "practice": "Prac",
    ]

    private static let priorityAliases: [String: String] = [
        "high": "High", "h": "High", "hi": "High",
        "medium": "Medium", "med": "Medium", "m": "Medium",
        "low": "Low", "l": "Low", "lo": "Low",
    ]

    /// Reads `+ title words [date words] [#type] [!priority]`.
    /// Dates are whatever macOS can recognise: `tomorrow`, `friday 7pm`, `nov 14 at 3:30pm`…
    static func parse(_ text: String) -> QuickAddDraft {
        var draft = QuickAddDraft()
        var words: [String] = []
        let body = text.hasPrefix("+") ? String(text.dropFirst()) : text

        for word in body.split(separator: " ", omittingEmptySubsequences: true).map(String.init) {
            if word.hasPrefix("#"), let type = typeAliases[String(word.dropFirst()).lowercased()] {
                if !draft.types.contains(type) { draft.types.append(type) }
            } else if word.hasPrefix("#"), let step = stepAliases[String(word.dropFirst()).lowercased()] {
                draft.stepType = step
            } else if word.hasPrefix("!"), let priority = priorityAliases[String(word.dropFirst()).lowercased()] {
                draft.priority = priority
            } else {
                words.append(word)
            }
        }

        var title = words.joined(separator: " ")
        if let found = detectDate(in: title) {
            draft.day = Day(found.date)
            draft.time = found.hasTime ? found.date : nil
            title.removeSubrange(found.range)
            title = tidy(title)
        }
        draft.title = title.trimmingCharacters(in: .whitespaces)
        return draft
    }

    private struct FoundDate {
        var date: Date
        var hasTime: Bool
        var range: Range<String.Index>
    }

    private static func detectDate(in text: String) -> FoundDate? {
        guard !text.isEmpty,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return nil }
        let whole = NSRange(text.startIndex..., in: text)
        // Take the last date in the text: "read chapter 4 friday" → friday.
        guard let match = detector.matches(in: text, options: [], range: whole).last,
              let start = match.date,
              let range = Range(match.range, in: text) else { return nil }
        // "due tomorrow at 5pm" comes back as a span from now until then: the end is the due time.
        let date = match.duration > 0 ? start.addingTimeInterval(match.duration) : start
        let phrase = text[range].lowercased()
        let timePattern = #"\d{1,2}\s*(am|pm|a\.m\.|p\.m\.)|\d{1,2}:\d{2}|\b(noon|midnight|tonight|morning|afternoon|evening)\b"#
        let hasTime = phrase.range(of: timePattern, options: .regularExpression) != nil
        return FoundDate(date: date, hasTime: hasTime, range: range)
    }

    /// Drops the little words left dangling once the date is cut out ("essay due" → "essay").
    private static func tidy(_ title: String) -> String {
        var words = title.split(separator: " ").map(String.init)
        let dangling: Set<String> = ["due", "by", "on", "at", "for", "before", "until", "-", "—", ","]
        while let last = words.last, dangling.contains(last.lowercased()) { words.removeLast() }
        while let first = words.first, [",", "-", "—"].contains(first) { words.removeFirst() }
        return words.joined(separator: " ")
    }
}
