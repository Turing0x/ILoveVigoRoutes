import Foundation

/// Which days Vitrasa runs a holiday timetable on.
///
/// **This exists only to keep the calendar projection honest**, and it is worth being precise
/// about why. When the feed's seven-day window does not reach the day being asked about,
/// `ServiceDayResolver` reuses the most recent day of the same weekday. That rule is right
/// for an ordinary Tuesday and wrong for a Tuesday that happens to be the 25th of December,
/// when the buses run a Sunday service. Without this calendar the projection would confidently
/// promise a full weekday timetable on a day the city half shuts down.
///
/// It cuts both ways, which is easy to miss: a holiday *inside* the observed window must also
/// be refused as a **template**, or a captured week containing the 12th of October would
/// propagate holiday service to every Monday for the next two months.
///
/// ## What is trustworthy here, and what is not
///
/// Three tiers, and they are not equally certain:
///
/// - **Fixed national and Galician holidays** are set in law and stable year to year. High
///   confidence.
/// - **Easter-derived holidays** (Holy Thursday, Good Friday) are computed, not tabulated, so
///   they are exact for any year. High confidence.
/// - **Local Vigo holidays** are fixed annually by the Concello and published in the DOG.
///   They move, and they cannot be derived. **This list needs a human check every year** —
///   `Resources/holidays-vigo.json` is where it lives and `local` is the field to edit.
///
/// The containment that makes an imperfect list acceptable: a holiday this calendar gets
/// wrong can only affect a day that is *already* being projected, and every projected day is
/// already labelled an estimate in the UI. A wrong entry degrades an answer that was never
/// presented as firm. It can never touch a day the feed actually covers, because observed
/// data is never projected in the first place.
public struct HolidayCalendar: Sendable, Hashable {

    /// Explicit dates, one per occurrence. Both the fixed rules and the computed
    /// Easter-derived days are expanded into this at load time, so a lookup is one hash.
    private let dates: Set<ServiceDate>

    /// The years this calendar was expanded for. Outside them it knows nothing, and saying so
    /// is different from saying "not a holiday" — see `covers(year:)`.
    public let years: ClosedRange<Int>

    public init(dates: Set<ServiceDate>, years: ClosedRange<Int>) {
        self.dates = dates
        self.years = years
    }

    /// Knows nothing about any year. Every lookup answers "not a holiday", which makes the
    /// projection behave exactly as it would have without this type at all.
    public static let empty = HolidayCalendar(dates: [], years: 0...0)

    public var count: Int { dates.count }

    public func isHoliday(_ date: ServiceDate) -> Bool { dates.contains(date) }

    /// Whether this calendar has anything to say about a year.
    ///
    /// A projection that reaches past the last expanded year is projecting blind: it cannot
    /// tell an ordinary Tuesday from Christmas. `ServiceDayResolver` refuses rather than
    /// guessing, which is why this is public.
    public func covers(year: Int) -> Bool { years.contains(year) }

    public func covers(_ date: ServiceDate) -> Bool { covers(year: date.year) }

    // MARK: - Easter

    /// Easter Sunday, by the anonymous Gregorian algorithm (Meeus/Jones/Butcher).
    ///
    /// Computed rather than tabulated: a table would be one more thing to get wrong every
    /// year, and this is exact for every Gregorian year. Holy Thursday and Good Friday — the
    /// two that matter for a bus timetable — are three and two days before it.
    public static func easterSunday(year: Int) -> ServiceDate {
        let a = year % 19
        let b = year / 100
        let c = year % 100
        let d = b / 4
        let e = b % 4
        let f = (b + 8) / 25
        let g = (b - f + 1) / 3
        let h = (19 * a + b - d - g + 15) % 30
        let i = c / 4
        let k = c % 4
        let l = (32 + 2 * e + 2 * i - h - k) % 7
        let m = (a + 11 * h + 22 * l) / 451
        let month = (h + l - 7 * m + 114) / 31
        let day = ((h + l - 7 * m + 114) % 31) + 1
        return ServiceDate(yyyymmdd: year * 10_000 + month * 100 + day)
    }

    // MARK: - Loading

    /// The shape of `holidays-vigo.json`.
    struct Definition: Decodable {
        struct MonthDay: Decodable {
            let month: Int
            let day: Int
            let name: String
        }
        struct Dated: Decodable {
            let date: Int
            let name: String
        }
        /// Same date every year: national and Galician statutory holidays.
        let fixed: [MonthDay]
        /// Offsets in days from Easter Sunday. Negative is before.
        let easterOffsets: [EasterOffset]
        /// One-off dates. Local Vigo holidays live here, and they expire.
        let local: [Dated]
        let firstYear: Int
        let lastYear: Int

        struct EasterOffset: Decodable {
            let offset: Int
            let name: String
        }
    }

    public enum LoadError: Error, CustomStringConvertible, Sendable {
        case malformed(String)
        public var description: String {
            switch self {
            case .malformed(let reason): "holidays-vigo.json: \(reason)"
            }
        }
    }

    public static func load(json data: Data, calendar: Calendar) throws -> HolidayCalendar {
        let definition: Definition
        do {
            definition = try JSONDecoder().decode(Definition.self, from: data)
        } catch {
            throw LoadError.malformed("\(error)")
        }
        guard definition.firstYear <= definition.lastYear else {
            throw LoadError.malformed("firstYear \(definition.firstYear) is after lastYear \(definition.lastYear)")
        }

        var dates = Set<ServiceDate>()
        for year in definition.firstYear...definition.lastYear {
            for rule in definition.fixed {
                guard (1...12).contains(rule.month), (1...31).contains(rule.day) else {
                    throw LoadError.malformed("'\(rule.name)' is not a real date: \(rule.month)/\(rule.day)")
                }
                dates.insert(ServiceDate(yyyymmdd: year * 10_000 + rule.month * 100 + rule.day))
            }
            let easter = easterSunday(year: year)
            for rule in definition.easterOffsets {
                guard let moved = easter.adding(days: rule.offset, calendar: calendar) else {
                    throw LoadError.malformed("'\(rule.name)' at offset \(rule.offset) is undatable")
                }
                dates.insert(moved)
            }
        }
        // Local entries are dated outright, and are kept even if they fall outside the
        // expanded range: a stale one is inert, and dropping it silently would hide an
        // out-of-date file rather than make it obvious.
        for entry in definition.local {
            dates.insert(ServiceDate(yyyymmdd: entry.date))
        }

        return HolidayCalendar(dates: dates,
                               years: definition.firstYear...definition.lastYear)
    }

    /// The calendar shipped with the package, or `.empty` when the resource is missing.
    ///
    /// Degrading to `.empty` rather than trapping is the same trade `FootpathTable.bundled`
    /// makes, and it is safe for the same reason: without a holiday calendar the projection
    /// is no worse than it was before this file existed. `HolidayCalendarTests` is the alarm
    /// that keeps the degradation from being silent.
    public static let bundled: HolidayCalendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Madrid") ?? .gmt
        guard let url = Bundle.module.url(forResource: "holidays-vigo", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let loaded = try? load(json: data, calendar: calendar)
        else { return .empty }
        return loaded
    }()
}
