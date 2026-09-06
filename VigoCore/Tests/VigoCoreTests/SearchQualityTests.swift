import Testing
import Foundation
@testable import VigoCore

/// A second, small feed dedicated to `searchStops` correctness — deliberately not the
/// shared `Fixture`, whose four stops (and `GTFSParserTests`/`RepositoryTests` counting
/// them) cannot grow without touching tests this file has no business touching. Every stop
/// name and code below is chosen to isolate one specific behaviour: see the comment on each
/// test for which.
private enum SearchQualityFixture {
    static let stops = """
    stop_id,stop_code,stop_name,stop_lat,stop_lon,wheelchair_boarding
    Q1,Q000001,Terminal Central,42.20,-8.70,1
    Q2,Q000088,Rúa Nova  1,42.20,-8.70,1
    Q3,Q000300,Coruña  Zona Vella,42.20,-8.70,1
    Q4,Q000301,Avenida da Coruña,42.20,-8.70,1
    Q5,Q000302,Rúa de Barcelona  Hospital Ribera Povisa,42.20,-8.70,1
    Q6,Q000303,Zona Coiro,42.20,-8.70,1
    Q7,Q000304,Zona Escoita,42.20,-8.70,1
    Q8,Q000020,Praza Vinte,42.20,-8.70,1
    Q9,Q002050,Praza Vinte Cincuenta,42.20,-8.70,1
    """

    static let routes = """
    route_id,agency_id,route_short_name,route_long_name,route_type,route_color,route_text_color
    1,1,C1,CIRCULAR CENTRO,3,ED4713,000000
    """

    static let trips = """
    route_id,service_id,trip_id,trip_headsign,direction_id,block_id,shape_id
    1,SVC1,T1,TERMINAL,0,B1,
    """

    static let stopTimes = """
    trip_id,arrival_time,departure_time,stop_id,stop_sequence,pickup_type,drop_off_type
    T1,08:00:00,08:00:00,Q1,1,0,0
    T1,08:10:00,08:10:00,Q2,2,0,0
    """

    static let calendar = """
    service_id, monday, tuesday, wednesday, thursday, friday, saturday, sunday, start_date, end_date
    """

    static let calendarDates = """
    service_id,date,exception_type
    SVC1,20260904,1
    """

    static let agency = """
    agency_id,agency_name,agency_url,agency_timezone,agency_lang
    1,Viguesa de Transportes S.L.,http://www.vitrasa.es/,Europe/Madrid,es
    """

    static var provider: GTFSInMemory {
        GTFSInMemory(texts: [
            "agency.txt": agency,
            "stops.txt": stops,
            "routes.txt": routes,
            "trips.txt": trips,
            "stop_times.txt": stopTimes,
            "calendar.txt": calendar,
            "calendar_dates.txt": calendarDates,
        ])
    }

    static func importedDatabase() throws -> AppDatabase {
        let db = try AppDatabase.inMemory()
        let result = try GTFSParser().parse(from: provider)
        _ = try GTFSImporter(database: db).import(feed: result.feed, parseWarnings: result.warnings)
        return db
    }
}

@Suite("Calidad del emparejamiento de searchStops")
struct SearchQualityTests {

    /// H-04: a numeric hit used to short-circuit `searchStops` and return before the name
    /// search ever ran. Stop Q1 has the exact code `1`; stop Q2's *name* ("Rúa Nova  1")
    /// also contains the digit `1`, but only the name search can find it. The old code
    /// returned just Q1; the merge has to return both.
    @Test("A numeric hit is merged with name matches, not returned alone")
    func numericSearchMergesWithNameMatches() throws {
        let repository = TransitRepository(database: try SearchQualityFixture.importedDatabase())
        let hits = try repository.searchStops("1")
        #expect(Set(hits.map(\.id)) == [StopID("Q1"), StopID("Q2")])
        #expect(hits.first?.id == StopID("Q1"), "the exact code match still leads")
    }

    /// H-02/H-03, at a scale the shared fixture cannot provide: code `20` (an exact match)
    /// and code `2050` (a prefix match) coexist, so a leading zero and a small `limit` both
    /// have something real to bite on.
    @Test("Leading zero and limit hold for a query with both an exact and a prefix hit")
    func numericExactAndPrefixTogetherRespectLimitAndLeadingZero() throws {
        let repository = TransitRepository(database: try SearchQualityFixture.importedDatabase())

        let plain = try repository.searchStops("20")
        #expect(Set(plain.map(\.id)) == [StopID("Q8"), StopID("Q9")], "exact 20 plus prefix 2050")

        // H-03: the old prefix pattern was built from the raw digits, so "020" would fail
        // to match a stored code that has never carried a leading zero.
        let leadingZero = try repository.searchStops("020")
        #expect(Set(leadingZero.map(\.id)) == Set(plain.map(\.id)))

        // H-02: the old code summed `exact + prefix` after the SQL-level `.limit()`, so an
        // exact hit could push the merged count past `limit` on its own.
        #expect(try repository.searchStops("20", limit: 1).count == 1)
    }

    /// H-40: "coruna" has to put "Coruña  Zona Vella" (the name starts with it) above
    /// "Avenida da Coruña" (the name only contains it) — the tier the old code never had a
    /// test for. The names are deliberately adversarial to plain alphabetical order too
    /// ("avenida..." sorts before "coruna..." on the letter alone): a mutation that merges
    /// the two tiers and sorts only by name would put Q4 first, not Q3, so this cannot pass
    /// by accident of the alphabet.
    @Test("A name-prefix match ranks above a name-contains match")
    func prefixTierOutranksContainsTier() throws {
        let repository = TransitRepository(database: try SearchQualityFixture.importedDatabase())
        let hits = try repository.searchStops("coruna")
        #expect(hits.map(\.id) == [StopID("Q3"), StopID("Q4")])
    }

    /// H-09: neither word order nor contiguity should matter once every term is required to
    /// appear somewhere. Mirrors the real feed's "Rúa de Barcelona  Hospital Ribera Povisa",
    /// where "hospital" and "povisa" are neither adjacent nor first-to-last in that order.
    @Test("Reordered, non-adjacent terms still find the stop")
    func termsMatchRegardlessOfOrder() throws {
        let repository = TransitRepository(database: try SearchQualityFixture.importedDatabase())
        for query in ["hospital povisa", "povisa hospital"] {
            let hits = try repository.searchStops(query)
            #expect(hits.map(\.id) == [StopID("Q5")], "query: \(query)")
        }
    }

    /// H-09's relevance half: among two stops that both merely *contain* "coi", the one
    /// where it starts a word ("Coiro") ranks before the one where it is buried mid-word
    /// ("Escoita"). Neither name starts with "coi", so both land in the same tier and only
    /// the word-prefix score can tell them apart.
    @Test("Within the contains tier, a word-prefix match ranks above a mid-word match")
    func wordPrefixOutranksMidWordMatch() throws {
        let repository = TransitRepository(database: try SearchQualityFixture.importedDatabase())
        let hits = try repository.searchStops("coi")
        #expect(hits.map(\.id) == [StopID("Q6"), StopID("Q7")])
    }
}
