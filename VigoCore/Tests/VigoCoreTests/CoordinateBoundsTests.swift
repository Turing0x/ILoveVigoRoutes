import Foundation
import Testing
@testable import VigoCore

/// El encuadre del mapa, sin mapa.
@Suite("Encuadre de coordenadas")
struct CoordinateBoundsTests {

    private func c(_ latitude: Double, _ longitude: Double) -> Coordinate {
        Coordinate(latitude: latitude, longitude: longitude)
    }

    @Test("Rodea todos los puntos, no solo el primero y el último")
    func boundsCoverEverything() throws {
        // El primer punto no es extremo en ningún eje, y cada uno de los cuatro extremos
        // llega más tarde y desde un punto distinto. Sin eso, olvidarse de actualizar (por
        // ejemplo) el mínimo de latitud no lo nota nadie: el primero ya era el mínimo.
        let bounds = try #require(CoordinateBounds([
            c(42.25, -8.75),   // primero: en medio de los dos rangos
            c(42.30, -8.79),   // máximo de latitud
            c(42.20, -8.72),   // mínimo de latitud
            c(42.26, -8.80),   // mínimo de longitud
            c(42.24, -8.70)    // máximo de longitud
        ]))
        #expect(bounds.minLatitude == 42.20)
        #expect(bounds.maxLatitude == 42.30)
        #expect(bounds.minLongitude == -8.80)
        #expect(bounds.maxLongitude == -8.70)
    }

    @Test("Sin puntos no hay recuadro")
    func emptyHasNoBounds() {
        #expect(CoordinateBounds([]) == nil)
        #expect(CoordinateBounds.union([nil, nil]) == nil)
    }

    @Test("El centro es el centro del recuadro, no la media de los puntos")
    func centreIsTheBoxCentre() throws {
        // Tres puntos apiñados al sur y uno al norte: la media aritmética caería mucho más
        // abajo que el centro del recuadro, y encuadrar por ella deja el norte fuera.
        let bounds = try #require(CoordinateBounds([
            c(42.20, -8.70), c(42.21, -8.70), c(42.22, -8.70), c(42.40, -8.70)]))
        #expect(bounds.centre.latitude == 42.30)
    }

    @Test("La unión de varias alternativas las contiene a todas")
    func unionHoldsEveryAlternative() throws {
        let west = try #require(CoordinateBounds([c(42.22, -8.80), c(42.24, -8.78)]))
        let east = try #require(CoordinateBounds([c(42.20, -8.70), c(42.26, -8.68)]))
        let both = try #require(CoordinateBounds.union([west, east, nil]))

        #expect(both.minLatitude == 42.20)
        #expect(both.maxLatitude == 42.26)
        #expect(both.minLongitude == -8.80)
        #expect(both.maxLongitude == -8.68)
        #expect(both == west.union(east), "la unión no depende del orden ni de los nils")
    }

    @Test("El margen amplía el recuadro y el suelo evita el zoom sobre la acera")
    func paddingAndFloor() throws {
        let wide = try #require(CoordinateBounds([c(42.20, -8.80), c(42.30, -8.70)]))
        let padded = wide.paddedSpans(factor: 1.4, minimum: 0.005)
        #expect(abs(padded.latitude - 0.14) < 1e-9, "0,10° por 1,4")
        #expect(abs(padded.longitude - 0.14) < 1e-9)

        // Un solo punto tiene span cero: sin suelo, la cámara se metería dentro del asfalto.
        let single = try #require(CoordinateBounds([c(42.23, -8.72)]))
        #expect(single.latitudeSpan == 0)
        let floored = single.paddedSpans(factor: 1.4, minimum: 0.005)
        #expect(floored.latitude == 0.005)
        #expect(floored.longitude == 0.005)
    }

    @Test("Unos límites al revés se enderezan solos")
    func boundsNormalise() {
        let flipped = CoordinateBounds(minLatitude: 42.30, maxLatitude: 42.20,
                                       minLongitude: -8.70, maxLongitude: -8.80)
        #expect(flipped.minLatitude == 42.20)
        #expect(flipped.maxLongitude == -8.70)
        #expect(flipped.latitudeSpan > 0)
    }

    /// Un trayecto tiene que poder encuadrarse aunque su viaje no traiga `shape_id`, cosa que
    /// el GTFS permite: las paradas y los extremos a pie bastan.
    @Test("Un trayecto nombra sus propias coordenadas sin el trazado")
    func journeyNamesItsOwnCoordinates() {
        let origin = Place.coordinate(c(42.20, -8.75), label: "Origen")
        let board = PlannerFixture.stop("A")
        let alight = PlannerFixture.stop("B", northMetres: 2_000)
        let destination = Place.coordinate(c(42.28, -8.70), label: "Destino")
        let now = Date(timeIntervalSince1970: 1_757_000_000)

        let journey = Journey(legs: [
            .walk(from: origin, to: .stop(board), seconds: 300, metres: 300),
            .ride(routeID: RouteID("L1"), routeShortName: "1", headsign: nil,
                  tripID: TripID("t1"), board: board, alight: alight,
                  departure: now, arrival: now.addingTimeInterval(600), intermediateStops: []),
            .walk(from: .stop(alight), to: destination, seconds: 240, metres: 250)
        ], departure: now, arrival: now.addingTimeInterval(1_140), transfers: 0)

        let coordinates = journey.keyCoordinates
        #expect(coordinates.count == 6, "dos por tramo: origen y destino de cada uno")
        let bounds = CoordinateBounds(coordinates)
        #expect(bounds?.minLatitude == 42.20)
        #expect(bounds?.maxLatitude == 42.28)
    }
}
