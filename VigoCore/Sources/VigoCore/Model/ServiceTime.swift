import Foundation

/// A GTFS time, stored as **seconds since the start of the service day** — not as a
/// wall-clock time.
///
/// This distinction is load-bearing. The Vitrasa feed contains 1773 stop times at or
/// past `24:00:00`, running up to `30:31:00` (a 06:31 bus belonging to the previous
/// service day). Parsing those with a `HH:mm:ss` date formatter fails, and it fails
/// silently on exactly the late-night trips a transit app is most useful for.
public struct ServiceTime: Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    /// Seconds elapsed since 00:00:00 of the service day. May exceed 86400.
    public let secondsSinceServiceDayStart: Int

    public init(seconds: Int) { self.secondsSinceServiceDayStart = seconds }

    public init(hours: Int, minutes: Int, seconds: Int) {
        self.secondsSinceServiceDayStart = hours * 3600 + minutes * 60 + seconds
    }

    /// Parses a GTFS `HH:MM:SS` value. Accepts hour values above 23 and a missing
    /// leading zero (`5:00:00`), both of which are legal GTFS.
    ///
    /// Returns `nil` for anything malformed rather than silently coercing, so that a
    /// feed regression surfaces as a parse error instead of a wrong departure time.
    public init?(gtfs text: some StringProtocol) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let h = Int(parts[0]), let m = Int(parts[1]), let s = Int(parts[2]),
              !parts[0].isEmpty, parts[1].count == 2, parts[2].count == 2,
              h >= 0, (0...59).contains(m), (0...59).contains(s)
        else { return nil }
        self.secondsSinceServiceDayStart = h * 3600 + m * 60 + s
    }

    public var hours: Int { secondsSinceServiceDayStart / 3600 }
    public var minutes: Int { (secondsSinceServiceDayStart % 3600) / 60 }
    public var seconds: Int { secondsSinceServiceDayStart % 60 }

    /// True when this time belongs to the small hours of the *following* calendar day.
    public var rollsPastMidnight: Bool { secondsSinceServiceDayStart >= 86_400 }

    /// Wall-clock rendering, wrapping past midnight: `30:31:00` shows as `06:31`.
    public var clockDescription: String {
        let h = (secondsSinceServiceDayStart / 3600) % 24
        return String(format: "%02d:%02d", h, minutes)
    }

    public var description: String {
        String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    public static func < (a: Self, b: Self) -> Bool {
        a.secondsSinceServiceDayStart < b.secondsSinceServiceDayStart
    }

    // Stored as a bare integer count of seconds.
    public init(from decoder: any Decoder) throws {
        secondsSinceServiceDayStart = try decoder.singleValueContainer().decode(Int.self)
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer(); try c.encode(secondsSinceServiceDayStart)
    }

    /// Resolves this service time to an absolute instant on a given service day.
    public func date(onServiceDay day: ServiceDate, calendar: Calendar) -> Date? {
        guard let midnight = day.startOfDay(in: calendar) else { return nil }
        return midnight.addingTimeInterval(TimeInterval(secondsSinceServiceDayStart))
    }
}

/// A GTFS calendar date, stored in the feed's own `YYYYMMDD` integer form.
public struct ServiceDate: Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    /// `YYYYMMDD`, e.g. `20260904`.
    public let yyyymmdd: Int

    public init(yyyymmdd: Int) { self.yyyymmdd = yyyymmdd }

    public init?(gtfs text: some StringProtocol) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count == 8, let value = Int(trimmed) else { return nil }
        self.yyyymmdd = value
    }

    public init(_ date: Date, calendar: Calendar) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.yyyymmdd = (c.year ?? 0) * 10_000 + (c.month ?? 0) * 100 + (c.day ?? 0)
    }

    public var year: Int { yyyymmdd / 10_000 }
    public var month: Int { (yyyymmdd / 100) % 100 }
    public var day: Int { yyyymmdd % 100 }

    public func startOfDay(in calendar: Calendar) -> Date? {
        calendar.date(from: DateComponents(year: year, month: month, day: day))
    }

    public func adding(days: Int, calendar: Calendar) -> ServiceDate? {
        guard let start = startOfDay(in: calendar),
              let moved = calendar.date(byAdding: .day, value: days, to: start)
        else { return nil }
        return ServiceDate(moved, calendar: calendar)
    }

    /// GTFS weekday column order: Monday is 0 … Sunday is 6.
    public func gtfsWeekdayIndex(calendar: Calendar) -> Int? {
        guard let start = startOfDay(in: calendar) else { return nil }
        // Calendar.component(.weekday) is 1 = Sunday … 7 = Saturday.
        return (calendar.component(.weekday, from: start) + 5) % 7
    }

    public var description: String { String(yyyymmdd) }

    public static func < (a: Self, b: Self) -> Bool { a.yyyymmdd < b.yyyymmdd }

    // Stored as a bare YYYYMMDD integer.
    public init(from decoder: any Decoder) throws {
        yyyymmdd = try decoder.singleValueContainer().decode(Int.self)
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer(); try c.encode(yyyymmdd)
    }
}

extension ServiceDate {
    /// `DD/MM/YYYY`. Lives here rather than in the app because `PlanOutcomeMessage` needs it
    /// to say which days the feed actually covers, and a seven-day window is useless
    /// information without its dates.
    public var humanReadable: String {
        String(format: "%02d/%02d/%04d", day, month, year)
    }
}
