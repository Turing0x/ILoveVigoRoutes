import Testing
import Foundation
@testable import VigoCore

/// The randomized contrast the plan calls "where the confidence is earned": `RaptorEngine`
/// is easy to write so that it returns plausible-but-suboptimal answers, and no fixed
/// example network catches that reliably. Two hundred small random timetables, checked
/// against an independently-written exhaustive reference, are what catches it instead.
@Suite("RaptorEngine matches the brute-force reference")
struct BruteForceReferenceTests {

    @Test("Two hundred random small timetables, fixed seed")
    func randomizedContrast() {
        var rng = SeededGenerator(seed: 0xC0FFEE)
        var mismatches: [String] = []

        for iteration in 0..<200 {
            let (timetable, query, options) = RandomPlannerFixture.makeInstance(rng: &rng)
            let engineResult = RaptorEngine(options: options).run(timetable, query)
            let referenceResult = BruteForceReference.run(timetable, query, options: options)

            if engineResult.bestArrival != referenceResult.bestArrival {
                mismatches.append("iteration \(iteration): bestArrival differs — "
                    + "engine \(engineResult.bestArrival) vs reference \(referenceResult.bestArrival)")
                continue
            }
            for round in 0...options.maxRounds {
                for stop in 0..<timetable.stopCount {
                    let engineArrival = engineResult.arrival(round: round, stop: stop)
                    let referenceArrival = referenceResult.arrival(round: round, stop: stop)
                    if engineArrival != referenceArrival {
                        mismatches.append("iteration \(iteration), round \(round), stop \(stop): "
                            + "engine \(String(describing: engineArrival)) vs "
                            + "reference \(String(describing: referenceArrival))")
                    }
                }
            }
        }

        let detail = mismatches.prefix(10).joined(separator: "\n")
        #expect(mismatches.isEmpty, "\(detail)")
    }

    /// The same contrast for a traveller already on a bus. The seeded round 1 is written by
    /// hand in both the engine and the reference — from the same rule, from different code —
    /// which is the only way to find out that one of the two wrote it wrong.
    @Test("Two hundred random timetables, asked from on board a bus")
    func randomizedOnboardContrast() {
        var rng = SeededGenerator(seed: 0xC0FFEE)
        var mismatches: [String] = []

        for iteration in 0..<200 {
            let (timetable, base, options) = RandomPlannerFixture.makeInstance(rng: &rng)
            let query = RandomPlannerFixture.onboard(base, timetable: timetable, rng: &rng)
            let engineResult = RaptorEngine(options: options).run(timetable, query)
            let referenceResult = BruteForceReference.run(timetable, query, options: options)

            if engineResult.bestArrival != referenceResult.bestArrival {
                mismatches.append("iteration \(iteration): bestArrival differs — "
                    + "engine \(engineResult.bestArrival) vs reference \(referenceResult.bestArrival)")
                continue
            }
            for round in 0...options.maxRounds {
                for stop in 0..<timetable.stopCount {
                    let engineArrival = engineResult.arrival(round: round, stop: stop)
                    let referenceArrival = referenceResult.arrival(round: round, stop: stop)
                    if engineArrival != referenceArrival {
                        mismatches.append("iteration \(iteration), round \(round), stop \(stop): "
                            + "engine \(String(describing: engineArrival)) vs "
                            + "reference \(String(describing: referenceArrival))")
                    }
                }
            }
        }

        let detail = mismatches.prefix(10).joined(separator: "\n")
        #expect(mismatches.isEmpty, "\(detail)")
    }
}
