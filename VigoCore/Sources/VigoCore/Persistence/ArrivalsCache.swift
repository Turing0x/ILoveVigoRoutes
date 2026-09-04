import Foundation
import GRDB

/// Persists the last successful realtime response per stop.
///
/// Exists so a cold start with no network still shows something useful — clearly marked
/// as cached, with its age, never dressed up as live.
public struct ArrivalsCache: Sendable {
    let database: AppDatabase

    public init(database: AppDatabase) { self.database = database }

    public func store(_ snapshot: ArrivalsSnapshot) throws {
        let payload = try JSONEncoder().encode(CachedSnapshot(snapshot))
        try database.writer.write { db in
            try CachedArrivalsRow(vitrasaCode: snapshot.stopCode.value,
                                  fetchedAt: snapshot.fetchedAt,
                                  payload: payload).upsert(db)
        }
    }

    public func load(_ code: VitrasaStopCode) throws -> ArrivalsSnapshot? {
        try database.writer.read { db in
            guard let row = try CachedArrivalsRow.fetchOne(db, key: code.value) else { return nil }
            let decoded = try JSONDecoder().decode(CachedSnapshot.self, from: row.payload)
            return decoded.snapshot(code: code, fetchedAt: row.fetchedAt)
        }
    }

    public func clear() throws {
        _ = try database.writer.write { db in
            try db.execute(sql: "DELETE FROM cachedArrivals")
        }
    }

    /// Stored shape, kept separate from `ArrivalsSnapshot` so that changing the in-memory
    /// model cannot silently invalidate rows already on disk.
    private struct CachedSnapshot: Codable {
        struct Entry: Codable {
            let rawLine: String
            let destination: String
            let minutes: Int
            let metres: Int?
        }
        let stopName: String?
        let latitude: Double?
        let longitude: Double?
        let entries: [Entry]

        init(_ snapshot: ArrivalsSnapshot) {
            stopName = snapshot.stopName
            latitude = snapshot.latitude
            longitude = snapshot.longitude
            entries = snapshot.arrivals.map { arrival in
                var metres: Int?
                if case .vehicleTracked(let m) = arrival.confidence { metres = m }
                return Entry(rawLine: arrival.rawLine, destination: arrival.destination,
                             minutes: arrival.minutes, metres: metres)
            }
        }

        func snapshot(code: VitrasaStopCode, fetchedAt: Date) -> ArrivalsSnapshot {
            ArrivalsSnapshot(
                stopCode: code, stopName: stopName,
                latitude: latitude, longitude: longitude,
                arrivals: entries.map {
                    Arrival(rawLine: $0.rawLine, destination: $0.destination,
                            minutes: $0.minutes, metres: $0.metres)
                },
                fetchedAt: fetchedAt)
        }
    }
}
