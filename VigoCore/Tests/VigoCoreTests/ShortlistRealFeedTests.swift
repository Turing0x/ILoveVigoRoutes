import Testing
import Foundation
@testable import VigoCore

/// What the shortlist actually does on the published feed, on real origin–destination pairs.
///
/// Every judgement in `JourneyShortlist` and `JourneyOrdering.generalizedCostSeconds` was made
/// from numbers measured here rather than from reasoning about the code, and two of those
/// judgements turned out to be wrong the first time. This suite is what caught them, so it
/// stays — a synthetic fixture cannot tell you that a filter deletes the next four buses.
///
/// Skipped unless `VIGO_GTFS_ZIP` points at a downloaded `gtfs_vigo.zip`, like
/// `RealFeedIntegrationTests`:
///
///     VIGO_GTFS_ZIP=/path/to/gtfs_vigo.zip swift test
///
/// The assertions are shape-based on purpose. The feed is regenerated weekly, so exact
/// journeys would rot within days; what must not change is the *character* of the list.
@Suite("Shortlist against the real feed",
       .enabled(if: ProcessInfo.processInfo.environment["VIGO_GTFS_ZIP"] != nil))
struct ShortlistRealFeedTests {

    private struct Harness {
        let repository: TransitRepository
        let timetable: Timetable
        let options: PlannerOptions
        let day: ServiceDate
    }

    private func harness() async throws -> Harness {
        let path = try #require(ProcessInfo.processInfo.environment["VIGO_GTFS_ZIP"])
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let parsed = try GTFSParser().parse(from: try GTFSZipProvider(data: data))
        let db = try AppDatabase.inMemory()
        _ = try GTFSImporter(database: db).import(feed: parsed.feed, parseWarnings: parsed.warnings)
        let repository = TransitRepository(database: db)
        let options = PlannerOptions()
        // A weekday in the middle of the window, so the ±1 day either side is populated.
        let observed = try repository.observedServiceDays().sorted()
        let day = observed[min(2, observed.count - 1)]
        let store = TimetableStore(repository: repository, options: options)
        return Harness(repository: repository, timetable: try await store.timetable(anchor: day),
                       options: options, day: day)
    }

    /// Everything the departure scan collects for one pair, before any shortlisting.
    private func collect(_ h: Harness, from: Stop, to: Stop, hour: Int) throws -> [Journey] {
        let walk = WalkModel(options: h.options)
        func walks(_ stop: Stop) throws -> [StopWalk] {
            try h.repository.nearbyStops(
                latitude: stop.latitude, longitude: stop.longitude,
                radiusMetres: h.options.accessRadiusMetres, limit: h.options.maxNearbyStops
            ).compactMap { nearby in
                guard let index = h.timetable.index(of: nearby.stop.id) else { return nil }
                return StopWalk(stop: index,
                                seconds: Int32(walk.seconds(metres: nearby.distanceMetres,
                                                            as: .accessEgress)))
            }
        }
        let access = try walks(from), egress = try walks(to)
        let origin = Place.coordinate(Coordinate(from), label: from.name)
        let destination = Place.coordinate(Coordinate(to), label: to.name)

        let start = Int32(h.timetable.axisSeconds(
            for: h.day.startOfDay(in: h.repository.calendar)!
                .addingTimeInterval(TimeInterval(hour) * 3_600)))
        let deadline = start &+ Int32(h.options.searchHorizon)
        var departure = start
        var seen = Set<Journey>()
        var collected: [Journey] = []

        for _ in 0..<h.options.maxDepartureScans {
            let query = RaptorQuery(access: access, egress: egress,
                                    departure: departure, horizon: deadline &- departure)
            let result = RaptorEngine(options: h.options).run(h.timetable, query)
            let batch = JourneyReconstruction.alternatives(
                timetable: h.timetable, result: result, query: query,
                origin: origin, destination: destination, options: h.options)
            guard !batch.isEmpty else { break }
            for journey in batch where seen.insert(journey).inserted { collected.append(journey) }

            var earliest: Int32?
            for journey in batch {
                for leg in journey.legs {
                    guard case .ride(_, _, _, _, _, _, let d, _, _) = leg else { continue }
                    let seconds = Int32(h.timetable.axisSeconds(for: d))
                    if earliest == nil || seconds < earliest! { earliest = seconds }
                    break
                }
            }
            guard let boarding = earliest else { break }
            departure = boarding &+ 1
            guard departure <= deadline else { break }
        }
        return collected
    }

    /// Four pairs spanning the city: centre to hospital, beach to centre, and two across the
    /// hills, so the set is not all one kind of journey.
    private func pairs(_ h: Harness) throws -> [(Stop, Stop)] {
        let all = try h.repository.allStops()
        func find(_ fragment: String) throws -> Stop {
            try #require(all.first { $0.name.contains(fragment) }, "no stop matching '\(fragment)'")
        }
        return [
            (try find("Urzáiz - Príncipe"), try find("H. A. Cunqueiro (Porta")),
            (try find("Avda. de Samil (Verbum)"), try find("Rúa de Urzáiz - Est")),
            (try find("Avda. das Camelias  3"), try find("Avda. de Samil (Dunas)")),
            (try find("Praza de Suárez Llan"), try find("Estrada de Bembrive  3")),
        ]
    }

