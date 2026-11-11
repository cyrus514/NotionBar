import Foundation

/// A calendar day in the Mac's time zone, with no time of day.
/// (The Python plugin used `datetime.date` for the same job.)
struct Day: Hashable, Comparable, CustomStringConvertible, Sendable {
    let year: Int
    let month: Int
    let day: Int

    /// Gregorian calendar in the Mac's current time zone. Notion dates are always Gregorian,
    /// whatever calendar the Mac is set to.
    static let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .autoupdatingCurrent
        cal.locale = Locale(identifier: "en_US_POSIX")
        return cal
    }()

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// The local day that `date` falls on.
    init(_ date: Date) {
        let c = Day.calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1)
    }

    /// Parses the leading `YYYY-MM-DD` of a Notion date string.
    init?(iso: String) {
        let parts = iso.prefix(10).split(separator: "-")
        guard parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d) else { return nil }
        self.init(year: y, month: m, day: d)
    }

    /// Noon on this day. Used for arithmetic so daylight-saving jumps can't shift the date.
    var noon: Date {
        Day.calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) ?? Date()
    }

    /// The first moment of this day, local time.
    var startOfDay: Date {
        Day.calendar.startOfDay(for: noon)
    }

    func adding(_ days: Int) -> Day {
        Day(Day.calendar.date(byAdding: .day, value: days, to: noon) ?? noon)
    }

    /// Whole days from this day to `other` (negative if `other` is earlier).
    func days(to other: Day) -> Int {
        Day.calendar.dateComponents([.day], from: noon, to: other.noon).day ?? 0
    }

    /// 1 = Sunday … 7 = Saturday.
    var weekday: Int {
        Day.calendar.component(.weekday, from: noon)
    }

    /// `2026-11-10`, the form Notion uses for date-only values.
    var iso: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    var description: String { iso }

    static func < (a: Day, b: Day) -> Bool {
        (a.year, a.month, a.day) < (b.year, b.month, b.day)
    }
}

/// Parses and writes the date strings Notion uses.
enum NotionDate {
    /// Notion date string → (local day, local date-time or nil when it has no time).
    /// Port of `parse_when` in the plugin.
    static func parse(_ value: String?) -> (day: Day, time: Date?)? {
        guard let value, !value.isEmpty else { return nil }
        guard value.contains("T") else {
            return Day(iso: value).map { ($0, nil) }
        }
        if let date = parseDateTime(value) {
            return (Day(date), date)
        }
        // A time we can't read: keep the day so the item still lands in a section.
        return Day(iso: value).map { ($0, nil) }
    }

    static func parseDateTime(_ value: String) -> Date? {
        if hasTimeZone(value) {
            for parser in zonedParsers {
                if let date = parser.date(from: value) { return date }
            }
            for format in ["yyyy-MM-dd'T'HH:mmXXXXX", "yyyy-MM-dd'T'HH:mm:ssXXXXX", "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX"] {
                if let date = formatter(format).date(from: value) { return date }
            }
            return nil
        }
        // No offset: treat it as local time, like Python's naive datetime.
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm"] {
            if let date = formatter(format).date(from: value) { return date }
        }
        return nil
    }

    /// `2026-11-10T19:30:00.000-05:00`, written in the Mac's time zone.
    static func string(from date: Date) -> String {
        formatter("yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX").string(from: date)
    }

    /// Moves a Notion date string by whole days, keeping its shape:
    /// a date-only value stays date-only, a timed value keeps its local time of day.
    static func shift(_ value: String, days: Int) -> String {
        guard days != 0, let parsed = parse(value) else { return value }
        let target = parsed.day.adding(days)
        guard let time = parsed.time else { return target.iso }
        return string(from: moving(time, to: target))
    }

    /// Same local time of day, on another day.
    static func moving(_ time: Date, to day: Day) -> Date {
        let t = Day.calendar.dateComponents([.hour, .minute, .second], from: time)
        let c = DateComponents(year: day.year, month: day.month, day: day.day,
                               hour: t.hour, minute: t.minute, second: t.second)
        return Day.calendar.date(from: c) ?? time
    }

    private static func hasTimeZone(_ value: String) -> Bool {
        guard let t = value.firstIndex(of: "T") else { return false }
        let tail = value[value.index(after: t)...]
        return tail.hasSuffix("Z") || tail.contains("+") || tail.contains("-")
    }

    private static let zonedParsers: [ISO8601DateFormatter] = {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return [fractional, plain]
    }()

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.calendar = Day.calendar
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .autoupdatingCurrent
        f.dateFormat = format
        return f
    }
}

/// When an item is due. Port of `due_info` in the plugin.
struct Due: Hashable, Sendable {
    /// The day it starts (shown in labels).
    let start: Day
    /// The day it ends (decides whether it's overdue). Same as `start` unless it's a range.
    let end: Day
    /// The start date-time, when the Notion value includes a time.
    let time: Date?
    /// The strings exactly as Notion sent them, kept so the date can be moved later.
    let rawStart: String
    let rawEnd: String?

    init?(start rawStart: String?, end rawEnd: String?) {
        guard let rawStart, let parsedStart = NotionDate.parse(rawStart) else { return nil }
        self.start = parsedStart.day
        self.time = parsedStart.time
        self.end = NotionDate.parse(rawEnd)?.day ?? parsedStart.day
        self.rawStart = rawStart
        self.rawEnd = (rawEnd?.isEmpty ?? true) ? nil : rawEnd
    }

    /// The same due date moved by whole days.
    func shifted(days: Int) -> Due {
        Due(start: NotionDate.shift(rawStart, days: days),
            end: rawEnd.map { NotionDate.shift($0, days: days) }) ?? self
    }
}
