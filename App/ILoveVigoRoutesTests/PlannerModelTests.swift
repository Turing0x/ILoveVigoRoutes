import Foundation
import Testing
@testable import ILoveVigoRoutes
import VigoCore

/// The origin defaults to the device's position and keeps up with it — until the user says
/// otherwise. These tests are about that "until": nothing here touches CoreLocation, they
/// feed the model coordinates directly, which is all the view does anyway.
@Suite("Origen automático del planificador")
@MainActor
struct PlannerModelTests {

    private func makeModel() throws -> PlannerModel {
        let repository = TransitRepository(database: try AppDatabase.inMemory())
        let planner = JourneyPlanner(repository: repository,
                                     store: TimetableStore(repository: repository))
        return PlannerModel(planner: planner)
    }

    private let here = Coordinate(latitude: 42.2328, longitude: -8.7226)
    private let there = Coordinate(latitude: 42.2400, longitude: -8.7100)

    @Test("Sin elección previa, el origen es la ubicación y se refresca")
    func followsLocationByDefault() throws {
        let model = try makeModel()
        #expect(model.origin == nil)
        #expect(model.originFollowsLocation)

        model.updateCurrentLocation(here)
        #expect(model.origin?.coordinate == here)
        #expect(model.origin?.label == PickedPlace.currentLocationLabel)

        model.updateCurrentLocation(there)
        #expect(model.origin?.coordinate == there)
    }

    @Test("Un origen elegido a mano ya no lo pisa el GPS")
    func manualOriginWins() throws {
        let model = try makeModel()
        model.updateCurrentLocation(here)

        let chosen = Place.coordinate(there, label: "Samil")
        model.setOrigin(PickedPlace(place: chosen, isCurrentLocation: false))
        #expect(!model.originFollowsLocation)

        model.updateCurrentLocation(here)
        #expect(model.origin == chosen, "una actualización del GPS no puede pisar lo que eligió el usuario")
    }

    @Test("Elegir 'Mi ubicación' en el selector vuelve a activar el seguimiento")
    func pickingCurrentLocationResumesFollowing() throws {
        let model = try makeModel()
        model.setOrigin(PickedPlace(place: .coordinate(there, label: "Samil"), isCurrentLocation: false))

        model.setOrigin(.currentLocation(here))
        #expect(model.originFollowsLocation)

        model.updateCurrentLocation(there)
        #expect(model.origin?.coordinate == there)
    }

    @Test("El botón de volver a la ubicación reanuda el seguimiento")
    func useCurrentLocationResumesFollowing() throws {
        let model = try makeModel()
        model.setOrigin(PickedPlace(place: .coordinate(there, label: "Samil"), isCurrentLocation: false))

        model.useCurrentLocation(here)
        #expect(model.originFollowsLocation)
        #expect(model.origin?.coordinate == here)
    }

    @Test("Intercambiar es una elección: el origen deja de seguir al GPS")
    func swappingIsAChoice() throws {
        let model = try makeModel()
        model.updateCurrentLocation(here)
        model.setDestination(PickedPlace(place: .coordinate(there, label: "Samil"),
                                         isCurrentLocation: false))

        model.swapPlaces()
        #expect(!model.originFollowsLocation)
        #expect(model.origin?.coordinate == there)
        #expect(model.destination?.coordinate == here)

        model.updateCurrentLocation(here)
        #expect(model.origin?.coordinate == there, "tras intercambiar, el GPS ya no manda")
    }

    @Test("Fijar el origen desde un lugar guardado usa su nombre y deja de seguir el GPS")
    func settingOriginFromSavedPlace() throws {
        let model = try makeModel()
        model.updateCurrentLocation(here)

        let home = SavedPlace(id: SavedPlaceID.generate(), name: "Casa", symbolName: "house.fill",
                              anchor: .coordinate(there), createdAt: Date(), sortIndex: 0)
        model.setOrigin(PickedPlace(place: home.place, isCurrentLocation: false))

        #expect(model.origin?.label == "Casa")
        #expect(model.origin?.coordinate == there)
        #expect(!model.originFollowsLocation)

        model.updateCurrentLocation(here)
        #expect(model.origin?.label == "Casa", "una actualización del GPS no puede pisar un lugar guardado")
    }

    @Test("Sin origen y sin destino no se puede planificar")
    func cannotPlanWithoutBothEnds() throws {
        let model = try makeModel()
        #expect(!model.canPlan)
        model.updateCurrentLocation(here)
        #expect(!model.canPlan)
        model.setDestination(PickedPlace(place: .coordinate(there, label: "Samil"),
                                         isCurrentLocation: false))
        #expect(model.canPlan)
    }
}
