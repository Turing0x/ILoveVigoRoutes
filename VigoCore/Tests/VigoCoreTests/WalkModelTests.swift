import Testing
import Foundation
@testable import VigoCore

@Suite("Walking estimates and transfer footpaths")
struct WalkModelTests {

    private let walk = WalkModel()

    @Test("Converts metres to seconds through the detour factor")
    func conversion() {
        // 100 m of map is 135 m of pavement at 1.33 m/s, i.e. 101.5 s.
        #expect(walk.seconds(metres: 100, as: .transfer) == 102)
        // The same 100 m at the access factor is 150 m of pavement, i.e. 112.8 s.
        #expect(walk.seconds(metres: 100, as: .accessEgress) == 113)
        for kind in WalkKind.allCases {
            #expect(walk.seconds(metres: 0, as: kind) == 0)
            #expect(walk.seconds(metres: -5, as: kind) == 0,
                    "a negative distance is not a negative walk")
        }
    }

    /// B1. The whole point of splitting the factor: an access walk must never come out
    /// shorter than the same distance walked as a transfer, because underestimating *this*
    /// end is what hands the user a bus they cannot catch.
    @Test("An access walk is never cheaper than the same distance as a transfer")
    func accessIsThePessimisticEnd() {
        #expect(walk.detourFactor(.accessEgress) >= walk.detourFactor(.transfer))
        for metres in stride(from: 25.0, through: 800.0, by: 25.0) {
            #expect(walk.seconds(metres: metres, as: .accessEgress)
                    >= walk.seconds(metres: metres, as: .transfer))
        }
    }

    /// `metres(forSeconds:as:)` is the inverse used to label a leg on the map, and it only
    /// inverts the factor it was given. Round-tripping with the *wrong* kind is the silent
    /// error the `as:` parameter exists to make impossible to write by accident.
    @Test("Metres round-trip through seconds within the rounding-up error")
    func roundTrip() {
        for kind in WalkKind.allCases {
            for metres in stride(from: 20.0, through: 900.0, by: 20.0) {
                let back = walk.metres(forSeconds: walk.seconds(metres: metres, as: kind), as: kind)
                #expect(abs(back - metres) < 1.0)
            }
        }
        // And the mismatch is real, not theoretical: reversing an access walk with the
        // transfer factor overstates the distance by the ratio between the two.
        let seconds = walk.seconds(metres: 500, as: .accessEgress)
        #expect(walk.metres(forSeconds: seconds, as: .transfer)
                > walk.metres(forSeconds: seconds, as: .accessEgress))
    }

    /// Rounding down would let the planner offer a bus the user cannot reach.
    @Test("Rounds walking time up")
    func roundsUp() {
        let exact = WalkModel(options: PlannerOptions(
            walkSpeedMetresPerSecond: 1, accessDetourFactor: 1, transferDetourFactor: 1))
        for kind in WalkKind.allCases {
            #expect(exact.seconds(metres: 60, as: kind) == 60)
            #expect(exact.seconds(metres: 60.01, as: kind) == 61)
        }
    }

    @Test("Slower walking takes longer")
    func speedMatters() {
        let slow = WalkModel(options: PlannerOptions(walkSpeedMetresPerSecond: 0.9))
        for kind in WalkKind.allCases {
            #expect(slow.seconds(metres: 400, as: kind) > walk.seconds(metres: 400, as: kind))
        }
    }

    @Test("Measures the distance between two coordinates")
    func distance() {
        let there = Coordinate(PlannerFixture.stop("B", northMetres: 250))
        #expect(abs(walk.metres(from: PlannerFixture.base, to: there) - 250) < 0.5)
        for kind in WalkKind.allCases {
            #expect(walk.seconds(from: PlannerFixture.base, to: there, as: kind)
                    == walk.seconds(metres: 250, as: kind))
        }
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
        #expect(paths[0].seconds == walk.seconds(metres: 40, as: .transfer),
                "the footpath graph is transfers, whatever the access factor says")
    }

    /// The latitude sweep is an optimisation, and an optimisation that drops pairs would
    /// silently cost the planner transfers. Checked against the full quadratic scan.
    ///
    /// The reference applies the same admission rule the sweep does, and that rule is about
    /// **walked** metres: with no measured table the estimate is straight-line times the
    /// transfer factor, and it is that figure — not the straight line — that has to fit
    /// inside `maxTransferWalkMetres`. Comparing against a straight-line radius would be
    /// testing a policy the planner does not have.
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
                if metres * walk.detourFactor(.transfer) <= walk.options.maxTransferWalkMetres {
                    expected.insert([Int32(i), Int32(j)])
                }
            }
        }

        let produced = Set(walk.footpaths(stops: stops).map { [$0.from, $0.to] })
        #expect(!expected.isEmpty, "the layout must actually produce some neighbours")
        #expect(produced == expected)
    }

    /// B2. The measured table is believed over the estimate, and the difference is not a
    /// rounding one: two poles of the same avenue can be metres apart with no crossing
    /// between them.
    @Test("A measured pair overrides the straight-line estimate")
    func measuredWins() {
        let stops = [PlannerFixture.stop("A"), PlannerFixture.stop("B", eastMetres: 5)]
        let table = FootpathTable(metres: [(stops[0].id, stops[1].id, 112)])

        let estimated = walk.footpaths(stops: stops)
        #expect(estimated.count == 2)
        #expect(estimated[0].seconds <= 8, "five metres of straight line is nothing")

        let measured = walk.footpaths(stops: stops, table: table)
        #expect(measured.count == 2)
        #expect(measured[0].metres == 112)
        #expect(measured[0].seconds == walk.secondsForWalkedMetres(112))
        #expect(measured[0].seconds > 60, "112 m of pavement is a minute and a half, not five seconds")
    }

    /// A covered pair the generator found no route for is a measurement, not a gap: putting
    /// the straight-line estimate back would restore exactly the phantom transfers the
    /// table exists to remove.
    @Test("Two measured stops with no route get no footpath")
    func measuredAbsenceIsAnAnswer() {
        let a = PlannerFixture.stop("A")
        let b = PlannerFixture.stop("B", eastMetres: 30)
        let far = PlannerFixture.stop("FAR", northMetres: 5_000)
        // Both A and B are covered — by their rows to `far` — but no A–B row exists.
        let table = FootpathTable(metres: [(a.id, far.id, 900), (b.id, far.id, 900)])
        #expect(walk.footpaths(stops: [a, b], table: table).isEmpty)
    }

    /// A stop the feed gained after the table was generated must not lose every transfer it
    /// has. Absence of the *stop* is a gap; absence of a *pair* between covered stops is not.
    @Test("A stop the table does not cover falls back to the estimate")
    func uncoveredStopFallsBack() {
        let a = PlannerFixture.stop("A")
        let newcomer = PlannerFixture.stop("NEW", eastMetres: 40)
        let far = PlannerFixture.stop("FAR", northMetres: 5_000)
        let table = FootpathTable(metres: [(a.id, far.id, 900)])
        #expect(!table.covers(newcomer.id))

        let paths = walk.footpaths(stops: [a, newcomer], table: table)
        #expect(paths.count == 2, "an unmeasured stop is estimated, not stranded")
        #expect(paths[0].seconds == walk.seconds(metres: 40, as: .transfer))
    }

    /// The sweep filters candidates by straight-line distance while the policy is about
    /// walked metres. That is only sound because a street walk is never shorter than the
    /// straight line — so no measured pair inside the radius can fall outside the sweep.
    @Test("The sweep never hides a measured pair that is inside the radius")
    func sweepIsSoundForMeasuredPairs() {
        let radius = walk.options.maxTransferWalkMetres
        let a = PlannerFixture.stop("A")
        // Straight-line distance just inside the radius, measured at the radius exactly:
        // the tightest case the sweep has to admit.
        let b = PlannerFixture.stop("B", northMetres: radius - 1)
        let table = FootpathTable(metres: [(a.id, b.id, radius)])
        let paths = walk.footpaths(stops: [a, b], table: table)
        #expect(paths.count == 2)
        #expect(paths[0].metres == radius)
    }

    @Test("A zero radius produces no footpaths")
    func zeroRadius() {
        let none = WalkModel(options: PlannerOptions(maxTransferWalkMetres: 0))
        let stops = [PlannerFixture.stop("A"), PlannerFixture.stop("B", northMetres: 10)]
        #expect(none.footpaths(stops: stops).isEmpty)
        #expect(walk.footpaths(stops: []).isEmpty)
    }
}
