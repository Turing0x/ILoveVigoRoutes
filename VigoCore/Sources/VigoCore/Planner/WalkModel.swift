import Foundation

/// A point on the map. The planner deals in bare coordinates because an origin or a
/// destination is not always a stop — it can be the user's location or a tap on the map.
public struct Coordinate: Sendable, Hashable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    public init(_ stop: Stop) {
        self.init(latitude: stop.latitude, longitude: stop.longitude)
    }

    /// Rounds to `decimals` decimal places — four is roughly 11 m, the resolution
    /// `MapSearchSheet` throttles "Cerca de ti" on so GPS jitter alone does not relaunch that
    /// query, and the resolution `PLAN-FASES-8-13.md` §12.3 specifies for `recentSearch`'s
    /// `dedupKey`. Kept here once, not copied at each call site, so the two cannot drift
    /// apart (H-48).
    public func rounded(toDecimals decimals: Int) -> Coordinate {
        let factor = pow(10.0, Double(decimals))
        return Coordinate(latitude: (latitude * factor).rounded() / factor,
                          longitude: (longitude * factor).rounded() / factor)
    }
}

/// A walk between two stops, in the compact index space of the array the paths were
/// generated from — not `StopID`. RAPTOR's inner loop indexes arrays, and translating
/// identifiers inside it would dominate its cost.
public struct Footpath: Sendable, Hashable {
    public let from: Int32
    public let to: Int32
    public let seconds: Int32
    public let metres: Double

    public init(from: Int32, to: Int32, seconds: Int32, metres: Double) {
        self.from = from; self.to = to; self.seconds = seconds; self.metres = metres
    }
}

/// Which of a journey's walks a figure belongs to.
///
/// Not a cosmetic label: it selects the detour factor, and the two differ on purpose — see
/// `PlannerOptions.accessDetourFactor` for the measurement and the argument. Passing the
/// wrong one is a silent error of up to 11 % in a number the user acts on, so the parameter
/// has no default anywhere it is reachable from the planner.
public enum WalkKind: Sendable, Hashable, CaseIterable {
    /// Origin → first stop, last stop → destination, or a door-to-door walk with no bus at
    /// all. One end of it is a place the passenger chose, not a stop.
    case accessEgress
    /// Stop → stop, inside the network: a transfer on foot.
    case transfer
}

/// Turns distance into walking time, and finds the stop-to-stop walks the planner is
/// allowed to use as transfers.
///
/// Everything here is straight-line distance scaled by a detour factor. That is a
/// deliberate limit, not an oversight: routing on a street graph would mean either a
/// network round trip per leg or shipping a pedestrian graph of Vigo, and neither is
/// justified for a personal app. The consequence is that every walking figure is an
/// estimate and the UI says so.
public struct WalkModel: Sendable {
    public let options: PlannerOptions

    public init(options: PlannerOptions = PlannerOptions()) {
        self.options = options
    }

    /// The multiplier that turns straight-line metres into walked metres, for one kind of
    /// walk. The single place the two options are told apart, so a future third kind is one
    /// case here and a compiler error at every call site rather than a silent default.
    public func detourFactor(_ kind: WalkKind) -> Double {
        switch kind {
        case .accessEgress: options.accessDetourFactor
        case .transfer:     options.transferDetourFactor
        }
    }

    /// Rounded **up**, so the planner never claims a walk is faster than it is and then
    /// hands the user a bus they cannot catch.
    public func seconds(metres: Double, as kind: WalkKind) -> Int {
        guard metres > 0 else { return 0 }
        let walked = metres * detourFactor(kind)
        return Int((walked / options.walkSpeedMetresPerSecond).rounded(.up))
    }

    public func metres(from: Coordinate, to: Coordinate) -> Double {
        TransitRepository.haversineMetres(
            from.latitude, from.longitude, to.latitude, to.longitude)
    }

    /// Undoes `seconds(metres:as:)`, for a walk leg that only has the seconds `Timetable`
    /// stored — the exact metres were never carried past `footpaths(stops:)`. Approximate
    /// by construction: `seconds(metres:as:)` rounds up, so this is a lower bound on the
    /// distance that produced it, close enough for a UI figure already labelled an estimate.
    ///
    /// `kind` **must** be the one the seconds were produced with. Reversing an access walk
    /// with the transfer factor overstates its distance by the ratio between them, and that
    /// number is shown to the user as metres on a map.
    public func metres(forSeconds seconds: Int, as kind: WalkKind) -> Double {
        Double(seconds) * options.walkSpeedMetresPerSecond / detourFactor(kind)
    }

