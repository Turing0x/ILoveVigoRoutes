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

    @Test("«Ir a… desde esta parada»: la parada es el origen, el destino queda por elegir")
    func routeFromSelectedStop() {
        var state = MapNavigationState()
        let withoutCard = state.routeFromSelectedPlace()
        #expect(!withoutCard, "sin ficha abierta no hay origen que fijar")

        state.updateCurrentLocation(here)
        state.setDestination(poi("Antes"))
        state.select(stopPlace())
        let started = state.routeFromSelectedPlace()
        #expect(started)
        #expect(state.mode == .routing)
        #expect(state.origin == stopPlace())
        #expect(state.destination == nil)
        #expect(!state.originFollowsLocation)
        #expect(state.routeQuery(now: clock) == nil)

        state.updateCurrentLocation(there)
        #expect(state.origin == stopPlace(), "un fix del GPS no pisa la parada")

        state.setDestination(poi("Destino"))
        #expect(state.routeQuery(now: clock)?.origin == stopPlace().place)

        var empty = state
        empty.reset()
        empty.select(stopPlace())
        empty.routeFromSelectedPlace()
        empty.dismiss()
        #expect(empty.mode == .browsing, "sin destino, volver atrás es el mapa limpio")
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
        // `.droppedPin`, no `.address` (H-38 corrigió el `.address` fijo de antes): no hay
        // forma de saber si esta coordenada vino de una dirección o de un pin, y `.droppedPin`
        // no finge saberlo más de lo que ya fingía `.address`.
        #expect(place.origin == .droppedPin)
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

/// El modo seguimiento, que existe para encender tres cosas caras —cámara con rumbo, pantalla
/// despierta y GPS fino— y que por tanto tiene que apagarse solo en cuanto deja de tener
/// sentido.
@Suite("Seguimiento en el mapa")
struct MapFollowingTests {

    private let here = Coordinate(latitude: 42.2328, longitude: -8.7226)
    private let there = Coordinate(latitude: 42.2400, longitude: -8.7100)
    private let clock = Date(timeIntervalSince1970: 1_757_000_000)

    private func poi(_ name: String) -> MapPlace {
        MapPlace(place: .coordinate(there, label: name), subtitle: nil, origin: .pointOfInterest)
    }

    private func journey(_ offset: TimeInterval) -> Journey {
        Journey(legs: [.walk(from: MapPlace.currentLocation(here).place,
                             to: poi("Destino").place, seconds: 600, metres: 700)],
                departure: clock.addingTimeInterval(offset),
                arrival: clock.addingTimeInterval(offset + 600), transfers: 0)
    }

    /// Estado con una ruta calculada y el detalle abierto: el único sitio desde el que se
    /// puede empezar a seguir.
    private func openedJourney(alternatives: Int = 1) -> MapNavigationState {
        var state = MapNavigationState()
        state.updateCurrentLocation(here)
        state.select(poi("Destino"))
        state.route(to: poi("Destino"))
        state.planningFinished(.journeys((0..<alternatives).map { journey(Double($0) * 300) }))
        state.openSelectedAlternative()
        return state
    }

    @Test("No se puede seguir un trayecto que no está abierto")
    func followingNeedsAnOpenJourney() {
        var browsing = MapNavigationState()
        let fromBrowsing = browsing.startFollowing()
        #expect(!fromBrowsing)
        #expect(!browsing.isFollowing)

        // Con alternativas a la vista pero sin abrir ninguna, tampoco.
        var listed = openedJourney()
        listed.dismiss()
        #expect(listed.mode == .routing)
        let fromList = listed.startFollowing()
        #expect(!fromList)
        #expect(!listed.isFollowing)
    }

    @Test("Desde el detalle sí se puede")
    func followingStartsFromTheDetail() {
        var state = openedJourney()
        let started = state.startFollowing()
        #expect(started)
        #expect(state.isFollowing)

        state.stopFollowing()
        #expect(!state.isFollowing)
    }

    /// Quien toca "atrás" con la cámara persiguiéndole quiere que deje de perseguirle, no
    /// cerrar el trayecto. Es un nivel propio, por encima de la lista de tramos.
    @Test("`dismiss` sale primero del seguimiento y no del nivel")
    func dismissLeavesFollowingFirst() {
        var state = openedJourney()
        state.startFollowing()

        state.dismiss()
        #expect(!state.isFollowing)
        #expect(state.mode == .journeyDetail, "el trayecto sigue abierto")

        state.dismiss()
        #expect(state.mode == .routing, "y ahora sí se retrocede")
    }

    @Test("Destacar otra alternativa deja de seguir la anterior")
    func changingAlternativeStopsFollowing() {
        var state = openedJourney(alternatives: 2)
        state.startFollowing()

        state.selectAlternative(at: 1)
        #expect(!state.isFollowing, "seguir apuntaba a un trayecto que ya no es el elegido")
    }

    @Test("Volver a destacar la misma alternativa no interrumpe el seguimiento")
    func reselectingTheSameAlternativeKeepsFollowing() {
        var state = openedJourney(alternatives: 2)
        state.startFollowing()
        state.selectAlternative(at: state.selectedAlternative)
        #expect(state.isFollowing)
    }

    @Test("Editar un extremo apaga el seguimiento")
    func editingEndsStopsFollowing() {
        var state = openedJourney()
        state.startFollowing()
        state.setDestination(poi("Otro"))
        #expect(!state.isFollowing, "lo que se seguía ya no existe como respuesta")
        #expect(state.mode == .routing)
    }

    @Test("Replanificar apaga el seguimiento")
    func replanningStopsFollowing() {
        var state = openedJourney()
        state.startFollowing()
        state.planningStarted()
        #expect(!state.isFollowing)
    }

    @Test("Cerrar la hoja apaga el seguimiento")
    func resetStopsFollowing() {
        var state = openedJourney()
        state.startFollowing()
        state.reset()
        #expect(!state.isFollowing)
        #expect(state.mode == .browsing)
    }
}

/// El criterio de ordenación, dentro del flujo del mapa.
///
/// Vive aquí y no en `JourneyOrderingTests` porque lo que se prueba no es el orden —eso ya
/// está probado allí— sino lo que el cambio de criterio le hace al resto del estado.
@Suite("Orden de alternativas en el mapa")
struct MapOrderingTests {

    private let clock = Date(timeIntervalSince1970: 1_757_000_000)
    private let here = Coordinate(latitude: 42.2328, longitude: -8.7226)
    private let there = Coordinate(latitude: 42.2400, longitude: -8.7100)

    /// Un trayecto en autobús con la caminata final que se le pida.
    private func journey(board: Double, arrive: Double, egress: Int, line: String) -> Journey {
        let a = PlannerFixture.stop("A\(line)")
        let b = PlannerFixture.stop("B\(line)", northMetres: 1_000)
        return Journey(legs: [
            .walk(from: .coordinate(here, label: "O"), to: .stop(a), seconds: 120, metres: 150),
            .ride(routeID: RouteID("r\(line)"), routeShortName: line, headsign: nil,
                  tripID: TripID("t\(line)"), board: a, alight: b,
                  departure: clock.addingTimeInterval(board * 60),
                  arrival: clock.addingTimeInterval(arrive * 60 - Double(egress)),
                  intermediateStops: []),
            .walk(from: .stop(b), to: .coordinate(there, label: "D"),
                  seconds: egress, metres: Double(egress))
        ], departure: clock.addingTimeInterval(board * 60 - 120),
           arrival: clock.addingTimeInterval(arrive * 60), transfers: 0)
    }

    private func planned(_ journeys: [Journey]) -> MapNavigationState {
        var state = MapNavigationState()
        state.select(MapPlace(place: .coordinate(there, label: "Destino"), subtitle: nil,
                              origin: .droppedPin))
        state.updateCurrentLocation(here)
        _ = state.routeToSelectedPlace()
        state.planningStarted()
        state.planningFinished(.journeys(journeys))
        return state
    }

    @Test("Por defecto se ordena por la caminata final")
    func defaultIsLeastWalk() throws {
        let rapido = journey(board: 2, arrive: 20, egress: 900, line: "R")
        let cercano = journey(board: 5, arrive: 26, egress: 60, line: "C")
        let state = planned([rapido, cercano])

        #expect(state.ordering == .leastWalkAtEnd)
        #expect(state.visibleJourneys.first == cercano)
        #expect(state.currentJourney == cercano)
    }

    @Test("Cambiar de criterio reordena lo visible sin volver a planificar")
    func changingTheCriterionReorders() throws {
        let rapido = journey(board: 2, arrive: 20, egress: 900, line: "R")
        let cercano = journey(board: 5, arrive: 26, egress: 60, line: "C")
        var state = planned([rapido, cercano])

        state.setOrdering(.earliestArrival)
        #expect(state.visibleJourneys.first == rapido)
        #expect(state.route.journeys.count == 2, "el conjunto planificado no se toca")
    }

    /// `selectedAlternative` es un índice sobre la lista **visible**, así que reordenar sin
    /// resetearlo deja el mapa resaltando una ruta y la lista otra.
    @Test("Cambiar de criterio vuelve a la primera y apaga el seguimiento")
    func changingTheCriterionResetsSelection() throws {
        let a = journey(board: 2, arrive: 20, egress: 900, line: "A")
        let b = journey(board: 5, arrive: 26, egress: 60, line: "B")
        let c = journey(board: 9, arrive: 30, egress: 300, line: "C")
        var state = planned([a, b, c])

        state.selectAlternative(at: 2)
        _ = state.openSelectedAlternative()
        let following = state.startFollowing()
        #expect(following)
        #expect(state.selectedAlternative == 2)

        state.setOrdering(.earliestBoarding)
        #expect(state.selectedAlternative == 0)
        #expect(state.isFollowing == false)
    }

    @Test("Elegir el mismo criterio que ya estaba no toca nada")
    func settingTheSameCriterionIsANoOp() throws {
        let a = journey(board: 2, arrive: 20, egress: 60, line: "A")
        let b = journey(board: 5, arrive: 26, egress: 900, line: "B")
        var state = planned([a, b])

        state.selectAlternative(at: 1)
        state.setOrdering(.leastWalkAtEnd)
        #expect(state.selectedAlternative == 1, "no había nada que reordenar")
    }

    /// El planificador devuelve un conjunto mayor que el que cabe en pantalla justo para que
    /// el criterio elija de él.
    @Test("Solo se enseñan las que caben, elegidas por el criterio")
    func visibleIsCappedButChosenByTheCriterion() throws {
        var journeys: [Journey] = []
        for index in 0..<8 {
            // El que menos anda es el último por llegada.
            journeys.append(journey(board: Double(index), arrive: Double(20 + index),
                                    egress: index == 7 ? 30 : 600, line: "L\(index)"))
        }
        let state = planned(journeys)

        #expect(state.route.journeys.count == 8)
        #expect(state.visibleJourneys.count == 4)
        #expect(state.visibleJourneys.first == journeys[7],
                "el que menos anda entra aunque sea el último por llegada")
    }
}

