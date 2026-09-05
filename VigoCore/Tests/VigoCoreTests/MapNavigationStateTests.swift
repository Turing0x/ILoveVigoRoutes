import Foundation
import Testing
@testable import VigoCore

/// The map flow's state machine, exercised without a map.
///
/// This is the whole point of `MapNavigationState` being a value type in this package: every
/// transition the screen can make is checked here by `swift test` on the Mac, with no
/// simulator and no device involved. What is left for a device to answer is drawing and
/// gestures, not logic.
@Suite("Flujo del mapa")
struct MapNavigationStateTests {

    private let here = Coordinate(latitude: 42.2328, longitude: -8.7226)
    private let there = Coordinate(latitude: 42.2400, longitude: -8.7100)
    private let clock = Date(timeIntervalSince1970: 1_757_000_000)

    private func stopPlace(_ id: String = "1001") -> MapPlace {
        .stop(PlannerFixture.stop(id, name: "Praza de América"))
    }

    private func poi(_ name: String) -> MapPlace {
        MapPlace(place: .coordinate(there, label: name), subtitle: "Tienda",
                 origin: .pointOfInterest)
    }

    /// A journey with a fixed shape; only its times and identity matter here.
    private func journey(departureOffset: TimeInterval, arrivalOffset: TimeInterval,
                        transfers: Int = 0) -> Journey {
        let from = MapPlace.currentLocation(here).place
        let to = poi("Destino").place
        return Journey(
            legs: [.walk(from: from, to: to, seconds: Int(arrivalOffset - departureOffset),
                         metres: 500)],
            departure: clock.addingTimeInterval(departureOffset),
            arrival: clock.addingTimeInterval(arrivalOffset),
            transfers: transfers)
    }

    // MARK: - Estado inicial

    @Test("Arranca en el mapa limpio, sin ruta y siguiendo al GPS")
    func initialState() {
        let state = MapNavigationState()
        #expect(state.mode == .browsing)
        #expect(state.selectedPlace == nil)
        #expect(state.origin == nil)
        #expect(state.destination == nil)
        #expect(state.originFollowsLocation)
        #expect(state.route.journeys.isEmpty)
        #expect(state.routeQuery(now: clock) == nil)
    }

    // MARK: - Selección

    @Test("Seleccionar cualquier origen de lugar abre su ficha")
    func selectingShowsCard() {
        var state = MapNavigationState()

        state.select(stopPlace())
        #expect(state.selectedPlace?.stop != nil)
        #expect(state.selectedPlace?.subtitle == "Parada 1001")

        // Un POI de Apple entra por la misma puerta que una parada: es lo que sostiene
        // "cualquier lugar disponible" sin casos especiales.
        state.select(poi("El Corte Inglés"))
        #expect(state.selectedPlace?.stop == nil)
        #expect(state.selectedPlace?.label == "El Corte Inglés")
    }

    /// El hallazgo nº 1 de la sonda en dispositivo: al deseleccionar, MapKit deja un
    /// `MapSelection` **no nulo** con `value` y `feature` a `nil`. La vista traduce eso a
    /// `clearSelection()`, y esto comprueba que cerrar la ficha no se lleva por delante una
    /// ruta ya calculada.
    @Test("Deseleccionar cierra la ficha pero no cancela una ruta en curso")
    func clearingSelectionKeepsRoute() {
        var state = MapNavigationState()
        state.updateCurrentLocation(here)
        state.select(poi("Destino"))
        let started = state.routeToSelectedPlace()
        #expect(started)
        state.planningFinished(.journeys([journey(departureOffset: 0, arrivalOffset: 600)]))

        state.clearSelection()

        // Estaba en `.routing`, no en `.place`: deseleccionar un pin no toca nada.
        #expect(state.mode == .routing)
        #expect(state.route.journeys.count == 1)

        state.dismiss()
        #expect(state.mode == .place(state.destination!))
        state.clearSelection()
        #expect(state.mode == .browsing)
    }

    // MARK: - Origen automático

    @Test("El GPS mantiene el origen hasta que el usuario elige uno")
    func gpsOwnsOriginUntilTouched() {
        var state = MapNavigationState()
        state.updateCurrentLocation(here)
        #expect(state.origin?.coordinate == here)
        #expect(state.origin?.isCurrentLocation == true)

        state.updateCurrentLocation(there)
        #expect(state.origin?.coordinate == there)

        state.setOrigin(stopPlace())
        #expect(!state.originFollowsLocation)
        state.updateCurrentLocation(here)
        #expect(state.origin?.stop != nil, "un fix posterior no puede pisar un origen elegido")
        #expect(state.currentLocation == here, "pero la posición sí se sigue anotando")

        state.followCurrentLocation()
        #expect(state.originFollowsLocation)
        #expect(state.origin?.coordinate == here)
    }

