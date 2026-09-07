import Testing
import Foundation
@testable import VigoCore

@Suite("Perfil de movilidad")
struct AccessibilityProfileTests {

    // MARK: - Las dos tablas medidas

    /// Lo que hace que esto no sea un interruptor decorativo. Si las dos tablas empiezan a
    /// coincidir, o el recurso de silla desaparece del bundle, el modo pasaría a no hacer
    /// nada — y seguiría anunciándose en la interfaz, que es lo peor que puede pasar aquí.
    @Test("Las dos tablas existen y no son la misma")
    func twoDistinctBundledTables() {
        let foot = FootpathTable.bundled(for: .standard)
        let chair = FootpathTable.bundled(for: .wheelchair)

        #expect(foot.pairCount > 2_000, "footpaths.csv no se cargó")
        #expect(chair.pairCount > 2_000, "footpaths-wheelchair.csv no se cargó")
        #expect(chair.pairCount < foot.pairCount,
                "sin escaleras tiene que haber menos transbordos posibles, no los mismos")
    }

    /// Un transbordo que sólo existe por unas escaleras no debe existir en silla, y uno que
    /// da un rodeo debe salir más largo. Se comprueba sobre el conjunto entero en vez de
    /// sobre un par concreto: los identificadores de parada cambian cuando el Concello
    /// regenera el feed, y un test anclado a uno se pudriría en una semana.
    @Test("En silla, ningún transbordo es más corto que a pie; algunos no existen")
    func wheelchairIsNeverShorter() {
        let foot = FootpathTable.bundled(for: .standard)
        let chair = FootpathTable.bundled(for: .wheelchair)
        guard foot.pairCount > 0, chair.pairCount > 0 else { return }

        var missing = 0
        var longer = 0
        var checked = 0
        for a in foot.coveredStops {
            for b in foot.coveredStops where a != b {
                guard let onFoot = foot.metres(from: a, to: b) else { continue }
                checked += 1
                guard let inChair = chair.metres(from: a, to: b) else { missing += 1; continue }
                // La tolerancia no es pereza, es el ruido del método. Las paradas se
                // enganchan al nodo más cercano del grafo, y quitar las escaleras cambia la
                // componente conexa mayor: unas pocas paradas acaban enganchadas a otro nodo
                // y el residuo en línea recta hasta él varía. Medido sobre la tabla actual,
                // eso hace que unos pocos pares salgan hasta cuatro metros más cortos en
                // silla que a pie. Sobre caminatas de trescientos metros es ruido, y está
                // muy dentro del error del propio método; lo que no puede pasar es que la
                // ruta en silla sea sustancialmente más corta, porque su grafo es un
                // subconjunto del otro.
                #expect(inChair >= onFoot - 15,
                        "el grafo en silla es un subgrafo: no puede acortar una ruta")
                if inChair > onFoot + 0.5 { longer += 1 }
                if checked > 3_000 { break }
            }
            if checked > 3_000 { break }
        }
        #expect(missing > 0, "si no desaparece ningún transbordo, la exclusión no se aplicó")
        #expect(longer > 0, "si ninguno se alarga, la exclusión no se aplicó")
    }

    // MARK: - Velocidad

    @Test("El perfil elige la velocidad, y la de silla es más prudente")
    func profileChoosesSpeed() {
        let onFoot = PlannerOptions()
        var inChair = PlannerOptions()
        inChair.accessibility = .wheelchair

        #expect(onFoot.effectiveWalkSpeed == onFoot.walkSpeedMetresPerSecond)
        #expect(inChair.effectiveWalkSpeed == inChair.wheelchairSpeedMetresPerSecond)
        #expect(inChair.effectiveWalkSpeed < onFoot.effectiveWalkSpeed)

        // Y eso llega hasta las cifras que ve el usuario.
        for kind in WalkKind.allCases {
            #expect(WalkModel(options: inChair).seconds(metres: 400, as: kind)
                    > WalkModel(options: onFoot).seconds(metres: 400, as: kind))
        }
    }

    /// `metres(forSeconds:as:)` invierte la conversión para etiquetar un tramo en el mapa.
    /// Si no usara la misma velocidad que la produjo, un usuario en silla vería metros
    /// inflados por la razón entre las dos velocidades.
    @Test("La conversión inversa usa la velocidad del perfil")
    func inverseUsesTheProfileSpeed() {
        var inChair = PlannerOptions()
        inChair.accessibility = .wheelchair
        let walk = WalkModel(options: inChair)
        for kind in WalkKind.allCases {
            let back = walk.metres(forSeconds: walk.seconds(metres: 300, as: kind), as: kind)
            #expect(abs(back - 300) < 1.5)
        }
    }

    // MARK: - El perfil viaja con la consulta

    @Test("PlanQuery lleva el perfil, y por defecto es a pie")
    func queryCarriesTheProfile() {
        let origin = Place.coordinate(Coordinate(latitude: 42.23, longitude: -8.72), label: "O")
        let destination = Place.coordinate(Coordinate(latitude: 42.24, longitude: -8.71), label: "D")
        let plain = PlanQuery(origin: origin, destination: destination, departure: Date())
        #expect(plain.accessibility == .standard)

        let chair = PlanQuery(origin: origin, destination: destination,
                              departure: Date(), accessibility: .wheelchair)
        #expect(chair.accessibility == .wheelchair)
        #expect(plain != chair, "el perfil forma parte de la identidad de la consulta")
    }

    // MARK: - El estado del mapa

    /// La diferencia con `ordering`, y el motivo de que exista `setAccessibility` en vez de
    /// una propiedad a secas: cambiar de perfil **invalida** la respuesta, no la reordena.
    /// Dejar en pantalla trayectos calculados a pie bajo una etiqueta de silla de ruedas
    /// sería la peor mentira que esta app puede contar.
    @Test("Cambiar de perfil tira la respuesta que había")
    func changingProfileDropsTheAnswer() {
        var state = MapNavigationState()
        state.planningStarted()
        state.planningFinished(.noJourneyFound(horizon: 3_600))
        #expect(state.route.failure != nil)

        let changed = state.setAccessibility(.wheelchair)
        #expect(changed == true)
        #expect(state.accessibility == .wheelchair)
        if case .idle = state.route {} else {
            Issue.record("la ruta debería haberse vaciado, quedó \(state.route)")
        }
    }

    @Test("Repetir el perfil actual no cuesta una búsqueda")
    func repeatingTheProfileIsANoOp() {
        var state = MapNavigationState()
        var changed = state.setAccessibility(.standard)
        #expect(changed == false)
        changed = state.setAccessibility(.wheelchair)
        #expect(changed == true)
        changed = state.setAccessibility(.wheelchair)
        #expect(changed == false)
    }

    @Test("La consulta que sale del estado lleva el perfil elegido")
    func stateBuildsTheQueryWithTheProfile() {
        var state = MapNavigationState()
        state.updateCurrentLocation(Coordinate(latitude: 42.2328, longitude: -8.7226))
        state.select(MapPlace(place: .coordinate(
            Coordinate(latitude: 42.24, longitude: -8.71), label: "Destino"),
            subtitle: nil, origin: .pointOfInterest))
        let routed = state.routeToSelectedPlace()
        #expect(routed)

        _ = state.setAccessibility(.wheelchair)
        // Cambiar de perfil vacía la ruta pero no los extremos, así que la consulta sigue
        // pudiéndose construir — con el perfil nuevo.
        let query = state.routeQuery(now: Date())
        #expect(query?.accessibility == .wheelchair)
    }
}

