import Foundation
import Testing
@testable import VigoCore

/// The stops layer's gating, checked without a map.
@Suite("Capa de paradas del mapa")
struct MapStopsLayerTests {

    /// A grid of `count` stops all within ~1 km of Praza de América, so any viewport built
    /// below either holds all of them or none.
    private func cluster(_ count: Int) -> [Stop] {
        (0..<count).map { PlannerFixture.stop("C\($0)", northMetres: Double($0 % 20) * 10,
                                              eastMetres: Double($0 / 20) * 10) }
    }

    private var wide: MapStopsLayer.Viewport {
        .init(centreLatitude: PlannerFixture.base.latitude,
              centreLongitude: PlannerFixture.base.longitude,
              latitudeSpan: 0.2, longitudeSpan: 0.2)
    }

    /// Somewhere with no stops at all — the Atlantic, west of the ría.
    private var emptyWater: MapStopsLayer.Viewport {
        .init(centreLatitude: 42.15, centreLongitude: -9.20,
              latitudeSpan: 0.02, longitudeSpan: 0.02)
    }

    @Test("Dentro del límite, devuelve las paradas del recuadro")
    func drawsWhatFits() {
        let content = MapStopsLayer.content(from: cluster(50), in: wide)
        #expect(content == .stops(cluster(50)))
        #expect(content.stops.count == 50)
    }

    @Test("Por encima del límite dice cuántas hay, no una lista vacía")
    func tooManyCarriesTheCount() {
        let content = MapStopsLayer.content(from: cluster(300), in: wide, limit: 220)
        #expect(content == .tooMany(count: 300))
        #expect(content.stops.isEmpty, "no se dibuja ninguna, pero el motivo se conserva")
    }

    /// El motivo por el que esto salió de la vista: antes las dos situaciones devolvían un
    /// array vacío y la vista adivinaba entre ellas con `visibleStops.isEmpty &&
    /// !allStops.isEmpty`, que enseña "acerca el mapa para ver las paradas" sobre mar
    /// abierto. Aquí son dos casos distintos y no se pueden confundir.
    @Test("Un recuadro sin paradas no es lo mismo que demasiadas paradas")
    func emptyIsNotTooMany() {
        let empty = MapStopsLayer.content(from: cluster(300), in: emptyWater)
        #expect(empty == .stops([]))
        #expect(empty != .tooMany(count: 0))
    }

    @Test("El límite es inclusivo: justo en el tope todavía se dibuja")
    func limitIsInclusive() {
        #expect(MapStopsLayer.content(from: cluster(220), in: wide, limit: 220).stops.count == 220)
        if case .tooMany = MapStopsLayer.content(from: cluster(221), in: wide, limit: 220) {} else {
            Issue.record("una más que el límite ya es demasiado")
        }
    }

    @Test("El recuadro recorta por latitud y por longitud")
    func viewportClips() {
        let inside = PlannerFixture.stop("in")
        let north = PlannerFixture.stop("north", northMetres: 20_000)
        let east = PlannerFixture.stop("east", eastMetres: 20_000)
        let narrow = MapStopsLayer.Viewport(
            centreLatitude: PlannerFixture.base.latitude,
            centreLongitude: PlannerFixture.base.longitude,
            latitudeSpan: 0.01, longitudeSpan: 0.01)

        let content = MapStopsLayer.content(from: [inside, north, east], in: narrow)
        #expect(content.stops == [inside])
    }

    /// El span es la anchura **total** del recuadro, así que el borde está a la mitad. Sin
    /// una parada entre media anchura y anchura entera, un error de factor 2 en el recorte no
    /// lo ve nadie: la primera versión de este fichero probaba con una parada a 20 km, que
    /// queda fuera con o sin el fallo.
    @Test("El borde está a media anchura del centro, no a una anchura entera")
    func edgeIsHalfTheSpan() {
        // 0,01° de span ⇒ borde a 0,005° ≈ 556 m del centro.
        let viewport = MapStopsLayer.Viewport(
            centreLatitude: PlannerFixture.base.latitude,
            centreLongitude: PlannerFixture.base.longitude,
            latitudeSpan: 0.01, longitudeSpan: 0.01)

        let inside = PlannerFixture.stop("in", northMetres: 500)
        let justOutsideNorth = PlannerFixture.stop("outN", northMetres: 600)
        let justOutsideEast = PlannerFixture.stop("outE", eastMetres: 600)

        let content = MapStopsLayer.content(
            from: [inside, justOutsideNorth, justOutsideEast], in: viewport)
        #expect(content.stops == [inside],
                "600 m cae fuera del borde de 556 m, pero dentro de una anchura entera")
    }

    @Test("Un span negativo se trata como su valor absoluto")
    func spansAreNormalised() {
        let flipped = MapStopsLayer.Viewport(
            centreLatitude: PlannerFixture.base.latitude,
            centreLongitude: PlannerFixture.base.longitude,
            latitudeSpan: -0.2, longitudeSpan: -0.2)
        #expect(MapStopsLayer.content(from: cluster(10), in: flipped).stops.count == 10)
    }

    @Test("Sin paradas cargadas todavía, no hay nada que dibujar ni de qué avisar")
    func noStopsAtAll() {
        #expect(MapStopsLayer.content(from: [], in: wide) == .stops([]))
    }
}
