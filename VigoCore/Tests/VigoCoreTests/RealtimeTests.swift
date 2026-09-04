import Testing
import Foundation
@testable import VigoCore

@Suite("Realtime decoding")
struct RealtimeTests {

    @Test("Decodes a captured live response")
    func decodesLiveResponse() throws {
        let data = Data(Fixture.liveArrivalsJSON.utf8)
        let snapshot = try ConcelloRealtimeClient.decode(
            data, stopCode: VitrasaStopCode(6930), fetchedAt: Date())
        #expect(snapshot.stopCode == VitrasaStopCode(6930))
        #expect(snapshot.stopName == "Praza de América  1")
        #expect(snapshot.arrivals.count == 3)
        #expect(snapshot.arrivals[0].rawLine == "N4")
        #expect(snapshot.arrivals[0].minutes == 29)
    }

    /// The API returns ISO-8859-1 and says so in Content-Type. Feeding those bytes
    /// straight to JSONDecoder yields "Praza de AmÃ©rica" at best.
    @Test("Decodes an ISO-8859-1 body when the header declares it")
    func latin1Body() throws {
        let latin1 = try #require(Fixture.liveArrivalsJSON.data(using: .isoLatin1))
        let snapshot = try ConcelloRealtimeClient.decode(
            latin1, stopCode: VitrasaStopCode(6930), fetchedAt: Date(),
            contentType: "application/json;charset=ISO-8859-1")
        #expect(snapshot.stopName == "Praza de América  1")
        #expect(snapshot.stopName?.contains("Ã") == false, "mojibake would mean the wrong encoding was used")
    }

    /// Latin-1 decoding can never fail — every byte is a valid character — so a source
    /// that switched to UTF-8 would silently produce mojibake forever. Sniffing prevents
    /// that from being a silent regression.
    @Test("Falls back to UTF-8 when no charset is declared")
    func utf8WithoutDeclaredCharset() throws {
        let snapshot = try ConcelloRealtimeClient.decode(
            Data(Fixture.liveArrivalsJSON.utf8),
            stopCode: VitrasaStopCode(6930), fetchedAt: Date())
        #expect(snapshot.stopName == "Praza de América  1")
    }

    @Test("Honours a declared UTF-8 charset")
    func declaredUTF8() throws {
        let snapshot = try ConcelloRealtimeClient.decode(
            Data(Fixture.liveArrivalsJSON.utf8),
            stopCode: VitrasaStopCode(6930), fetchedAt: Date(),
            contentType: "application/json; charset=utf-8")
        #expect(snapshot.stopName == "Praza de América  1")
    }

    @Test("Latin-1 bytes without a declared charset still decode")
    func latin1WithoutHeader() throws {
        let latin1 = try #require(Fixture.liveArrivalsJSON.data(using: .isoLatin1))
        let snapshot = try ConcelloRealtimeClient.decode(
            latin1, stopCode: VitrasaStopCode(6930), fetchedAt: Date())
        #expect(snapshot.stopName == "Praza de América  1")
    }

