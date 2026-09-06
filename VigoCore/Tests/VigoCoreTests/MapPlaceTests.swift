import Testing
import Foundation
@testable import VigoCore

@Suite("MapPlace")
struct MapPlaceTests {
    private static let stop = Stop(
        id: StopID("3493"), gtfsStopCode: "P006930", vitrasaCode: VitrasaStopCode(6930),
        name: "Praza de América  1", searchName: "praza de america 1",
        latitude: 42.2209973130163, longitude: -8.73283517659561, wheelchairBoarding: 1)

    /// H-38: a saved-journey endpoint anchored to a stop, but not live-linked to a saved
    /// place, used to fall all the way back to `.address` — losing the stop entirely.
    @Test("A stop-anchored endpoint without a live link is still a stop, not an address")
    func stopAnchoredEndpointKeepsItsStop() {
        let endpoint = SavedEndpoint(
            placeID: nil, name: "Casa", symbolName: "house.fill", anchor: .stop(Self.stop))
        let place = MapPlace.savedEndpoint(endpoint)

        #expect(place.stop == Self.stop)
        #expect(place.symbolName == "bus.fill")
        // The saved name still wins over the stop's own name — that is the whole point of
        // having saved it, and `SavedEndpoint.place` already guarantees `.coordinate`.
        #expect(place.label == "Casa")
    }

    /// `.orphanedStop` carries no `Stop` value at all — just an id and a fallback coordinate
    /// — so `MapPlace.Origin.stop(Stop)` cannot represent it either; falling back to
    /// `.droppedPin` (a usable coordinate, no arrivals or favourite star) is the honest
    /// result, not a regression the way falling back to `.address` was for a live stop.
    @Test("An orphaned stop anchor falls back to a dropped pin, not an address")
    func orphanedStopAnchorFallsBackToDroppedPin() {
        let endpoint = SavedEndpoint(
            placeID: nil, name: "Casa", symbolName: "house.fill",
            anchor: .orphanedStop(StopID("gone"), fallback: Coordinate(latitude: 1, longitude: 2)))
        let place = MapPlace.savedEndpoint(endpoint)

        #expect(place.stop == nil, "orphaned: no live Stop to hand the caller")
        if case .droppedPin = place.origin {} else { Issue.record("expected .droppedPin, got \(place.origin)") }
    }

    @Test("A coordinate-anchored endpoint without a live link falls back to a dropped pin")
    func coordinateAnchoredEndpointFallsBackToDroppedPin() {
        let endpoint = SavedEndpoint(
            placeID: nil, name: "Oficina de un cliente", symbolName: "mappin",
            anchor: .coordinate(Coordinate(latitude: 42.2, longitude: -8.7)))
        let place = MapPlace.savedEndpoint(endpoint)

        #expect(place.stop == nil)
        #expect(place.symbolName == "mappin")
        if case .droppedPin = place.origin {} else { Issue.record("expected .droppedPin, got \(place.origin)") }
    }

    @Test("A live-linked endpoint is a saved place regardless of its anchor")
    func liveLinkedEndpointIsASavedPlace() {
        let endpoint = SavedEndpoint(
            placeID: SavedPlaceID("p1"), name: "Casa", symbolName: "house.fill", anchor: .stop(Self.stop))
        let place = MapPlace.savedEndpoint(endpoint)

        if case .savedPlace(let id) = place.origin {
            #expect(id == SavedPlaceID("p1"))
        } else {
            Issue.record("expected .savedPlace, got \(place.origin)")
        }
        #expect(place.symbolName == "bookmark.fill")
    }

    /// H-48: the rounding `MapSearchSheet` throttles "Cerca de ti" with, and the one
    /// `PLAN-FASES-8-13.md` §12.3 specifies for the Fase 12 `dedupKey` — one function, so the
    /// two cannot quietly drift to different thresholds.
    @Test("Coordinate rounding: same after rounding within ~11 m, different beyond it")
    func coordinateRoundingCollapsesJitterNotRealMovement() {
        let base = Coordinate(latitude: 42.22099, longitude: -8.73283)
        let jitter = Coordinate(latitude: 42.220991, longitude: -8.732831)
        #expect(base.rounded(toDecimals: 4) == jitter.rounded(toDecimals: 4))

        let realMove = Coordinate(latitude: 42.22110, longitude: -8.73283)
        #expect(base.rounded(toDecimals: 4) != realMove.rounded(toDecimals: 4))
    }
}