    public func seconds(from: Coordinate, to: Coordinate, as kind: WalkKind) -> Int {
        seconds(metres: metres(from: from, to: to), as: kind)
    }

    /// The symmetric transfer walks between stops closer than `maxTransferWalkMetres`,
    /// as indices into `stops`.
    ///
    /// Sweeps in latitude order, so the scan for each stop stops as soon as the latitude
    /// gap alone exceeds the radius. At 1154 stops this touches a handful of neighbours
    /// each rather than the full 1.3 M pairs.
    ///
    /// **`table` is consulted first and believed.** A measured street distance is not an
    /// improvement on the straight-line estimate, it is a different kind of fact: the
    /// estimate's error on short pairs is unbounded, because two poles five metres apart
    /// across an uncrossable road are a five-second transfer by straight line and an
    /// eighty-five-second one on the pavement. See `FootpathTable`.
    ///
    /// The sweep's radius is therefore a *candidate* filter, not the policy. A pair inside
    /// it is admitted only if the table says the real walk is inside
    /// `maxTransferWalkMetres` too — or, for a pair the table does not cover, if the
    /// straight-line estimate is, which is the old behaviour and the fallback.
    ///
    /// No transitive closure is computed. For straight-line distances that costs nothing
    /// (the triangle inequality guarantees a two-hop walk is never shorter). For street
    /// distances it is no longer free in principle — a detour around a barrier can make
    /// A→B→C shorter than A→C — but the generator routes on the real network, so its A→C is
    /// already that detour. What the radius rules out is a transfer longer than the radius,
    /// which is policy.
    public func footpaths(stops: [Stop], table: FootpathTable = .empty) -> [Footpath] {
        let radius = options.maxTransferWalkMetres
        guard radius > 0, stops.count > 1 else { return [] }

        // Wide enough to hold every pair whose *street* distance could still be inside the
        // radius. Street distance is never shorter than the straight line, so a straight-line
        // sweep at the radius itself would be sound — but the sweep is also what bounds the
        // candidate set, and keeping it at the radius means a pair the table measures at
        // 380 m is only considered if it also happens to be within 400 m as the crow flies.
        // That is true for almost all of them and cheap to stop worrying about.
        let sweepRadius = radius
        let latitudeSpan = sweepRadius / 111_320.0

        let byLatitude = stops.indices.sorted { stops[$0].latitude < stops[$1].latitude }
        var paths: [Footpath] = []
        for (position, index) in byLatitude.enumerated() {
            let origin = stops[index]
            var ahead = position + 1
            while ahead < byLatitude.count {
                let otherIndex = byLatitude[ahead]
                let other = stops[otherIndex]
                if other.latitude - origin.latitude > latitudeSpan { break }
                ahead += 1

                let straight = TransitRepository.haversineMetres(
                    origin.latitude, origin.longitude, other.latitude, other.longitude)
                guard straight <= sweepRadius else { continue }

                let metres: Double
                if let measured = table.metres(from: origin.id, to: other.id) {
                    metres = measured
                } else if table.covers(origin.id) && table.covers(other.id) {
                    // Both ends were measured and no route came back inside the generator's
                    // radius. That is an answer — "you cannot walk this in a sensible time" —
                    // and overriding it with a straight line would put back exactly the
                    // phantom transfers this table exists to remove.
                    continue
                } else {
                    // At least one stop is newer than the table. Estimate it rather than
                    // strand it: a stop the feed just gained would otherwise have no
                    // transfers at all until someone regenerates the resource.
                    metres = straight * detourFactor(.transfer)
                }
                guard metres <= radius else { continue }

                // `.transfer` is not a choice here: this function's whole output is the
                // footpath graph, and every edge in it is a stop-to-stop transfer. The
                // metres are already walked metres by this point, whether they were measured
                // or estimated, so the factor must not be applied a second time.
                let cost = Int32(secondsForWalkedMetres(metres))
                paths.append(Footpath(from: Int32(index), to: Int32(otherIndex),
                                      seconds: cost, metres: metres))
                paths.append(Footpath(from: Int32(otherIndex), to: Int32(index),
                                      seconds: cost, metres: metres))
            }
        }
        return paths
    }

    /// Seconds for a distance that is **already** walked metres — measured on a street
    /// network, or estimated and scaled once. No detour factor is applied: doing so would
    /// double-count it, which is the one mistake this whole split makes easy to write.
    public func secondsForWalkedMetres(_ metres: Double) -> Int {
        guard metres > 0 else { return 0 }
        return Int((metres / options.walkSpeedMetresPerSecond).rounded(.up))
    }
}
