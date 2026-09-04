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

    /// Rounded **up**, so the planner never claims a walk is faster than it is and then
    /// hands the user a bus they cannot catch.
    public func seconds(metres: Double) -> Int {
        guard metres > 0 else { return 0 }
        let walked = metres * options.walkDetourFactor
        return Int((walked / options.walkSpeedMetresPerSecond).rounded(.up))
    }

    public func metres(from: Coordinate, to: Coordinate) -> Double {
        TransitRepository.haversineMetres(
            from.latitude, from.longitude, to.latitude, to.longitude)
    }

    /// Undoes `seconds(metres:)`, for a walk leg that only has the seconds `Timetable`
    /// stored — the exact metres were never carried past `footpaths(stops:)`. Approximate
    /// by construction: `seconds(metres:)` rounds up, so this is a lower bound on the
    /// distance that produced it, close enough for a UI figure already labelled an estimate.
    public func metres(forSeconds seconds: Int) -> Double {
        Double(seconds) * options.walkSpeedMetresPerSecond / options.walkDetourFactor
    }

    public func seconds(from: Coordinate, to: Coordinate) -> Int {
        seconds(metres: metres(from: from, to: to))
    }

    /// The symmetric transfer walks between stops closer than `maxTransferWalkMetres`,
    /// as indices into `stops`.
    ///
    /// Sweeps in latitude order, so the scan for each stop stops as soon as the latitude
    /// gap alone exceeds the radius. At 1149 stops and a 300 m radius this touches a
    /// handful of neighbours each rather than the full 1.3 M pairs.
    ///
    /// No transitive closure is computed, and that costs nothing: straight-line distance
    /// obeys the triangle inequality, so a two-hop walk is never shorter than the direct
    /// one. What the radius rules out is a transfer walk longer than the radius — which is
    /// policy, not a lost optimum.
    public func footpaths(stops: [Stop]) -> [Footpath] {
        let radius = options.maxTransferWalkMetres
        guard radius > 0, stops.count > 1 else { return [] }

        let byLatitude = stops.indices.sorted { stops[$0].latitude < stops[$1].latitude }
        // One degree of latitude is ~111.32 km everywhere; longitude is not, which is why
        // the cheap test is on latitude and the exact one is haversine.
        let latitudeSpan = radius / 111_320.0

        var paths: [Footpath] = []
        for (position, index) in byLatitude.enumerated() {
            let origin = stops[index]
            var ahead = position + 1
            while ahead < byLatitude.count {
                let otherIndex = byLatitude[ahead]
                let other = stops[otherIndex]
                if other.latitude - origin.latitude > latitudeSpan { break }
                ahead += 1

                let metres = TransitRepository.haversineMetres(
                    origin.latitude, origin.longitude, other.latitude, other.longitude)
                guard metres <= radius else { continue }

                let cost = Int32(seconds(metres: metres))
                paths.append(Footpath(from: Int32(index), to: Int32(otherIndex),
                                      seconds: cost, metres: metres))
                paths.append(Footpath(from: Int32(otherIndex), to: Int32(index),
                                      seconds: cost, metres: metres))
            }
        }
        return paths
    }
}