    @Test("Intercambiar extremos apaga el seguimiento del GPS")
    func swapStopsFollowing() {
        var state = MapNavigationState()
        state.updateCurrentLocation(here)
        state.select(poi("Destino"))
        let started = state.routeToSelectedPlace()
        #expect(started)

        state.swapEnds()
        #expect(state.origin?.label == "Destino")
        #expect(state.destination?.isCurrentLocation == true)
        #expect(!state.originFollowsLocation)

        // Sin esto, el siguiente fix del GPS deshace el intercambio en silencio.
        state.updateCurrentLocation(there)
        #expect(state.origin?.label == "Destino")
    }

    @Test("Sin posición conocida no se puede arrancar una ruta con origen automático")
    func routingNeedsAnOrigin() {
        var state = MapNavigationState()
        state.select(poi("Destino"))
        let withoutOrigin = state.routeToSelectedPlace()
        #expect(!withoutOrigin)
        #expect(state.mode == .place(state.selectedPlace!))

        // Con un origen puesto a mano sí, aunque nunca haya habido GPS.
        state.setOrigin(stopPlace())
        let withOrigin = state.routeToSelectedPlace()
        #expect(withOrigin)
        #expect(state.mode == .routing)
    }

    @Test("Sin lugar seleccionado, pedir ruta no hace nada")
    func routingNeedsADestination() {
        var state = MapNavigationState()
        state.updateCurrentLocation(here)
        let started = state.routeToSelectedPlace()
        #expect(!started)
        #expect(state.mode == .browsing)
    }

    // MARK: - Consulta

    @Test("La consulta sale de los dos extremos y del modo de salida")
    func queryReflectsState() throws {
        var state = MapNavigationState()
        state.updateCurrentLocation(here)
        state.select(poi("Destino"))
        state.routeToSelectedPlace()

        let immediate = try #require(state.routeQuery(now: clock))
        #expect(immediate.departure == clock)
        #expect(immediate.origin.coordinate == here)
        #expect(immediate.destination.coordinate == there)

        let later = clock.addingTimeInterval(3_600)
        state.departure = .at(later)
        #expect(state.routeQuery(now: clock)?.departure == later)
    }

    // MARK: - Resultados

    @Test("Cada PlanOutcome aterriza en la forma que la lista sabe dibujar")
    func outcomesFold() {
        var state = MapNavigationState()
        state.planningStarted()
        #expect(state.route.isPlanning)

        state.planningFinished(.journeys([journey(departureOffset: 0, arrivalOffset: 600),
                                          journey(departureOffset: 300, arrivalOffset: 900)]))
        #expect(state.route.journeys.count == 2)
        #expect(!state.route.isWalkOnly)

        state.planningFinished(.walkOnly(journey(departureOffset: 0, arrivalOffset: 400)))
        #expect(state.route.journeys.count == 1)
        #expect(state.route.isWalkOnly, "caminar es una alternativa, pero hay que poder decir que lo es")

        state.planningFinished(.noServiceOnDay(ServiceDate(yyyymmdd: 20_260_905)))
        #expect(state.route.journeys.isEmpty)
        if case .noServiceOnDay = state.route.failure {} else {
            Issue.record("el motivo del fallo tiene que sobrevivir intacto hasta la vista")
        }
    }

    /// `.journeys([])` es un éxito vacío que no existe en la práctica, pero si llegara, una
    /// lista vacía en pantalla sería mentira: no es que haya opciones y no quepan, es que no
    /// hay ninguna.
    @Test("Una lista vacía de alternativas no se dibuja como éxito")
    func emptyJourneyListIsAFailure() {
        var state = MapNavigationState()
        state.planningFinished(.journeys([]))
        #expect(state.route.journeys.isEmpty)
        #expect(state.route.failure != nil)
    }

    @Test("Editar un extremo tira el resultado anterior")
    func editingEndsInvalidatesResult() {
        var state = MapNavigationState()
        state.updateCurrentLocation(here)
        state.select(poi("Destino"))
        state.routeToSelectedPlace()
        state.planningFinished(.journeys([journey(departureOffset: 0, arrivalOffset: 600)]))
        let opened = state.openSelectedAlternative()
        #expect(opened)
        #expect(state.mode == .journeyDetail)

        state.setDestination(stopPlace())

        // Si el resultado sobreviviera, el mapa seguiría pintando el trazado viejo bajo unos
        // extremos nuevos — y el detalle abierto sería el de una ruta que ya nadie pidió.
        #expect(state.route.journeys.isEmpty)
        #expect(state.mode == .routing)
    }