@Suite("Aviso de horario estimado en el mapa")
struct MapNavigationEstimateNoticeTests {

    private let here = Coordinate(latitude: 42.2328, longitude: -8.7226)
    private let there = Coordinate(latitude: 42.2400, longitude: -8.7100)
    private let clock = Date(timeIntervalSince1970: 1_757_000_000)

    /// Cualquier trayecto sirve: lo que se comprueba aquí es el aviso, no el trayecto.
    private func anyJourney() -> Journey {
        let a = PlannerFixture.stop("A")
        let b = PlannerFixture.stop("B", northMetres: 1_000)
        return Journey(legs: [
            .walk(from: .coordinate(here, label: "O"), to: .stop(a), seconds: 120, metres: 150),
            .ride(routeID: RouteID("r1"), routeShortName: "C1", headsign: nil,
                  tripID: TripID("t1"), board: a, alight: b,
                  departure: clock.addingTimeInterval(600),
                  arrival: clock.addingTimeInterval(1_200),
                  intermediateStops: []),
            .walk(from: .stop(b), to: .coordinate(there, label: "D"), seconds: 90, metres: 110),
        ], departure: clock, arrival: clock.addingTimeInterval(1_290), transfers: 0)
    }

    private func planned(_ schedule: ServiceDaySource) -> MapNavigationState {
        var state = MapNavigationState()
        state.planningStarted()
        state.planningFinished(.journeys([anyJourney()]), schedule: schedule)
        return state
    }

