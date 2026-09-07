import Foundation

/// Real walked distance between pairs of stops, measured once on a pedestrian street
/// network and shipped with the app.
///
/// **Why this exists.** `WalkModel` estimates a walk as straight-line distance times a
/// detour factor. Measured against a real pedestrian graph, that factor's per-pair error
/// runs from −28 % to +29 % (`AUDITORIA-MOTOR-VS-CONCELLO.md` F-2), and the worst cases are
/// not the long walks — they are the short ones. Two poles of the same avenue can sit five
/// metres apart across a road with no crossing between them: the straight line says five
/// seconds, the pavement says eighty-five. Avda. de Samil 15 and Samil por Coia are exactly
/// that pair, 5 m apart and 112 m of walking, and before this table the planner offered a
/// transfer between them that nobody could make.
///
/// Transfers are the half of the walking problem that can be solved once and for all,
/// because **both ends are known in advance**: there are only a few thousand pairs of stops
/// close enough to matter, so they can be routed offline and looked up at run time. The
/// other half — the user's door to the first stop, the last stop to wherever they are going
/// — cannot, because those ends are wherever the user happens to be.
///
/// Built by `Tools/build_footpaths.py` from an OpenStreetMap extract. That script is the
/// only thing that writes `footpaths.csv`; nothing at run time can.
public struct FootpathTable: Sendable {

    /// Undirected: one entry per pair, with the two stops in a canonical order. A walk
    /// between two stops costs the same in both directions — pedestrians ignore one-ways,
    /// which is the reason the generator routes on an undirected graph in the first place —
    /// and storing it once makes an asymmetric table unrepresentable rather than merely
    /// unlikely.
    private let metresByPair: [Pair: Double]

    /// Every stop the table was built from.
    ///
    /// Load-bearing, not diagnostics. Absence of a pair means two different things and the
    /// planner has to tell them apart: if **both** stops are known, the generator looked and
    /// found no route inside the radius, so there is genuinely no transfer. If either stop
    /// is unknown — a stop the feed gained after this table was generated — absence means
    /// only that nobody has measured it, and falling back to the straight-line estimate is
    /// better than silently stranding it with no transfers at all.
    public let coveredStops: Set<StopID>

    struct Pair: Hashable, Sendable {
        let a: StopID
        let b: StopID

        init(_ x: StopID, _ y: StopID) {
            if x.rawValue <= y.rawValue { a = x; b = y } else { a = y; b = x }
        }
    }

    public init(metres: [(StopID, StopID, Double)]) {
        var byPair = [Pair: Double](minimumCapacity: metres.count)
        var covered = Set<StopID>(minimumCapacity: metres.count)
        for (from, to, distance) in metres {
            covered.insert(from)
            covered.insert(to)
            guard from != to else { continue }
            let pair = Pair(from, to)
            // Two rows for the same pair should not happen — the generator writes each
            // once — but if a hand-edited file ever contains both, the shorter wins rather
            // than whichever happened to be read last.
            if let existing = byPair[pair], existing <= distance { continue }
            byPair[pair] = distance
        }
        self.metresByPair = byPair
        self.coveredStops = covered
    }

    /// An empty table that covers nothing, so every lookup falls back. What the planner uses
    /// when the resource is missing — a unit test bundle, or a build that dropped it.
    public static let empty = FootpathTable(metres: [])

    public var pairCount: Int { metresByPair.count }

    /// The measured walk between two stops, or `nil` when this table has nothing to say.
    public func metres(from: StopID, to: StopID) -> Double? {
        metresByPair[Pair(from, to)]
    }

    /// Whether absence of a pair is a measurement ("no route within the radius") or a gap
    /// ("never measured"). See `coveredStops`.
    public func covers(_ stop: StopID) -> Bool { coveredStops.contains(stop) }

    // MARK: - Loading

    public enum LoadError: Error, CustomStringConvertible, Sendable {
        case malformed(line: Int, reason: String)

        public var description: String {
            switch self {
            case .malformed(let line, let reason): "footpaths.csv:\(line): \(reason)"
            }
        }
    }

    /// Parses `from_stop_id,to_stop_id,metres`.
    ///
    /// Hand-rolled rather than routed through `CSVTable`: this file is written by one script
    /// in this repository and never by a third party, the values are three plain fields with
    /// no quoting, and the parser is small enough that reading it is faster than checking
    /// what the general one would do with a stop id containing a comma.
    public static func load(csv data: Data) throws -> FootpathTable {
        guard let text = String(data: data, encoding: .utf8) else {
            throw LoadError.malformed(line: 0, reason: "not UTF-8")
        }
        var rows: [(StopID, StopID, Double)] = []
        // Split on every newline spelling, not on `"\n"` alone. Swift treats CR LF as a
        // *single* `Character`, so `split(separator: "\n")` does not break a CRLF file at
        // all: the whole thing comes back as one line. That line starts with the header (or
        // a comment), gets skipped, and `load` returns an empty table — with no error, no
        // throw, and a planner quietly back to guessing straight lines. A regenerated file
        // that ever picks up Windows line endings has to fail loudly or not at all, and
        // "not at all" is the one this chooses.
        let lines = text.split(omittingEmptySubsequences: false) {
            $0 == "\n" || $0 == "\r\n" || $0 == "\r"
        }
        for (index, line) in lines.enumerated() {
            if line.isEmpty || line.hasPrefix("#") { continue }
            // Not `index == 0`: a comment above the header pushes it down a line, and a
            // header parsed as data throws on the word "metres" rather than being ignored.
            if line.hasPrefix("from_stop_id") { continue }
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count == 3 else {
                throw LoadError.malformed(line: index + 1, reason: "expected 3 fields, got \(fields.count)")
            }
            guard let metres = Double(fields[2]), metres >= 0 else {
                throw LoadError.malformed(line: index + 1, reason: "unreadable distance '\(fields[2])'")
            }
            rows.append((StopID(String(fields[0])), StopID(String(fields[1])), metres))
        }
        return FootpathTable(metres: rows)
    }

    /// The table shipped in the package's resources, or `.empty` when it is not there.
    ///
    /// Never throws and never traps. A missing or corrupt table degrades the planner to the
    /// straight-line estimate it used before — worse answers, not no answers — and that is
    /// the right trade for a resource whose absence is a packaging mistake rather than a
    /// user's problem.
    public static let bundled: FootpathTable = {
        guard let url = Bundle.module.url(forResource: "footpaths", withExtension: "csv"),
              let data = try? Data(contentsOf: url),
              let table = try? load(csv: data)
        else { return .empty }
        return table
    }()
}