    @Test("La alternativa destacada siempre es un índice válido")
    func alternativeSelectionStaysValid() {
        var state = MapNavigationState()
        state.planningFinished(.journeys([journey(departureOffset: 0, arrivalOffset: 600),
                                          journey(departureOffset: 300, arrivalOffset: 900)]))
        #expect(state.selectedAlternative == 0)

        state.selectAlternative(at: 1)
        #expect(state.currentJourney == state.route.journeys[1])

        state.selectAlternative(at: 7)
        #expect(state.selectedAlternative == 1, "un índice fuera de rango se ignora, no rompe")

        state.planningFinished(.journeys([journey(departureOffset: 0, arrivalOffset: 600)]))
        #expect(state.selectedAlternative == 0, "un resultado nuevo no puede dejar el índice colgando")
    }

    @Test("No se abre el detalle de una alternativa que no existe")
    func cannotOpenMissingAlternative() {
        var state = MapNavigationState()
        let opened = state.openSelectedAlternative()
        #expect(!opened)
        #expect(state.mode == .browsing)
    }

    // MARK: - Volver atrás

    /// La tabla completa. Es el test que impide que "atrás" se convierta en tres respuestas
    /// distintas repartidas por los gestos de la hoja.
    @Test("`dismiss` recorre exactamente un nivel, desde cualquier modo")
    func dismissTable() {
        var state = MapNavigationState()
        state.updateCurrentLocation(here)
        let destination = poi("Destino")
        state.select(destination)
        state.routeToSelectedPlace()
        state.planningFinished(.journeys([journey(departureOffset: 0, arrivalOffset: 600)]))
        state.openSelectedAlternative()

        #expect(state.mode == .journeyDetail)
        state.dismiss()
        #expect(state.mode == .routing, "del detalle se vuelve a las alternativas, no al mapa")
        state.dismiss()
        #expect(state.mode == .place(destination), "y de las alternativas, a la ficha del destino")
        state.dismiss()
        #expect(state.mode == .browsing)
        state.dismiss()
        #expect(state.mode == .browsing, "el mapa limpio es el suelo")

        state.beginSearch()
        state.dismiss()
        #expect(state.mode == .browsing)
    }

    @Test("Volver desde una ruta sin destino cae al mapa limpio")
    func dismissFromRoutingWithoutDestination() {
        var state = MapNavigationState()
        state.updateCurrentLocation(here)
        state.select(poi("Destino"))
        state.routeToSelectedPlace()
        state.reset()
        #expect(state.mode == .browsing)
        #expect(state.destination == nil)
    }

    @Test("Cancelar la búsqueda solo actúa si se estaba buscando")
    func cancelSearchIsScoped() {
        var state = MapNavigationState()
        let place = stopPlace()
        state.select(place)
        state.cancelSearch()
        #expect(state.mode == .place(place), "cancelar una búsqueda que no existe no cierra la ficha")

        state.beginSearch()
        state.cancelSearch()
        #expect(state.mode == .browsing)
    }

    // MARK: - MapPlace

    @Test("MapPlace conserva la procedencia que decide las acciones de la ficha")
    func mapPlaceProvenance() {
        let stop = MapPlace.stop(PlannerFixture.stop("6930"))
        #expect(stop.stop != nil)
        #expect(stop.symbolName == "bus.fill")
        #expect(stop.subtitle == "Parada 6930")

        let mine = MapPlace.currentLocation(here)
        #expect(mine.isCurrentLocation)
        #expect(mine.label == MapPlace.currentLocationLabel)
        #expect(mine.stop == nil)

        // Sin red no hay calle, y eso no es un error: el punto sigue siendo planificable.
        let blind = MapPlace.droppedPin(there)
        #expect(blind.label == MapPlace.droppedPinLabel)
        #expect(blind.coordinate == there)
        let named = MapPlace.droppedPin(there, name: "Rúa do Areal, 12")
        #expect(named.label == "Rúa do Areal, 12")
    }
}

/// Trayectos guardados llevados al mapa.
@Suite("Trayectos guardados en el mapa")
struct SavedJourneyOnMapTests {

    private let here = Coordinate(latitude: 42.2328, longitude: -8.7226)

    private func endpoint(name: String, anchor: SavedPlaceAnchor,
                          placeID: SavedPlaceID? = nil) -> SavedEndpoint {
        SavedEndpoint(placeID: placeID, name: name, symbolName: "house.fill", anchor: anchor)
    }

    @Test("Un extremo guardado conserva su nombre, no el de la parada")
    func savedNameWins() {
        let stop = PlannerFixture.stop("6930", name: "Rúa do Areal")
        let place = MapPlace.savedEndpoint(
            endpoint(name: "Casa", anchor: .stop(stop), placeID: SavedPlaceID("p1")))

        #expect(place.label == "Casa", "guardarlo con un nombre propio es el motivo de guardarlo")
        #expect(place.subtitle == "Rúa do Areal", "pero sin ocultar a qué parada se refiere")
        #expect(place.origin == .savedPlace(SavedPlaceID("p1")))
    }