    @Test("Un horario observado no lleva aviso")
    func observedHasNoNotice() {
        #expect(planned(.observed).estimateNotice == nil)
    }

    @Test("Un horario proyectado lleva aviso, y dice de qué día sale")
    func projectedHasNotice() {
        let template = ServiceDate(yyyymmdd: 20_260_904)
        let notice = planned(.projected(template: template)).estimateNotice
        #expect(notice != nil)
        #expect(notice?.contains(template.humanReadable) == true)
    }

    /// El invariante que motivó atar el aviso a `route` en vez de sólo a `schedule`: seis
    /// transiciones distintas devuelven la ruta a `.idle`, y pedirle a cada una que se
    /// acuerde de limpiar el horario es justo la clase de contabilidad que se pudre. Basta
    /// un sitio olvidado para que un aviso de "estimado" quede flotando sobre resultados
    /// firmes.
    @Test("El aviso no sobrevive a que se vacíe la ruta")
    func noticeDiesWithTheRoute() {
        var state = planned(.projected(template: ServiceDate(yyyymmdd: 20_260_904)))
        #expect(state.estimateNotice != nil)

        state.reset()
        #expect(state.estimateNotice == nil, "una ruta vacía no tiene horarios que matizar")
    }

    @Test("Una búsqueda nueva sin proyección limpia el aviso de la anterior")
    func aFreshSearchClearsIt() {
        var state = planned(.projected(template: ServiceDate(yyyymmdd: 20_260_904)))
        #expect(state.estimateNotice != nil)

        state.planningStarted()
        state.planningFinished(.journeys([anyJourney()]), schedule: .observed)
        #expect(state.estimateNotice == nil)
    }

