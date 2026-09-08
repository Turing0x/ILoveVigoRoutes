import Foundation

/// One possible answer to "which bus is this": a pattern, a trip of it, and the position the
/// traveller is at.
public struct OnboardTripCandidate: Sendable, Hashable {
    public let pattern: Int
    /// Index of the trip **within the pattern**, the only sense `Timetable` has.
    public let trip: Int
    public let position: Int
    /// Compact stop index, for the timetable's arrays.
    public let stop: Int32
    public let routeShortName: String
    public let headsign: String?
    /// The trip's scheduled departure at `position`, in axis seconds.
    public let scheduledAtPosition: Int32
    /// Signed, positive is late.
    public let delaySeconds: Int32
    public let distanceMetres: Double
    /// Lower is better. Only meaningful against other candidates of the same query.
    public let score: Double

    public init(pattern: Int, trip: Int, position: Int, stop: Int32,
                routeShortName: String, headsign: String?,
                scheduledAtPosition: Int32, delaySeconds: Int32,
                distanceMetres: Double, score: Double) {
        self.pattern = pattern; self.trip = trip; self.position = position; self.stop = stop
        self.routeShortName = routeShortName; self.headsign = headsign
        self.scheduledAtPosition = scheduledAtPosition; self.delaySeconds = delaySeconds
        self.distanceMetres = distanceMetres; self.score = score
    }
}

/// Turns "I am on the 11" plus a GPS fix into a specific trip at a specific position.
///
/// **Why this is a declaration and not a detection.** The realtime API answers with a line, a
/// destination and a countdown at one stop; it has no vehicle or trip identifier, so nothing
/// in it can say which bus somebody is sitting on (`FirstBoardingMatch`'s doc comment covers
/// the same limit for a different question). The line comes from the traveller; the position,
/// the direction and the trip come from geometry and the timetable; and when those cannot
/// separate two answers, the traveller is asked rather than guessed at.
///
/// **The known approximation.** Candidates are snapped to the pattern's *stops*, not to its
/// shape polyline: shapes live in SQLite, and keeping this a pure function of
/// `(Timetable, Input)` is what lets `swift test` cover it on a Mac with no simulator. Between
/// two stops 600 m apart the snap can be a few hundred metres off, which the time filter then
/// cleans up — a candidate only survives if a trip of that pattern is actually passing there
/// now.
public enum OnboardTripResolution {

    public struct Input: Sendable, Hashable {
        public let declaredLine: String
        public let coordinate: Coordinate
        /// The fix's own reported accuracy, widening the snap radius rather than rejecting a
        /// bad fix outright. `nil` when unknown.
        public let horizontalAccuracyMetres: Double?
        public let now: Date
        /// An earlier fix, when there is one. Its only job is to tell the two directions of a
        /// line apart before the first stop has been passed.
        public let previous: Previous?

        public struct Previous: Sendable, Hashable {
            public let coordinate: Coordinate
            public let at: Date
            public init(coordinate: Coordinate, at: Date) {
                self.coordinate = coordinate; self.at = at
            }
        }

        public init(declaredLine: String, coordinate: Coordinate,
                    horizontalAccuracyMetres: Double? = nil, now: Date,
                    previous: Previous? = nil) {
            self.declaredLine = declaredLine; self.coordinate = coordinate
            self.horizontalAccuracyMetres = horizontalAccuracyMetres
            self.now = now; self.previous = previous
        }
    }

    public enum Outcome: Sendable, Hashable {
        case resolved(OnboardTripCandidate)
        /// Two or more answers that geometry and time cannot separate — different directions
        /// of the same line, typically. The UI asks which one.
        case ambiguous([OnboardTripCandidate])
        case noPatternForLine(String)
        case tooFarFromLine(nearestMetres: Double)
        case noTripRunningNow(routeShortName: String)
    }

