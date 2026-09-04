import Testing
import Foundation
@testable import VigoCore

@Suite("Walking estimates and transfer footpaths")
struct WalkModelTests {

    private let walk = WalkModel()

    @Test("Converts metres to seconds through the detour factor")
    func conversion() {
        // 100 m of map is 135 m of pavement at 1.33 m/s, i.e. 101.5 s.
        #expect(walk.seconds(metres: 100) == 102)
        #expect(walk.seconds(metres: 0) == 0)
        #expect(walk.seconds(metres: -5) == 0, "a negative distance is not a negative walk")
    }

    /// Rounding down would let the planner offer a bus the user cannot reach.
    @Test("Rounds walking time up")
    func roundsUp() {
        let exact = WalkModel(options: PlannerOptions(
            walkSpeedMetresPerSecond: 1, walkDetourFactor: 1))
        #expect(exact.seconds(metres: 60) == 60)
        #expect(exact.seconds(metres: 60.01) == 61)
    }

    @Test("Slower walking takes longer")
    func speedMatters() {
        let slow = WalkModel(options: PlannerOptions(walkSpeedMetresPerSecond: 0.9))
        #expect(slow.seconds(metres: 400) > walk.seconds(metres: 400))
    }

    @Test("Measures the distance between two coordinates")
    func distance() {
        let there = Coordinate(PlannerFixture.stop("B", northMetres: 250))
        #expect(abs(walk.metres(from: PlannerFixture.base, to: there) - 250) < 0.5)
        #expect(walk.seconds(from: PlannerFixture.base, to: there) == walk.seconds(metres: 250))
    }

    @Test("Footpaths stay inside the transfer radius")
    func radius() {
        let stops = [
            PlannerFixture.stop("A"),
            PlannerFixture.stop("B", northMetres: 250),
            PlannerFixture.stop("C", northMetres: 1_000),
        ]
        let paths = walk.footpaths(stops: stops)
        #expect(Set(paths.map { [$0.from, $0.to] }) == [[0, 1], [1, 0]])
        #expect(paths.allSatisfy { $0.metres <= walk.options.maxTransferWalkMetres })
    }

    @Test("Footpaths are symmetric and cost the same both ways")
    func symmetry() {
        let stops = (0..<12).map { PlannerFixture.stop("S\($0)", northMetres: Double($0) * 80) }
        let paths = walk.footpaths(stops: stops)
        var byPair: [[Int32]: Footpath] = [:]
        for path in paths { byPair[[path.from, path.to]] = path }
        #expect(!paths.isEmpty)
        for path in paths {
            let mirror = byPair[[path.to, path.from]]
            #expect(mirror?.seconds == path.seconds)
            #expect(mirror?.metres == path.metres)
        }
    }

    @Test("A stop never walks to itself")
    func noSelfLoops() {
        let stops = [PlannerFixture.stop("A"), PlannerFixture.stop("A2", northMetres: 5)]
        #expect(walk.footpaths(stops: stops).allSatisfy { $0.from != $0.to })
    }

    @Test("Twin stops across the road are connected")
    func twinStops() {
        let stops = [PlannerFixture.stop("A"), PlannerFixture.stop("A2", eastMetres: 40)]
        let paths = walk.footpaths(stops: stops)
        #expect(paths.count == 2)
        #expect(paths[0].seconds == walk.seconds(metres: 40))
    }

    /// The latitude sweep is an optimisation, and an optimisation that drops pairs would
    /// silently cost the planner transfers. Checked against the full quadratic scan.
    @Test("The latitude sweep finds every pair the brute-force scan finds")
    func sweepMatchesBruteForce() {
        // Fixed seed: a layout that exposes a gap in the sweep must keep exposing it.
        var seed: UInt64 = 0x5EED
        func next() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(seed >> 11) / Double(UInt64(1) << 53)
        }
        let stops = (0..<200).map {
            PlannerFixture.stop("S\($0)",
                                northMetres: (next() - 0.5) * 4_000,
                                eastMetres: (next() - 0.5) * 4_000)
        }

        var expected = Set<[Int32]>()
        for i in stops.indices {
            for j in stops.indices where i != j {
                let metres = TransitRepository.haversineMetres(
                    stops[i].latitude, stops[i].longitude, stops[j].latitude, stops[j].longitude)
                if metres <= walk.options.maxTransferWalkMetres {
                    expected.insert([Int32(i), Int32(j)])
                }
            }
        }

        let produced = Set(walk.footpaths(stops: stops).map { [$0.from, $0.to] })
        #expect(!expected.isEmpty, "the layout must actually produce some neighbours")
        #expect(produced == expected)
    }

    @Test("A zero radius produces no footpaths")
    func zeroRadius() {
        let none = WalkModel(options: PlannerOptions(maxTransferWalkMetres: 0))
        let stops = [PlannerFixture.stop("A"), PlannerFixture.stop("B", northMetres: 10)]
        #expect(none.footpaths(stops: stops).isEmpty)
        #expect(walk.footpaths(stops: []).isEmpty)
    }
}
