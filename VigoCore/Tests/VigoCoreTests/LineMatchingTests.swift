import Testing
import Foundation
@testable import VigoCore

@Suite("Emparejamiento de líneas")
struct LineMatchingTests {
    /// A slice shaped like the real feed: short numeric lines, lettered variants, a ghost
    /// route with a trailing dot (the kind `routesWithService()` already filters before this
    /// ever sees it, but the dot-stripping still has to hold if that ever changes), and two
    /// "H" lines whose long name carries "HOSPITAL".
    private static let routes: [Route] = [
        route("10", "TEIS – CANIDO – SAIÁNS"),
        route("11", "SAN MIGUEL - CABRAL"),
        route("12A", "SAIÁNS – MUÍÑOS – HOSP. MEIXOEIRO"),
        route("15A", "CABRAL - SAMIL"),
        route("15B", "HOSP. MEIXOEIRO - SAMIL / NAVIA"),
        route("15C", "UNIVERSIDADE – SAMIL / NAVIA"),
        route("H", "NAVIA - BOUZAS - HOSPITAL ALVARO CUNQUEIRO"),
        route("H1", "POLICARPO SANZ – HOSPITAL ÁLVARO CUNQUEIRO"),
        route("6", "HOSP. ALVARO CUNQUEIRO - BEADE – PZA. ESPAÑA"),
        route("9B.", "BOUZAS"),
    ]

    private static func route(_ short: String, _ long: String) -> Route {
        Route(id: RouteID(short), shortName: short, longName: long, routeType: 3,
              colorHex: nil, textColorHex: nil)
    }

    @Test("An exact short-code match leads")
    func exactCodeLeads() {
        let hits = LineMatching.matches(query: "H", in: Self.routes)
        #expect(hits.first?.shortName == "H")
    }

    /// H-25: a bare "1" used to match 44 of 45 real lines through an unranked `contains`.
    /// Here it must find only the short-code prefix matches: "10", "11", "12A", "15A/B/C" —
    /// not "H"/"H1"/"H6", whose codes do not start with "1".
    @Test("A short numeric query matches by short-code prefix, not by name contains")
    func shortQueryMatchesByPrefixOnly() {
        let hits = LineMatching.matches(query: "1", in: Self.routes, limit: 20)
        #expect(Set(hits.map(\.shortName)) == ["10", "11", "12A", "15A", "15B", "15C"])
    }

    @Test("A two-digit prefix narrows to just its own family")
    func twoDigitPrefixNarrows() {
        let hits = LineMatching.matches(query: "15", in: Self.routes, limit: 20)
        #expect(hits.map(\.shortName) == ["15A", "15B", "15C"])
    }

    /// A query that matches no short code but appears in several long names — H-45's other
    /// half, ranked by `lineNameOrdering` since none of these codes are numeric. Route "6"'s
    /// long name abbreviates to "HOSP." in this fixture, mirroring the real feed, so it must
    /// NOT match the spelled-out "hospital" — only "H" and "H1", which spell it in full.
    @Test("A prose query matches by long-name contains")
    func proseQueryMatchesLongName() {
        let hits = LineMatching.matches(query: "hospital", in: Self.routes, limit: 20)
        #expect(Set(hits.map(\.shortName)) == ["H", "H1"])

        let abbreviated = LineMatching.matches(query: "hosp", in: Self.routes, limit: 20)
        #expect(Set(abbreviated.map(\.shortName)) == ["6", "12A", "15B", "H", "H1"])
    }

    /// H-39: the feed's trailing dot on a ghost route's code must not stop it matching its
    /// own bare number, if it were ever searchable.
    @Test("A trailing dot on the stored code does not block matching")
    func trailingDotDoesNotBlockMatch() {
        let hits = LineMatching.matches(query: "9B", in: Self.routes, limit: 20)
        #expect(hits.map(\.shortName) == ["9B."])
    }

    @Test("Respects the limit")
    func respectsLimit() {
        let hits = LineMatching.matches(query: "1", in: Self.routes, limit: 2)
        #expect(hits.count == 2)
    }

    @Test("An empty query matches nothing")
    func emptyQueryMatchesNothing() {
        #expect(LineMatching.matches(query: "", in: Self.routes).isEmpty)
        #expect(LineMatching.matches(query: "   ", in: Self.routes).isEmpty)
    }
}
