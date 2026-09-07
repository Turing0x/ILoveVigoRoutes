import Testing
import Foundation
@testable import VigoCore

/// Our planner against the Concello's, on the same origin–destination pairs.
///
/// **What this is for.** `BruteForceReference` already checks that `RaptorEngine` finds the
/// optimum *of the timetable it was given*. It cannot check whether that timetable, those
/// walking times and those transfer rules add up to an answer a person would recognise. The
/// Concello runs OpenTripPlanner over the same Vitrasa GTFS
/// (`AUDITORIA-MOTOR-VS-CONCELLO.md` §2.4 — one feed, same agency, the same 43 routes with
/// service), which makes it the only independent implementation of this exact problem that
/// exists. Disagreeing with it is not proof of a bug; agreeing with it closely is decent
/// evidence of not having one, and the size of the disagreement is a number that moves when
/// the engine changes. That is what turns "it still gets it wrong sometimes" into something
/// that can be worked on.
///
/// **Opt-in twice over**, because it reaches a third party's public infrastructure:
///
///     VIGO_GTFS_ZIP=/path/to/gtfs_vigo.zip VIGO_OTP_DIFF=1 swift test --filter OTPDifferential
///
/// It is not part of any ordinary run and it is not CI's business. Six pairs, one at a time,
/// spaced — municipal infrastructure serving its own city's transit data, and there is no
/// reason to lean on it. A sweep does not belong here.
///
/// **What is not compared, and why.** Not the lines chosen: OTP optimises a generalized cost
/// and we produce a Pareto front, so the two legitimately pick different buses between the
/// same two points. What is compared is door-to-door arrival, which is the thing both are
/// ultimately answering and the thing a passenger notices.
///
/// **A worked example of how to read a disagreement**, from the first run of this suite. On
/// Camelias → Samil at 09:00 we arrived at 09:25 and OTP at 09:43 — eighteen minutes apart,
/// far outside anything that could be rounding. Arriving *earlier* is not self-evidently
/// right; it is exactly what an over-optimistic walking model looks like. Checked against the
/// raw feed, our journey was 12A from Avda. das Camelias 80 to Avda. de Europa, a transfer to
/// 15A, alighting at Avda. de Europa 102 — a stop 152 m from the destination. Every leg
/// exists in `stop_times.txt` at those times. OTP does not return that itinerary at any
/// `walkReluctance` we asked it for; it prefers a direct bus with 1757 m of walking.
///
/// So the disagreement was real and ours was correct. That is the point of the suite: not to
/// match, but to make divergence visible enough to go and check.
@Suite("Differential against the Concello's OpenTripPlanner",
       .enabled(if: ProcessInfo.processInfo.environment["VIGO_GTFS_ZIP"] != nil
                 && ProcessInfo.processInfo.environment["VIGO_OTP_DIFF"] != nil),
       .serialized)
struct OTPDifferentialTests {

    private static let planEndpoint = "https://planificador-rutas.vigo.org/otp/routers/default/plan"

    /// Six pairs across the city: centre to hospital, beach to centre, and the hilly bits
    /// where a straight-line walking model has the most to get wrong.
    private static let pairs: [(name: String, from: Coordinate, to: Coordinate)] = [
        ("Príncipe → H. Álvaro Cunqueiro",
         Coordinate(latitude: 42.2358735, longitude: -8.7200833),
         Coordinate(latitude: 42.1910340, longitude: -8.7143031)),
        ("Samil → Urzáiz",
         Coordinate(latitude: 42.2138688, longitude: -8.7744106),
         Coordinate(latitude: 42.2358735, longitude: -8.7200833)),
        ("Camelias → Samil",
         Coordinate(latitude: 42.2280000, longitude: -8.7280000),
         Coordinate(latitude: 42.2102568, longitude: -8.7747406)),
        ("Bembrive → centro",
         Coordinate(latitude: 42.1950000, longitude: -8.6900000),
         Coordinate(latitude: 42.2358735, longitude: -8.7200833)),
        ("Navia → Praza de América",
         Coordinate(latitude: 42.2020000, longitude: -8.7590000),
         Coordinate(latitude: 42.2255000, longitude: -8.7290000)),
        ("Teis → Bouzas",
         Coordinate(latitude: 42.2480000, longitude: -8.6870000),
         Coordinate(latitude: 42.2220000, longitude: -8.7560000)),
    ]

    // MARK: - Their answer

    private struct OTPItinerary {
        let startTime: Date
        let endTime: Date
        let transfers: Int
        let walkMetres: Double
    }

    private func otpItineraries(from: Coordinate, to: Coordinate, at when: Date,
                                calendar: Calendar) async throws -> [OTPItinerary] {
        var components = URLComponents(string: Self.planEndpoint)!
        let date = DateFormatter()
        date.calendar = calendar
        date.timeZone = calendar.timeZone
        date.locale = Locale(identifier: "en_US_POSIX")
        date.dateFormat = "MM-dd-yyyy"
        let time = DateFormatter()
        time.calendar = calendar
        time.timeZone = calendar.timeZone
        time.locale = Locale(identifier: "en_US_POSIX")
        time.dateFormat = "h:mm a"

        components.queryItems = [
            .init(name: "fromPlace", value: "\(from.latitude),\(from.longitude)"),
            .init(name: "toPlace", value: "\(to.latitude),\(to.longitude)"),
            .init(name: "date", value: date.string(from: when)),
            .init(name: "time", value: time.string(from: when)),
            .init(name: "mode", value: "TRANSIT,WALK"),
            .init(name: "arriveBy", value: "false"),
            .init(name: "numItineraries", value: "3"),
            .init(name: "locale", value: "es"),
        ]

        let (data, _) = try await URLSession.shared.data(from: components.url!)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plan = root["plan"] as? [String: Any],
              let raw = plan["itineraries"] as? [[String: Any]]
        else { return [] }

        return raw.compactMap { entry in
            guard let start = entry["startTime"] as? Double,
                  let end = entry["endTime"] as? Double else { return nil }
            return OTPItinerary(
                startTime: Date(timeIntervalSince1970: start / 1000),
                endTime: Date(timeIntervalSince1970: end / 1000),
                transfers: entry["transfers"] as? Int ?? 0,
                walkMetres: entry["walkDistance"] as? Double ?? 0)
        }
    }

