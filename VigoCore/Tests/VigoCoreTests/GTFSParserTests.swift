import Testing
import Foundation
@testable import VigoCore

@Suite("GTFS parser")
struct GTFSParserTests {

    @Test("Parses the whole fixture feed")
    func parsesFeed() throws {
        let result = try GTFSParser().parse(from: Fixture.provider)
        let feed = result.feed
        #expect(feed.stops.count == 4)
        #expect(feed.routes.count == 4)
        #expect(feed.trips.count == 3)
        #expect(feed.stopTimes.count == 6)
        #expect(feed.calendarDates.count == 3)
        #expect(feed.calendar.isEmpty)      // calendar.txt has a header and no rows
        #expect(feed.shapePoints.count == 2)
        #expect(feed.agencies.first?.timeZone == "Europe/Madrid")
    }

    /// The single most dangerous mapping in the project: the realtime API keys on the
    /// numeric part of stop_code, not on stop_id. Getting it wrong returns HTTP 200 with
    /// an empty body, so nothing fails — the stop just looks like it has no buses.
    @Test("Derives the realtime code from stop_code, not stop_id", arguments: [
        ("3493", "P006930", 6930),
        ("3885", "P0014264", 14264),
        ("4856", "PA20113", 20113),
    ])
    func vitrasaCodeDerivation(stopID: String, code: String, expected: Int) throws {
        let feed = try Fixture.parsedFeed()
        let stop = try #require(feed.stops.first { $0.id == StopID(stopID) })
        #expect(stop.gtfsStopCode == code)
        #expect(stop.vitrasaCode == VitrasaStopCode(expected))
        #expect(stop.vitrasaCode?.value != Int(stopID), "the two identifiers must not be conflated")
    }

    @Test("A stop with no code parses but is flagged as having no realtime")
    func stopWithoutCode() throws {
        let result = try GTFSParser().parse(from: Fixture.provider)
        let stop = try #require(result.feed.stops.first { $0.id == StopID("9999") })
        #expect(stop.vitrasaCode == nil)
        #expect(result.warnings.contains { $0.message.contains("no usable stop_code") })
    }

    @Test("Trims the tab that the feed puts in route 18A's long name")
    func trimsRouteName() throws {
        let feed = try Fixture.parsedFeed()
        let route = try #require(feed.routes.first { $0.id == RouteID("18") })
        #expect(route.longName == "AREAL/COLÓN - SÁRDOMA/POULEIRA")
        #expect(!route.longName.hasPrefix("\t"))
    }

    @Test("Keeps service ids that contain double spaces intact")
    func serviceIDsWithSpaces() throws {
        let feed = try Fixture.parsedFeed()
        #expect(feed.calendarDates.contains { $0.serviceID == ServiceID("A  01LP001_008001") })
    }

    @Test("Folds accents for search")
    func searchName() throws {
        let feed = try Fixture.parsedFeed()
        let stop = try #require(feed.stops.first { $0.id == StopID("3493") })
        #expect(stop.name == "Praza de América  1")
        #expect(stop.searchName == "praza de america 1", "accents folded and double spaces collapsed")
    }

    @Test("Keeps a stop time past midnight")
    func pastMidnightPreserved() throws {
        let feed = try Fixture.parsedFeed()
        let st = try #require(feed.stopTimes.first { $0.tripID == TripID("T_NIGHT_1") })
        #expect(st.departure.secondsSinceServiceDayStart == 90_600)
        #expect(st.departure.rollsPastMidnight)
    }

    @Test("Reports the service window")
    func serviceWindow() throws {
        let window = try #require(Fixture.parsedFeed().serviceWindow)
        #expect(window.lowerBound == ServiceDate(yyyymmdd: 20_260_904))
        #expect(window.upperBound == ServiceDate(yyyymmdd: 20_260_906))
    }

    @Test("Missing a required file throws")
    func missingRequiredFile() {
        let provider = GTFSInMemory(texts: ["stops.txt": Fixture.stops])
        #expect(throws: GTFSParseError.self) { try GTFSParser().parse(from: provider) }
    }

    /// A row with an unreadable time is dropped and reported. Defaulting it to midnight
    /// would put a phantom departure at the top of the list.
    @Test("Drops and reports unparsable times rather than defaulting them")
    func unparsableTimeIsReported() throws {
        var texts = [
            "stops.txt": Fixture.stops, "routes.txt": Fixture.routes,
            "trips.txt": Fixture.trips, "calendar_dates.txt": Fixture.calendarDates,
        ]
        texts["stop_times.txt"] = """
        trip_id,arrival_time,departure_time,stop_id,stop_sequence
        T_DAY_1,08:00:00,08:00:00,3493,1
        T_DAY_1,notatime,notatime,3885,2
        """
        let result = try GTFSParser().parse(from: GTFSInMemory(texts: texts))
        #expect(result.feed.stopTimes.count == 1)
        #expect(result.warnings.contains { $0.message.contains("unparsable time") })
    }

    @Test("A feed with no service at all is reported")
    func noServiceWarning() throws {
        var texts = [
            "stops.txt": Fixture.stops, "routes.txt": Fixture.routes,
            "trips.txt": Fixture.trips, "stop_times.txt": Fixture.stopTimes,
        ]
        texts["calendar.txt"] = Fixture.calendar
        let result = try GTFSParser().parse(from: GTFSInMemory(texts: texts))
        #expect(result.warnings.contains { $0.message.contains("defines no service") })
    }
}
