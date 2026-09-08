import Foundation

/// A bus the traveller is riding right now, declared by them and followed by GPS.
///
/// **Not an `ActiveJourneySnapshot`, and not a smaller one.** That type is a plan already
/// chosen, ridden to a destination that is already known, and its doc comment says in as many
/// words that it is never replanned. This is the opposite situation: a vehicle with no
/// destination attached yet, whose entire reason to exist is that the traveller may think of
/// one mid-ride and ask whether this bus serves it. The two are mutually exclusive — starting
/// one ends the other — and accepting an alternative planned from this ride converts it into
/// an `ActiveJourneySnapshot`.
///
/// **Why the ride is declared and not detected.** The realtime source reports a line, a
/// destination and a countdown at one stop; nothing in it can be joined to a GTFS trip
/// (`RealtimeModels.swift`, `FirstBoardingMatch`). So the traveller names the line and the
/// app resolves the rest from where they are.
///
/// Anchoring follows the rule the rest of the app already obeys: every stop is a `stopID`
/// **plus a fallback coordinate**, because `GTFSImporter` clears and rewrites `stop` on each
/// refresh. Pattern and trip indices get the same treatment one level up — see
/// `patternStopIDs`.
public struct OnboardRide: Codable, Sendable, Hashable {
    public struct StopRef: Codable, Sendable, Hashable {
        /// `nil` only if the stop vanished from the feed between declaring and re-reading.
        public let stopID: StopID?
        public let name: String
        public let latitude: Double
        public let longitude: Double

        public init(stopID: StopID?, name: String, latitude: Double, longitude: Double) {
            self.stopID = stopID; self.name = name
            self.latitude = latitude; self.longitude = longitude
        }

        public var coordinate: Coordinate { Coordinate(latitude: latitude, longitude: longitude) }

        public static func from(_ stop: Stop) -> StopRef {
            StopRef(stopID: stop.id, name: stop.name,
                    latitude: stop.latitude, longitude: stop.longitude)
        }
    }

    /// How the direction of travel was settled.
    public enum Confidence: String, Codable, Sendable {
        /// The resolver was confident enough on its own.
        case inferred
        /// The traveller picked among ambiguous candidates. Never downgraded afterwards.
        case confirmedByUser
    }

    /// As the feed spells it, for display.
    public let routeShortName: String
    /// The comparison key — `TextNormalization.normalizedLineName`. Stored rather than
    /// recomputed so a change to the folding rules cannot silently re-point a stored ride.
    public let normalizedLine: String
    public let headsign: String?

    /// **The pattern's fingerprint.** Pattern indices are rebuilt from scratch by
    /// `TimetableBuilder` on every reimport *and* on every anchor day, so an index stored here
    /// would point at a different pattern tomorrow. The ordered stop-id sequence is the only
    /// identity that survives both — and it is what tells the two directions of a line apart,
    /// and the two visits of a loop.
    public let patternStopIDs: [StopID]

    /// Informative only, exactly like `ActiveJourneySnapshot.Ride.tripID`: a reimport may drop
    /// it. Re-resolution falls back to matching by scheduled time.
    public let tripID: TripID?

    /// Where the traveller got on, when they know it. `boardPosition` is its index in
    /// `patternStopIDs`, which a loop makes ambiguous by id alone.
    public let boardStop: StopRef
    public let boardPosition: Int

    /// The last stop the traveller is known to have reached, and its index in the pattern.
    public let currentStop: StopRef
    public let currentPosition: Int

    /// The trip's scheduled time at `currentPosition`, as an absolute date.
    ///
    /// Never axis seconds: the axis is relative to a `Timetable`'s anchor midnight, and the
    /// anchor moves. A stored axis value would mean a different instant tomorrow.
    public let scheduledAtCurrent: Date

    /// Signed, positive is late. Observed by `OnboardProgress` from the times the traveller
    /// actually passed stops — never from the realtime countdown, which cannot see this
    /// vehicle.
    public let observedDelaySeconds: Int

    public let declaredAt: Date
    /// When the position was last confirmed. What staleness is measured from, and what the
    /// UI shows the age of — the app only tracks location in the foreground, so claiming a
    /// live position would be a claim the data does not support.
    public let updatedAt: Date
    public let confidence: Confidence