    /// An unknown stop comes back as HTTP 200 with empty arrays. Treating that as
    /// "no buses due" would hide the fact that the identifier was wrong.
    @Test("An empty parada array is reported as an unknown stop")
    func unknownStop() throws {
        #expect(throws: RealtimeError.self) {
            try ConcelloRealtimeClient.decode(
                Data(Fixture.unknownStopJSON.utf8),
                stopCode: VitrasaStopCode(999_999), fetchedAt: Date())
        }
    }

    @Test("A real stop with no buses due is not an error")
    func stopWithNoBuses() throws {
        let json = #"{"parada":[{"latitud":42.2,"longitud":-8.7,"stop_vitrasa":6930,"nombre":"X"}],"estimaciones":[]}"#
        let snapshot = try ConcelloRealtimeClient.decode(
            Data(json.utf8), stopCode: VitrasaStopCode(6930), fetchedAt: Date())
        #expect(snapshot.arrivals.isEmpty)
    }

    @Test("An upstream rejection is surfaced, not swallowed")
    func invalidTipo() throws {
        #expect(throws: RealtimeError.self) {
            try ConcelloRealtimeClient.decode(
                Data(Fixture.invalidTipoJSON.utf8),
                stopCode: VitrasaStopCode(6930), fetchedAt: Date())
        }
    }

    /// metros == -1 means no vehicle is being tracked, so the estimate cannot be
    /// presented as live. This drives the badge shown in the UI.
    @Test("Grades confidence from the reported distance")
    func confidenceGrading() {
        let untracked = Arrival(rawLine: "C1", destination: "PRAZA AMÉRICA*", minutes: 9, metres: -1)
        #expect(untracked.confidence == .operatorEstimate)
        #expect(!untracked.confidence.hasTrackedVehicle)

        let tracked = Arrival(rawLine: "C1", destination: "PRAZA AMÉRICA*", minutes: 3, metres: 850)
        #expect(tracked.confidence == .vehicleTracked(metres: 850))
        #expect(tracked.confidence.hasTrackedVehicle)

        let missing = Arrival(rawLine: "C1", destination: "X", minutes: 3, metres: nil)
        #expect(missing.confidence == .operatorEstimate)
    }

    @Test("Cleans the destination strings the API actually sends", arguments: [
        ("PRAZA AMÉRICA*", "PRAZA AMÉRICA"),
        ("XESTOSO *", "XESTOSO"),
        ("  COIA por CAMELIAS*", "COIA por CAMELIAS"),
        ("P. AMERICA - URZAIZ - G.ESPINO*", "P. AMERICA - URZAIZ - G.ESPINO"),
    ])
    func destinationCleaning(input: String, expected: String) {
        #expect(Arrival(rawLine: "X", destination: input, minutes: 1, metres: -1).destination == expected)
    }

    /// The API says "PSA" where the feed says "PSA1"/"PSA4", and the feed carries variant
    /// names ending in a dot. Matching has to survive both.
    @Test("Normalises line labels for matching", arguments: [
        ("C1", "C1"), ("11.", "11"), ("4A-", "4A"), ("PSA 1", "PSA1"), ("15b", "15B"),
    ])
    func lineNormalisation(input: String, expected: String) {
        #expect(TextNormalization.normalizedLineName(input) == expected)
    }

    @Test("Arrivals are ordered soonest first")
    func ordering() throws {
        let json = #"{"parada":[{"stop_vitrasa":1,"nombre":"X","latitud":0,"longitud":0}],"estimaciones":[{"minutos":50,"ruta":"B*","linea":"2","metros":-1},{"minutos":5,"ruta":"A*","linea":"1","metros":-1}]}"#
        let snapshot = try ConcelloRealtimeClient.decode(
            Data(json.utf8), stopCode: VitrasaStopCode(1), fetchedAt: Date())
        #expect(snapshot.arrivals.map(\.minutes) == [5, 50])
    }

    @Test("Garbage in the body fails loudly")
    func garbage() {
        #expect(throws: RealtimeError.self) {
            try ConcelloRealtimeClient.decode(
                Data("<html>502 Bad Gateway</html>".utf8),
                stopCode: VitrasaStopCode(6930), fetchedAt: Date())
        }
    }
}

/// Stubs standing in for the network so behaviour around failure can be tested.
struct StubRealtimeProvider: RealtimeArrivalsProviding {
    let result: @Sendable (VitrasaStopCode) async throws -> ArrivalsSnapshot
    func arrivals(for stopCode: VitrasaStopCode) async throws -> ArrivalsSnapshot {
        try await result(stopCode)
    }
}

actor CallCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

@Suite("Throttling")
struct ThrottleTests {

    /// These are unofficial endpoints run by a municipality. Repeated requests for the
    /// same stop inside the window must not reach the network.
    @Test("Reuses a recent answer instead of hitting the network again")
    func throttles() async throws {
        let counter = CallCounter()
        let stub = StubRealtimeProvider { code in
            await counter.increment()
            return ArrivalsSnapshot(stopCode: code, stopName: "X", latitude: nil,
                                    longitude: nil, arrivals: [], fetchedAt: Date())
        }
        let throttled = ThrottledRealtimeProvider(upstream: stub, minimumInterval: 60)
        for _ in 0 ..< 5 { _ = try await throttled.arrivals(for: VitrasaStopCode(6930)) }
        #expect(await counter.count == 1)
    }

    @Test("Different stops are throttled independently")
    func perStop() async throws {
        let counter = CallCounter()
        let stub = StubRealtimeProvider { code in
            await counter.increment()
            return ArrivalsSnapshot(stopCode: code, stopName: "X", latitude: nil,
                                    longitude: nil, arrivals: [], fetchedAt: Date())
        }
        let throttled = ThrottledRealtimeProvider(upstream: stub, minimumInterval: 60)
        _ = try await throttled.arrivals(for: VitrasaStopCode(6930))
        _ = try await throttled.arrivals(for: VitrasaStopCode(14264))
        #expect(await counter.count == 2)
    }

    @Test("An explicit refresh bypasses the throttle")
    func invalidate() async throws {
        let counter = CallCounter()
        let stub = StubRealtimeProvider { code in
            await counter.increment()
            return ArrivalsSnapshot(stopCode: code, stopName: "X", latitude: nil,
                                    longitude: nil, arrivals: [], fetchedAt: Date())
        }
        let throttled = ThrottledRealtimeProvider(upstream: stub, minimumInterval: 60)
        _ = try await throttled.arrivals(for: VitrasaStopCode(6930))
        await throttled.invalidate(VitrasaStopCode(6930))
        _ = try await throttled.arrivals(for: VitrasaStopCode(6930))
        #expect(await counter.count == 2)
    }
}