    // MARK: - Ours

    private func harness() async throws -> (JourneyPlanner, TransitRepository, ServiceDate) {
        let path = try #require(ProcessInfo.processInfo.environment["VIGO_GTFS_ZIP"])
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let parsed = try GTFSParser().parse(from: try GTFSZipProvider(data: data))
        let db = try AppDatabase.inMemory()
        _ = try GTFSImporter(database: db).import(feed: parsed.feed, parseWarnings: parsed.warnings)
        let repository = TransitRepository(database: db)
        let options = PlannerOptions()
        let store = TimetableStore(repository: repository, options: options)
        // A weekday in the middle of the observed window: both sides populated, and a day
        // both engines definitely have real data for rather than a projection.
        let observed = try repository.observedServiceDays().sorted()
        let day = observed[min(2, observed.count - 1)]
        return (JourneyPlanner(repository: repository, store: store, options: options),
                repository, day)
    }

    // MARK: - The comparison

    @Test("Nuestra mejor llegada no se aleja de la suya")
    func arrivalsAgree() async throws {
        let (planner, repository, day) = try await harness()
        let departure = try #require(day.startOfDay(in: repository.calendar))
            .addingTimeInterval(9 * 3_600)

        var deltas: [TimeInterval] = []
        var report: [String] = []

        for pair in Self.pairs {
            let theirs = try await otpItineraries(from: pair.from, to: pair.to,
                                                  at: departure, calendar: repository.calendar)
            // Spaced on purpose. This is municipal infrastructure and six sequential
            // requests with a pause between them is the whole budget this test has.
            try await Task.sleep(for: .milliseconds(800))

            guard let theirBest = theirs.map(\.endTime).min() else {
                report.append("  \(pair.name): OTP no devolvió nada")
                continue
            }

            let result = try await planner.plan(PlanQuery(
                origin: .coordinate(pair.from, label: "origen"),
                destination: .coordinate(pair.to, label: "destino"),
                departure: departure))
            guard case .journeys(let ours) = result.outcome,
                  let ourBest = ours.map(\.arrival).min() else {
                report.append("  \(pair.name): nosotros no devolvimos nada, OTP sí")
                Issue.record("\(pair.name): OTP encuentra ruta y nosotros no")
                continue
            }

            let delta = ourBest.timeIntervalSince(theirBest)
            deltas.append(delta)
            report.append(String(format: "  %-32@ nuestra %@  suya %@  Δ %+.0f min",
                                 pair.name as NSString,
                                 short(ourBest, repository.calendar),
                                 short(theirBest, repository.calendar),
                                 delta / 60))
        }

        print("\n=== diferencial contra el OTP del Concello ===")
        report.forEach { print($0) }

        let sorted = deltas.map { abs($0) }.sorted()
        guard !sorted.isEmpty else {
            Issue.record("ninguna pareja produjo comparación")
            return
        }
        let median = sorted[sorted.count / 2]
        print(String(format: "=== |Δ| mediana %.1f min, peor %.1f min, n=%d ===\n",
                     median / 60, sorted.last! / 60, sorted.count))

        // Deliberately loose, and it is a *ratchet* rather than a specification. The two
        // engines optimise different things — a generalized cost against a Pareto front —
        // so they will not agree exactly and should not be made to. What this catches is a
        // regression that makes us systematically worse: our best arrival drifting half an
        // hour from theirs means something in the feed handling, the walking model or the
        // transfer rules has broken, not that we chose a different bus.
        #expect(median <= 15 * 60,
                "la mediana se ha ido a \(Int(median / 60)) min; algo estructural ha cambiado")
        #expect(sorted.allSatisfy { $0 <= 45 * 60 },
                "alguna pareja se desvía más de 45 min de su respuesta")
    }

    /// The weaker but blunter check: wherever they find a journey, so do we.
    ///
    /// A gap here is the failure that matters most and the one hardest to notice from inside
    /// — an origin or destination our access radius, footpath table or calendar cannot serve
    /// at all, where theirs can.
    @Test("Donde ellos encuentran ruta, nosotros también")
    func coverageAgrees() async throws {
        let (planner, repository, day) = try await harness()
        let departure = try #require(day.startOfDay(in: repository.calendar))
            .addingTimeInterval(9 * 3_600)

        for pair in Self.pairs {
            let theirs = try await otpItineraries(from: pair.from, to: pair.to,
                                                  at: departure, calendar: repository.calendar)
            try await Task.sleep(for: .milliseconds(800))
            guard !theirs.isEmpty else { continue }

            let result = try await planner.plan(PlanQuery(
                origin: .coordinate(pair.from, label: "origen"),
                destination: .coordinate(pair.to, label: "destino"),
                departure: departure))
            switch result.outcome {
            case .journeys(let journeys):
                #expect(!journeys.isEmpty, "\(pair.name): lista vacía")
            case .walkOnly:
                Issue.record("\(pair.name): sólo ofrecemos ir a pie y OTP encuentra autobús")
            default:
                Issue.record("\(pair.name): \(result.outcome) frente a \(theirs.count) rutas de OTP")
            }
        }
    }

    private func short(_ date: Date, _ calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