    @Test("Un fallo tampoco arrastra el aviso")
    func failureCarriesNoNotice() {
        var state = planned(.projected(template: ServiceDate(yyyymmdd: 20_260_904)))
        state.planningStarted()
        state.planningFinished(.noJourneyFound(horizon: 3_600), schedule: .observed)
        #expect(state.estimateNotice == nil)
    }
}

@Suite("Aviso de parada cercana en el mapa")
struct MapNavigationNearbyStopHintTests {

    private let clock = Date(timeIntervalSince1970: 1_757_000_000)

    private func hint() -> NearbyStopHint {
        let n = PlannerFixture.stop("N", northMetres: 200, name: "N cercana")
        let d = PlannerFixture.stop("D", eastMetres: 3_000)
        let journey = Journey(legs: [
            .ride(routeID: RouteID("r2"), routeShortName: "L2", headsign: nil,
                  tripID: TripID("t2"), board: n, alight: d,
                  departure: clock, arrival: clock.addingTimeInterval(600),
                  intermediateStops: []),
        ], departure: clock, arrival: clock.addingTimeInterval(600), transfers: 0)
        return NearbyStopHint(stop: n, walkSeconds: 240, arrivesEarlierBy: 900, journey: journey)
    }

    private func planned(_ outcome: PlanOutcome) -> MapNavigationState {
        var state = MapNavigationState()
        state.planningStarted()
        state.planningFinished(outcome, nearbyStopHint: hint())
        return state
    }

    @Test("Se ve con alternativas y también cuando no se encontró nada")
    func visibleWithAnAnswer() {
        #expect(planned(.journeys([hint().journey])).visibleNearbyStopHint != nil)
        #expect(planned(.noJourneyFound(horizon: 3_600)).visibleNearbyStopHint != nil)
    }

    @Test("No sobrevive a que se vacíe la ruta")
    func diesWithTheRoute() {
        var state = planned(.journeys([hint().journey]))
        state.reset()
        #expect(state.visibleNearbyStopHint == nil)
    }

    @Test("Una búsqueda nueva sin aviso limpia el de la anterior")
    func aFreshSearchClearsIt() {
        var state = planned(.journeys([hint().journey]))
        state.planningStarted()
        #expect(state.visibleNearbyStopHint == nil, "mientras busca no hay respuesta que matizar")
        state.planningFinished(.journeys([hint().journey]))
        #expect(state.visibleNearbyStopHint == nil)
    }

    @Test("Un error al planificar lo quita")
    func thrownFailureClearsIt() {
        var state = planned(.journeys([hint().journey]))
        state.planningFailed()
        #expect(state.nearbyStopHint == nil)
    }
}