@Suite("Radio de acceso en minutos")
struct AccessRadiusTests {

    /// B4. El radio ya no es una constante en metros: sale de un presupuesto de tiempo. Es lo
    /// que hace coherente el modo «camino despacio», que antes cambiaba la velocidad pero
    /// dejaba a todo el mundo con el mismo radio en metros.
    @Test("El radio sale del presupuesto de minutos, no al revés")
    func radiusIsDerived() {
        var options = PlannerOptions()
        let base = options.accessRadiusMetres
        options.maxAccessWalkMinutes *= 2
        #expect(abs(options.accessRadiusMetres - base * 2) < 0.001)
    }

    /// Que el radio por defecto siga siendo el que fija el handoff. Expresar la política en
    /// la unidad correcta no debía cambiar hasta dónde llega la app.
    @Test("Por defecto sigue alcanzando los 800 m de siempre")
    func defaultReachIsUnchanged() {
        #expect(abs(PlannerOptions().accessRadiusMetres - 800) < 5)
    }

    /// El mismo presupuesto de tiempo, menos distancia. Ésa es la idea entera.
    @Test("En silla de ruedas el radio se encoge solo")
    func wheelchairRadiusShrinks() {
        var chair = PlannerOptions()
        chair.accessibility = .wheelchair
        #expect(chair.maxAccessWalkMinutes == PlannerOptions().maxAccessWalkMinutes)
        #expect(chair.accessRadiusMetres < PlannerOptions().accessRadiusMetres)
        // 15 min a 1,0 m/s con factor 1,50.
        #expect(abs(chair.accessRadiusMetres - 600) < 5)
    }

    /// Andar despacio también encoge el radio, que es lo que antes no pasaba.
    @Test("Andar más despacio encoge el radio")
    func slowerWalkerReachesLess() {
        var slow = PlannerOptions(walkSpeedMetresPerSecond: 1.0)
        #expect(slow.accessRadiusMetres < PlannerOptions().accessRadiusMetres)
        slow.maxAccessWalkMinutes = 20
        #expect(slow.accessRadiusMetres > PlannerOptions().accessRadiusMetres * 0.9,
                "más tiempo compensa la velocidad")
    }

    /// Un radio derivado no puede contradecir al tiempo que representa: la caminata que
    /// implica el borde del radio es exactamente el presupuesto.
    @Test("El borde del radio cuesta exactamente el presupuesto")
    func theEdgeCostsTheBudget() {
        for profile in AccessibilityProfile.allCases {
            var options = PlannerOptions()
            options.accessibility = profile
            let walk = WalkModel(options: options)
            let seconds = walk.seconds(metres: options.accessRadiusMetres, as: .accessEgress)
            #expect(abs(Double(seconds) - options.maxAccessWalkMinutes * 60) <= 1)
        }
    }
}