    public init(routeShortName: String, normalizedLine: String? = nil, headsign: String?,
                patternStopIDs: [StopID], tripID: TripID?,
                boardStop: StopRef, boardPosition: Int,
                currentStop: StopRef, currentPosition: Int,
                scheduledAtCurrent: Date, observedDelaySeconds: Int,
                declaredAt: Date, updatedAt: Date, confidence: Confidence) {
        self.routeShortName = routeShortName
        self.normalizedLine = normalizedLine
            ?? TextNormalization.normalizedLineName(routeShortName)
        self.headsign = headsign
        self.patternStopIDs = patternStopIDs
        self.tripID = tripID
        self.boardStop = boardStop; self.boardPosition = boardPosition
        self.currentStop = currentStop; self.currentPosition = currentPosition
        self.scheduledAtCurrent = scheduledAtCurrent
        self.observedDelaySeconds = observedDelaySeconds
        self.declaredAt = declaredAt; self.updatedAt = updatedAt
        self.confidence = confidence
    }

    /// The same ride, moved forward to a position the traveller has since reached.
    ///
    /// `confidence` is carried, never downgraded: a direction the traveller confirmed by hand
    /// stays confirmed for the rest of the ride.
    public func advanced(to stop: StopRef, position: Int, scheduledAtCurrent: Date,
                         observedDelaySeconds: Int, at now: Date) -> OnboardRide {
        OnboardRide(routeShortName: routeShortName, normalizedLine: normalizedLine,
                    headsign: headsign, patternStopIDs: patternStopIDs, tripID: tripID,
                    boardStop: boardStop, boardPosition: boardPosition,
                    currentStop: stop, currentPosition: position,
                    scheduledAtCurrent: scheduledAtCurrent,
                    observedDelaySeconds: observedDelaySeconds,
                    declaredAt: declaredAt, updatedAt: now, confidence: confidence)
    }
}

extension OnboardRide {
    /// The ride a resolved candidate describes, ready to store.
    ///
    /// The boarding stop defaults to where the traveller is now: somebody who declares a bus
    /// mid-route often does not remember which stop they got on at, and inventing one would be
    /// a fact nobody supplied. When it is known — the stop-detail shortcut knows it exactly —
    /// the caller passes it.
    public init(_ candidate: OnboardTripCandidate, in timetable: Timetable, now: Date,
                boardPosition: Int? = nil, confidence: Confidence = .inferred) {
        let stopAt: (Int) -> Stop = { position in
            timetable.stops[Int(timetable.stopIndex(pattern: candidate.pattern, position: position))]
        }
        let board = boardPosition ?? candidate.position
        self.init(
            routeShortName: candidate.routeShortName,
            headsign: candidate.headsign,
            patternStopIDs: (0..<timetable.stopCount(ofPattern: candidate.pattern))
                .map { stopAt($0).id },
            tripID: timetable.tripRef(pattern: candidate.pattern, trip: candidate.trip).tripID,
            boardStop: .from(stopAt(board)), boardPosition: board,
            currentStop: .from(stopAt(candidate.position)), currentPosition: candidate.position,
            scheduledAtCurrent: timetable.date(
                forAxisSeconds: Int(candidate.scheduledAtPosition)),
            // The lateness implied by where the bus is right now, kept from the first moment:
            // a traveller who declares a bus that is already eight minutes late should not be
            // shown schedule times until the next stop goes by.
            observedDelaySeconds: Int(candidate.delaySeconds),
            declaredAt: now, updatedAt: now, confidence: confidence)
    }
}

// MARK: - Caducidad

public enum OnboardRideStaleness: Sendable, Hashable {
    case active
    case stale(since: Date)
}

extension OnboardRide {
    /// Pure: `now` comes in as a parameter, the same contract `ActiveJourneySnapshot.staleness`
    /// and `FirstBoardingMatch.hasDeparted` already use.
    ///
    /// **Measured from `updatedAt`, not from a scheduled arrival.** An onboard ride has no
    /// arrival to be late for — it has a position that was last confirmed at some moment, and
    /// once that moment is old enough the honest thing is to ask, not to keep drawing a
    /// capsule that claims to know where the traveller is.
    public func staleness(now: Date,
                          grace: TimeInterval = OnboardOptions().staleGraceSeconds)
        -> OnboardRideStaleness {
        let deadline = updatedAt.addingTimeInterval(grace)
        return now <= deadline ? .active : .stale(since: deadline)
    }
}