    /// C2, and the reason it was never implemented.
    ///
    /// The audit claimed the departure scan wasted passes because it restarts one second
    /// after the *earliest* boarding of a whole batch. Measured, it does not: over sixteen
    /// passes across four pairs, exactly one produced no new journey — and that pair's next
    /// two passes produced three more, so an early exit would have made the answer worse.
    /// The claim was made by reading and is retracted by measuring.
    @Test("Cada pase del rebarrido aporta trayectos nuevos")
    func theDepartureScanEarnsItsPasses() async throws {
        let h = try await harness()
        var totalPasses = 0
        var barrenPasses = 0

        for (from, to) in try pairs(h) {
            var seen = Set<Journey>()
            var departure = Int32(h.timetable.axisSeconds(
                for: h.day.startOfDay(in: h.repository.calendar)!.addingTimeInterval(9 * 3_600)))
            let deadline = departure &+ Int32(h.options.searchHorizon)

            for pass in 0..<h.options.maxDepartureScans {
                let before = seen.count
                // One pass at a time, rather than `collect`'s whole loop: measuring what
                // each pass adds is the entire point of this test.
                let batch = try collectOnePass(h, from: from, to: to,
                                               departure: departure, deadline: deadline)
                guard !batch.journeys.isEmpty else { break }
                for journey in batch.journeys { seen.insert(journey) }
                totalPasses += 1
                if seen.count == before && pass > 0 { barrenPasses += 1 }
                guard let boarding = batch.earliestBoarding else { break }
                departure = boarding &+ 1
                guard departure <= deadline else { break }
            }
        }

        #expect(totalPasses >= 12, "the scan should be doing real work on four pairs")
        // Generous: the point is that passes are productive, not that none ever repeats.
        #expect(Double(barrenPasses) / Double(totalPasses) < 0.35,
                "\(barrenPasses)/\(totalPasses) passes produced nothing — the restart rule regressed")
    }

    private func collectOnePass(
        _ h: Harness, from: Stop, to: Stop, departure: Int32, deadline: Int32
    ) throws -> (journeys: [Journey], earliestBoarding: Int32?) {
        let walk = WalkModel(options: h.options)
        func walks(_ stop: Stop) throws -> [StopWalk] {
            try h.repository.nearbyStops(
                latitude: stop.latitude, longitude: stop.longitude,
                radiusMetres: h.options.accessRadiusMetres, limit: h.options.maxNearbyStops
            ).compactMap { nearby in
                guard let index = h.timetable.index(of: nearby.stop.id) else { return nil }
                return StopWalk(stop: index,
                                seconds: Int32(walk.seconds(metres: nearby.distanceMetres,
                                                            as: .accessEgress)))
            }
        }
        let query = RaptorQuery(access: try walks(from), egress: try walks(to),
                                departure: departure, horizon: deadline &- departure)
        let result = RaptorEngine(options: h.options).run(h.timetable, query)
        let batch = JourneyReconstruction.alternatives(
            timetable: h.timetable, result: result, query: query,
            origin: .coordinate(Coordinate(from), label: from.name),
            destination: .coordinate(Coordinate(to), label: to.name), options: h.options)
        var earliest: Int32?
        for journey in batch {
            for leg in journey.legs {
                guard case .ride(_, _, _, _, _, _, let d, _, _) = leg else { continue }
                let seconds = Int32(h.timetable.axisSeconds(for: d))
                if earliest == nil || seconds < earliest! { earliest = seconds }
                break
            }
        }
        return (batch, earliest)
    }

    /// C1's premise, kept as a live check rather than a claim in a document.
    ///
    /// If the five-axis dominance ever starts pulling its weight on real queries, the extra
    /// filter is dead code and this will say so.
    @Test("La dominancia de cinco ejes descarta poco o nada por sí sola")
    func paretoAloneBarelyFilters() async throws {
        let h = try await harness()
        var pairsWhereItDidNothing = 0
        var total = 0

        for (from, to) in try pairs(h) {
            let collected = try collect(h, from: from, to: to, hour: 9)
            guard collected.count > 3 else { continue }
            total += 1
            if JourneyShortlist.undominated(collected).count == collected.count {
                pairsWhereItDidNothing += 1
            }
        }
        #expect(total >= 3)
        #expect(pairsWhereItDidNothing >= 1,
                "la dominancia ya filtra sola; conviene revisar si `plausible` sigue haciendo falta")
    }

    /// The two properties the filter must have at once, on real data: it has to prune, and
    /// it must never take away a criterion's own answer.
    @Test("La poda recorta sin quitarle a ningún criterio su respuesta")
    func pruningIsRealAndSafe() async throws {
        let h = try await harness()
        var prunedSomewhere = false

        for (from, to) in try pairs(h) {
            let front = JourneyShortlist.undominated(try collect(h, from: from, to: to, hour: 9))
            guard front.count > 2 else { continue }
            let kept = Set(JourneyShortlist.plausible(
                front, slack: h.options.alternativeSlackSeconds))

            if kept.count < front.count { prunedSomewhere = true }
            for criterion in JourneyOrdering.allCases {
                let winner = try #require(criterion.apply(front, limit: 1).first)
                #expect(kept.contains(winner),
                        "«\(criterion.label)» perdió su respuesta en \(from.name) → \(to.name)")
            }
        }
        #expect(prunedSomewhere, "la poda no quitó nada en ninguna consulta real")
    }

    /// The regression that matters most, on real data. The first draft of the cost measured
    /// from the query's clock and cut a five-option search to one, the four losers being the
    /// next four buses.
    @Test("La poda conserva varias salidas sucesivas")
    func keepsMoreThanOneDeparture() async throws {
        let h = try await harness()

        for (from, to) in try pairs(h) {
            let front = JourneyShortlist.undominated(try collect(h, from: from, to: to, hour: 9))
            guard front.count >= 4 else { continue }
            let kept = JourneyShortlist.plausible(
                front, slack: h.options.alternativeSlackSeconds)
            let boardings = Set(kept.compactMap { JourneyOrdering.firstBoarding($0) })
            #expect(boardings.count >= 2,
                    "\(from.name) → \(to.name): la poda dejó una sola salida de \(front.count) opciones")
        }
    }
}