    public static func resolve(_ input: Input, timetable: Timetable,
                               options: OnboardOptions = OnboardOptions()) -> Outcome {
        let patterns = OnboardPatternLookup.patterns(forLine: input.declaredLine, in: timetable)
        guard !patterns.isEmpty else { return .noPatternForLine(input.declaredLine) }

        let radius = options.maxSnapMetres + (input.horizontalAccuracyMetres ?? 0)
        let nowAxis = Int32(timetable.axisSeconds(for: input.now))

        var nearest = Double.greatestFiniteMagnitude
        var sawNearbyPosition = false
        var candidates: [OnboardTripCandidate] = []

        for pattern in patterns {
            let positions = timetable.stopCount(ofPattern: pattern)
            for position in 0..<positions {
                let metres = OnboardPatternLookup.metres(from: input.coordinate,
                                                         toPosition: position,
                                                         ofPattern: pattern, in: timetable)
                nearest = min(nearest, metres)
                guard metres <= radius else { continue }
                sawNearbyPosition = true

                // A loop pattern puts the same stop at two positions, and both land here. It
                // is the window below that separates them: only one of the two has a trip
                // passing at this hour. Never resolve a loop by taking the first slot.
                let trips = OnboardPatternLookup.trips(
                    ofPattern: pattern, through: position, in: timetable,
                    nowAxis: nowAxis, late: options.lateWindowSeconds,
                    early: options.earlyWindowSeconds)
                for trip in trips {
                    let scheduled = timetable.departure(pattern: pattern, trip: trip,
                                                        position: position)
                    let delay = nowAxis &- scheduled
                    let score = score(metres: metres, radius: radius, delay: delay,
                                      pattern: pattern, position: position,
                                      input: input, timetable: timetable, options: options)
                    candidates.append(OnboardTripCandidate(
                        pattern: pattern, trip: trip, position: position,
                        stop: timetable.stopIndex(pattern: pattern, position: position),
                        routeShortName: timetable.patternRouteShortName[pattern],
                        headsign: timetable.tripRef(pattern: pattern, trip: trip).headsign,
                        scheduledAtPosition: scheduled, delaySeconds: delay,
                        distanceMetres: metres, score: score))
                }
            }
        }

        guard sawNearbyPosition else { return .tooFarFromLine(nearestMetres: nearest) }
        guard !candidates.isEmpty else {
            return .noTripRunningNow(routeShortName:
                timetable.patternRouteShortName[patterns[0]])
        }

        // Sorted by score, then by pattern and trip so a tie resolves the same way on every
        // run — the same reason `RaptorEngine` sorts its scan order.
        candidates.sort {
            ($0.score, $0.pattern, $0.trip, $0.position)
                < ($1.score, $1.pattern, $1.trip, $1.position)
        }
        let best = candidates[0]

        // Ambiguity is only ever about *which way the bus is going*: two candidates of the
        // same pattern and headsign differ in trip, and the delay term already picks the
        // right one. Two candidates that disagree about the direction are a question only the
        // traveller can answer.
        let rivals = candidates.filter {
            $0.score - best.score <= options.ambiguityMargin
                && ($0.pattern != best.pattern || $0.headsign != best.headsign)
        }
        guard rivals.isEmpty else {
            var shown = [best]
            for rival in rivals where !shown.contains(where: {
                $0.pattern == rival.pattern && $0.headsign == rival.headsign
            }) {
                shown.append(rival)
            }
            return .ambiguous(Array(shown.prefix(options.maxAmbiguousCandidates)))
        }
        return .resolved(best)
    }

    /// Lines with a stop within the snap radius of a coordinate, folded and sorted the way the
    /// rest of the app orders line names.
    ///
    /// What turns a 45-line picker into two or three: the traveller is standing inside a bus
    /// on a street, and only a handful of lines run down it.
    public static func linesNearby(coordinate: Coordinate, timetable: Timetable,
                                   options: OnboardOptions = OnboardOptions()) -> [String] {
        var found: Set<String> = []
        for pattern in 0..<timetable.patternCount {
            for position in 0..<timetable.stopCount(ofPattern: pattern) {
                let metres = OnboardPatternLookup.metres(from: coordinate, toPosition: position,
                                                         ofPattern: pattern, in: timetable)
                if metres <= options.maxSnapMetres {
                    found.insert(timetable.patternRouteShortName[pattern])
                    break
                }
            }
        }
        return found.sorted(by: TransitRepository.lineNameOrdering)
    }

    // MARK: - Puntuación

    /// Distance and lateness, each normalised to its own tolerance so neither drowns the
    /// other, minus a bonus for a direction the traveller is demonstrably moving in.
    private static func score(metres: Double, radius: Double, delay: Int32,
                              pattern: Int, position: Int,
                              input: Input, timetable: Timetable,
                              options: OnboardOptions) -> Double {
        let distanceTerm = metres / max(radius, 1)
        let delayTerm = Double(abs(Int(delay))) / Double(options.lateWindowSeconds)
        return distanceTerm + delayTerm - directionBonus(
            pattern: pattern, position: position, input: input, timetable: timetable)
    }

    /// A quarter of a point when an earlier fix maps to an *earlier* position of this same
    /// pattern — i.e. the bus has been moving forwards along it.
    ///
    /// Only this can separate the two directions of a line while the bus is between stops,
    /// which is most of the time. It is a bonus and not a filter on purpose: one stale fix
    /// should tilt the answer, never decide it.
    private static func directionBonus(pattern: Int, position: Int,
                                       input: Input, timetable: Timetable) -> Double {
        guard let previous = input.previous, previous.at < input.now else { return 0 }
        var bestPosition: Int?
        var bestMetres = Double.greatestFiniteMagnitude
        for candidate in 0..<timetable.stopCount(ofPattern: pattern) {
            let metres = OnboardPatternLookup.metres(from: previous.coordinate,
                                                     toPosition: candidate,
                                                     ofPattern: pattern, in: timetable)
            if metres < bestMetres { bestMetres = metres; bestPosition = candidate }
        }
        guard let bestPosition, bestPosition < position else { return 0 }
        return 0.25
    }
}
