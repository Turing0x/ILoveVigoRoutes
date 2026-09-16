import Testing
import Foundation
@testable import VigoCore

/// «Estoy en esta parada», on the case that showed it was broken.
///
/// Standing at Gregorio Espino 33 (5720), heading for the Concello, the planner offered a walk
/// to another stop and never the 4C, which leaves from 5720 and runs straight there. A stop
/// chosen as origin was being treated as a point on the pavement.
///
/// Skipped unless `VIGO_GTFS_ZIP` points at a downloaded `gtfs_vigo.zip`, like the other
/// real-feed suites.
@Suite("Stop origin against the real feed",
       .enabled(if: ProcessInfo.processInfo.environment["VIGO_GTFS_ZIP"] != nil))
struct StopOriginRealFeedTests {

    @Test("Desde la parada 5720 al Concello, todo sale de la 5720 y el 4C está")
    func gregorioEspinoToConcello() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["VIGO_GTFS_ZIP"])
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let parsed = try GTFSParser().parse(from: try GTFSZipProvider(data: data))
        let db = try AppDatabase.inMemory()
        _ = try GTFSImporter(database: db).import(feed: parsed.feed, parseWarnings: parsed.warnings)
        let repository = TransitRepository(database: db)
        let planner = JourneyPlanner(repository: repository,
                                     store: TimetableStore(repository: repository))

        let stop = try #require(try repository.stop(vitrasaCode: VitrasaStopCode(5720)))
        // Praza do Rei, the door of the Concello.
        let concello = Place.coordinate(Coordinate(latitude: 42.23545, longitude: -8.72685),
                                        label: "Concello de Vigo")

        // A weekday inside the observed window, at 10:00.
        let calendar = repository.calendar
        let day = try #require(try repository.observedServiceDays().sorted().first { day in
            guard let start = day.startOfDay(in: calendar) else { return false }
            return (2...6).contains(calendar.component(.weekday, from: start))
        })
        let departure = try #require(day.startOfDay(in: calendar)).addingTimeInterval(10 * 3_600)

        let result = try await planner.plan(PlanQuery(origin: .stop(stop), destination: concello,
                                                      departure: departure))
        guard case .journeys(let journeys) = result.outcome else {
            Issue.record("expected journeys, got \(result.outcome)")
            return
        }
        func describe(_ j: Journey) -> String {
            j.legs.map { leg -> String in
                switch leg {
                case .walk(_, let to, let s, _): return "walk \(s)s→\(to.label)"
                case .ride(_, let line, _, _, let board, let alight, let dep, _, _):
                    return "\(line) \(board.name)→\(alight.name) @\(dep)"
                }
            }.joined(separator: " | ")
        }
        let summary = journeys.map(describe).joined(separator: "\n")

        let buses = journeys.filter { $0.legs.contains { if case .ride = $0 { true } else { false } } }
        #expect(!buses.isEmpty, "no bus journeys:\n\(summary)")
        for journey in buses {
            guard let first = journey.legs.first(where: { if case .ride = $0 { true } else { false } }),
                  case .ride(_, _, _, _, let board, _, _, _, _) = first else { continue }
            #expect(board.id == stop.id, "boards away from 5720:\n\(describe(journey))")
        }
        #expect(buses.contains { $0.legs.contains {
            if case .ride(_, let line, _, _, _, _, _, _, _) = $0 { line == "4C" } else { false }
        } }, "no 4C offered:\n\(summary)")
    }
}
