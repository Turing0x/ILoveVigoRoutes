import Foundation

/// Matches a search query against route labels — the decision `MapSearchSheet.matchingLines`
/// used to make inline in the view, unranked and untestable without a simulator.
///
/// Tiered like `TransitRepository.searchStops`, but in the opposite direction from it: a stop
/// query is tested as a prefix *of the name*, while a line query is tested against the line's
/// own short code first — someone typing "15" is reaching for a line number, not a word in a
/// sentence. `normalizedLineName` (not `searchFolded`) drives the short-code tiers, since route
/// codes carry no accents but do carry the feed's trailing dot (`9B.`) that has to fold away
/// for a code query to survive it; `searchFolded` still drives the long-name tier, which is
/// prose and does carry accents.
public enum LineMatching {
    /// Routes matching `query`, best match first, capped at `limit`.
    ///
    /// Three tiers, each ordered by `TransitRepository.lineNameOrdering`: the short code
    /// matches exactly, then the short code is a prefix of it, then the long name merely
    /// contains it. There is no plain "short code contains the query" tier — that is what let
    /// a single letter like "a" match 44 of 45 real lines; a query that is genuinely a
    /// fragment of a code and not its prefix (`"3d"` for `"C3d"`) is the accepted cost.
    public static func matches(query: String, in routes: [Route], limit: Int = 8) -> [Route] {
        let code = TextNormalization.normalizedLineName(query)
        guard !code.isEmpty else { return [] }
        let prose = TextNormalization.searchFolded(query)

        func shortCode(_ route: Route) -> String { TextNormalization.normalizedLineName(route.shortName) }
        func foldedLong(_ route: Route) -> String { TextNormalization.searchFolded(route.longName) }
        func byLineOrder(_ a: Route, _ b: Route) -> Bool {
            TransitRepository.lineNameOrdering(a.shortName, b.shortName)
        }

        var seen = Set<RouteID>()
        var result: [Route] = []
        func add(_ candidates: [Route]) {
            for route in candidates where seen.insert(route.id).inserted { result.append(route) }
        }

        add(routes.filter { shortCode($0) == code })
        add(routes.filter { shortCode($0).hasPrefix(code) }.sorted(by: byLineOrder))
        if !prose.isEmpty {
            add(routes.filter { foldedLong($0).contains(prose) }.sorted(by: byLineOrder))
        }

        return Array(result.prefix(limit))
    }
}