    /// El feed se reimporta entero cada semana y puede llevarse una parada por delante. Un
    /// trayecto guardado no puede quedarse inservible por eso: el ancla guarda coordenada de
    /// respaldo justo para esto, y al planificador le basta una coordenada.
    @Test("Un extremo cuya parada desapareció sigue siendo planificable")
    func orphanedEndpointStillWorks() {
        let place = MapPlace.savedEndpoint(endpoint(
            name: "Trabajo",
            anchor: .orphanedStop(StopID("se fue"), fallback: here)))

        #expect(place.coordinate == here)
        #expect(place.subtitle == nil, "no hay parada viva de la que dar el nombre")
        #expect(place.label == "Trabajo")
    }

    @Test("Un extremo suelto, sin lugar guardado detrás, no finge estarlo")
    func adHocEndpointIsNotLinked() {
        let place = MapPlace.savedEndpoint(endpoint(name: "Otro sitio", anchor: .coordinate(here)))
        #expect(place.origin == .address)
        #expect(place.stop == nil)
    }

    @Test("Tocar un trayecto guardado pone los dos extremos y deja de seguir al GPS")
    func routingBothEndsStopsFollowingLocation() {
        var state = MapNavigationState()
        state.updateCurrentLocation(here)
        #expect(state.originFollowsLocation)

        let journey = SavedJourney(
            id: SavedJourneyID("j1"), customLabel: "Al trabajo",
            origin: endpoint(name: "Casa", anchor: .coordinate(here)),
            destination: endpoint(name: "Trabajo",
                                  anchor: .coordinate(Coordinate(latitude: 42.24, longitude: -8.71))),
            createdAt: Date(timeIntervalSince1970: 1_757_000_000), sortIndex: 0)
        let ends = journey.mapEnds
        state.route(from: ends.origin, to: ends.destination)

        #expect(state.mode == .routing)
        #expect(state.origin?.label == "Casa")
        #expect(state.destination?.label == "Trabajo")
        // Los dos extremos los eligió el usuario al guardarlos; un fix posterior no puede
        // sustituir el origen por "Mi ubicación" y convertir el trayecto en otro distinto.
        #expect(!state.originFollowsLocation)
        state.updateCurrentLocation(Coordinate(latitude: 42.30, longitude: -8.60))
        #expect(state.origin?.label == "Casa")
    }
}

/// Guardar como trayecto lo que hay en la hoja de ruta.
@Suite("Extremos de un trayecto por guardar")
struct SavedEndpointInputFromMapPlaceTests {

    private let here = Coordinate(latitude: 42.2328, longitude: -8.7226)

    /// El importador borra y reescribe la tabla `stop` entera cada semana, así que guardar el
    /// `Stop` sería guardar algo que caduca. Se guarda el id y una coordenada de respaldo.
    @Test("Una parada se guarda por su id, con coordenada de respaldo")
    func stopIsStoredByID() {
        let stop = PlannerFixture.stop("6930", name: "Rúa do Areal")
        let input = MapPlace.stop(stop).savedEndpointInput

        #expect(input.placeID == nil, "una parada suelta no está enlazada a ningún lugar guardado")
        #expect(input.name == "Rúa do Areal")
        if case .stopID(let id, let fallback) = input.anchor {
            #expect(id == stop.id)
            #expect(fallback == Coordinate(stop), "sin esto, un feed nuevo dejaría el trayecto inservible")
        } else {
            Issue.record("una parada tiene que anclarse por id, no por coordenada")
        }
    }

    /// Enlazado, no copiado: renombrar "Casa" más tarde tiene que renombrarlo también aquí.
    @Test("Un lugar guardado se queda enlazado")
    func savedPlaceStaysLinked() {
        let id = SavedPlaceID("p1")
        let place = MapPlace(place: .coordinate(here, label: "Casa"),
                             subtitle: nil, origin: .savedPlace(id))
        #expect(place.savedEndpointInput.placeID == id)
        #expect(place.savedEndpointInput.name == "Casa")
    }

    @Test("Una dirección o un punto suelto son extremos ad hoc")
    func adHocEndpointsAreNotLinked() {
        for origin in [MapPlace.Origin.address, .droppedPin, .pointOfInterest, .currentLocation] {
            let place = MapPlace(place: .coordinate(here, label: "X"), subtitle: nil, origin: origin)
            #expect(place.savedEndpointInput.placeID == nil,
                    "no hay lugar guardado al que enlazarse")
            if case .coordinate = place.savedEndpointInput.anchor {} else {
                Issue.record("sin parada detrás, el ancla es la coordenada")
            }
        }
    }
}
