import Foundation

/// GTFS `stop_id` — the feed's internal key, the one that joins to `stop_times`.
///
/// This is **not** the identifier the realtime API accepts. Passing one of these
/// to the network layer returns HTTP 200 with empty arrays — a silent failure.
/// See `VitrasaStopCode`.
public struct StopID: Hashable, Sendable, Codable, RawRepresentable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    // Encoded as a bare string so database rows and JSON stay flat.
    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer(); try c.encode(rawValue)
    }
}

/// The public stop number used by InfoBus and the Concello realtime API.
///
/// Derived from GTFS `stop_code` by dropping the leading `P` and any leading
/// zeros: `P006930` → `6930`. Verified against all 1149 stops in the feed
/// (1149 matches, 0 mismatches) — see `DATA-SOURCES.md` §2.8.
public struct VitrasaStopCode: Hashable, Sendable, Codable, CustomStringConvertible {
    public let value: Int
    public init(_ value: Int) { self.value = value }

    /// Parses a GTFS `stop_code` such as `P006930` or `PA20113`.
    /// Returns `nil` when no digits are present.
    public init?(gtfsStopCode: String) {
        let digits = gtfsStopCode.drop { !$0.isNumber }
        guard let value = Int(digits) else { return nil }
        self.init(value)
    }

    public var description: String { String(value) }

    // Encoded as a bare integer so database rows and JSON stay flat.
    public init(from decoder: any Decoder) throws {
        value = try decoder.singleValueContainer().decode(Int.self)
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer(); try c.encode(value)
    }
}

public struct RouteID: Hashable, Sendable, Codable, RawRepresentable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    // Encoded as a bare string so database rows and JSON stay flat.
    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer(); try c.encode(rawValue)
    }
}

public struct TripID: Hashable, Sendable, Codable, RawRepresentable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    // Encoded as a bare string so database rows and JSON stay flat.
    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer(); try c.encode(rawValue)
    }
}

public struct ServiceID: Hashable, Sendable, Codable, RawRepresentable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    // Encoded as a bare string so database rows and JSON stay flat.
    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer(); try c.encode(rawValue)
    }
}

public struct ShapeID: Hashable, Sendable, Codable, RawRepresentable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    // Encoded as a bare string so database rows and JSON stay flat.
    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer(); try c.encode(rawValue)
    }
}
