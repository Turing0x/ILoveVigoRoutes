import Testing
import Foundation
@testable import VigoCore

@Suite("Service times and dates")
struct ServiceTimeTests {

    @Test("Parses an ordinary time")
    func ordinary() throws {
        let t = try #require(ServiceTime(gtfs: "05:00:00"))
        #expect(t.secondsSinceServiceDayStart == 18_000)
        #expect(t.clockDescription == "05:00")
        #expect(!t.rollsPastMidnight)
    }

    /// The real feed contains 1773 stop times at or past 24:00:00, the latest being
    /// 30:31:00. A `HH:mm:ss` DateFormatter returns nil for all of them, which would drop
    /// every late-night departure without any error surfacing.
    @Test("Parses times past midnight", arguments: [
        ("24:00:00", 86_400, "00:00"),
        ("25:30:00", 91_800, "01:30"),
        ("30:31:00", 109_860, "06:31"),
    ])
    func pastMidnight(input: String, seconds: Int, clock: String) throws {
        let t = try #require(ServiceTime(gtfs: input))
        #expect(t.secondsSinceServiceDayStart == seconds)
        #expect(t.clockDescription == clock)
        #expect(t.rollsPastMidnight)
    }

    @Test("Accepts a single-digit hour")
    func singleDigitHour() throws {
        #expect(ServiceTime(gtfs: "5:07:00")?.secondsSinceServiceDayStart == 18_420)
    }

    @Test("Rejects malformed input instead of coercing it", arguments: [
        "", "5:00", "05:00:00:00", "aa:bb:cc", "05:60:00", "05:00:60", "05:0:00", ":00:00",
    ])
    func rejectsMalformed(input: String) {
        #expect(ServiceTime(gtfs: input) == nil)
    }

    @Test("Orders correctly across midnight")
    func ordering() throws {
        let late = try #require(ServiceTime(gtfs: "25:00:00"))
        let early = try #require(ServiceTime(gtfs: "23:00:00"))
        #expect(early < late)
    }

    @Test("Parses feed dates")
    func dates() throws {
        let d = try #require(ServiceDate(gtfs: "20260904"))
        #expect(d.year == 2026 && d.month == 9 && d.day == 4)
        #expect(ServiceDate(gtfs: "2026090") == nil)
        #expect(ServiceDate(gtfs: "") == nil)
    }

    @Test("Maps to GTFS weekday columns with Monday first")
    func weekday() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Madrid")!
        // 2026-09-04 is a Friday, index 4 in a Monday-first table.
        #expect(ServiceDate(yyyymmdd: 20_260_904).gtfsWeekdayIndex(calendar: cal) == 4)
        // 2026-09-06 is a Sunday, index 6.
        #expect(ServiceDate(yyyymmdd: 20_260_906).gtfsWeekdayIndex(calendar: cal) == 6)
        // 2026-09-07 is a Monday, index 0.
        #expect(ServiceDate(yyyymmdd: 20_260_907).gtfsWeekdayIndex(calendar: cal) == 0)
    }

    @Test("Moves across a month boundary")
    func addingDays() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Madrid")!
        let d = ServiceDate(yyyymmdd: 20_260_901)
        #expect(d.adding(days: -1, calendar: cal)?.yyyymmdd == 20_260_831)
    }
}
