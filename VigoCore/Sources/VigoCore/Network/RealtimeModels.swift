import Foundation

/// How much to trust a single predicted arrival.
///
/// The upstream API reports `metros`, the distance of the vehicle from the stop. All
/// observations during Fase 0 were taken outside service hours and returned `-1`, so the
/// meaning of a non-negative value is **inferred, not confirmed** — see `DATA-SOURCES.md`
/// §3.7. The app therefore never claims "live" outright; `.vehicleTracked` is the
/// strongest thing it will say, and only when the API gives a distance.
public enum ArrivalConfidence: Sendable, Hashable {
    /// The API reported a distance, so a specific vehicle is being tracked.
    case vehicleTracked(metres: Int)
    /// The API gave no distance. Most likely a timetable-derived estimate.
    case operatorEstimate

    public var hasTrackedVehicle: Bool {
        if case .vehicleTracked = self { return true }
        return false
    }
}

public struct Arrival: Sendable, Hashable, Identifiable {
    /// Line label exactly as the API returned it.
    public let rawLine: String
    /// Folded label used to match against GTFS route names.
    public let normalizedLine: String
    /// Destination, cleaned of the trailing `*` and stray spacing the API includes.
    public let destination: String
    public let minutes: Int
    public let confidence: ArrivalConfidence

    public var id: String { "\(rawLine)|\(destination)|\(minutes)" }

    public init(rawLine: String, destination: String, minutes: Int, metres: Int?) {
        self.rawLine = rawLine
        self.normalizedLine = TextNormalization.normalizedLineName(rawLine)
        self.destination = TextNormalization.cleanedDestination(destination)
        self.minutes = minutes
        if let metres, metres >= 0 {
            self.confidence = .vehicleTracked(metres: metres)
        } else {
            self.confidence = .operatorEstimate
        }
    }
}

public struct ArrivalsSnapshot: Sendable, Hashable {
    public let stopCode: VitrasaStopCode
    /// Name as the realtime source knows it; may differ in punctuation from the GTFS name.
    public let stopName: String?
    public let latitude: Double?
    public let longitude: Double?
    public let arrivals: [Arrival]
    public let fetchedAt: Date

    public init(stopCode: VitrasaStopCode, stopName: String?, latitude: Double?,
                longitude: Double?, arrivals: [Arrival], fetchedAt: Date) {
        self.stopCode = stopCode; self.stopName = stopName
        self.latitude = latitude; self.longitude = longitude
        self.arrivals = arrivals; self.fetchedAt = fetchedAt
    }
}

public enum RealtimeError: Error, CustomStringConvertible, Sendable {
    /// The upstream returned an empty `parada` array, which is how it signals an
    /// unknown stop — with HTTP 200.
    case stopNotFound(VitrasaStopCode)
    case upstreamRejectedRequest(String)
    case transport(String)
    case decoding(String)
    case noRealtimeIdentifier(StopID)

    public var description: String {
        switch self {
        case .stopNotFound(let c): "the source does not know stop \(c)"
        case .upstreamRejectedRequest(let m): "the source rejected the request: \(m)"
        case .transport(let m): "network error: \(m)"
        case .decoding(let m): "unreadable response: \(m)"
        case .noRealtimeIdentifier(let s): "stop \(s) has no realtime code"
        }
    }

    /// Whether showing cached or timetabled data instead is the right fallback.
    public var isTransient: Bool {
        switch self {
        case .transport, .decoding, .upstreamRejectedRequest: true
        case .stopNotFound, .noRealtimeIdentifier: false
        }
    }
}

/// The single seam the rest of the app talks to.
///
/// Everything that knows the shape of the Concello's JSON lives behind this protocol, so a
/// change upstream is a one-file change here rather than a change everywhere arrivals are
/// displayed.
public protocol RealtimeArrivalsProviding: Sendable {
    func arrivals(for stopCode: VitrasaStopCode) async throws -> ArrivalsSnapshot
}
