import Foundation
import Testing
@testable import ILoveVigoRoutes
import VigoCore

@Suite("Búsqueda de direcciones")
@MainActor
struct AddressSearchModelTests {
    private let suggestion = AddressSuggestion(id: UUID(), title: "Hospital Álvaro Cunqueiro",
                                               subtitle: "Estrada Clara Campoamor, Vigo")

    @Test("Una consulta de menos de tres caracteres no llega al geocoder")
    func shortQueryDoesNotSearch() async {
        let service = StubAddressSearchService()
        let model = AddressSearchModel(service: service, debounce: .zero)

        model.update(query: "Ru")
        await settle()

        #expect(service.suggestionQueries.isEmpty)
        #expect(model.suggestions.isEmpty)
    }

    @Test("Una ráfaga solo busca el último texto")
    func burstOnlySearchesLastQuery() async {
        let service = StubAddressSearchService(suggestions: { _ in [] })
        let model = AddressSearchModel(service: service, debounce: .zero)

        model.update(query: "Hos")
        model.update(query: "Hosp")
        model.update(query: "Hospital")
        await settle()

        #expect(service.suggestionQueries == ["Hospital"])
    }

    @Test("Una sugerencia resuelta se convierte en un lugar para el planificador")
    func resolutionReturnsPlace() async {
        let coordinate = Coordinate(latitude: 42.2138, longitude: -8.7302)
        let service = StubAddressSearchService(resolve: { suggestion in
            .coordinate(coordinate, label: suggestion.title)
        })
        let model = AddressSearchModel(service: service, debounce: .zero)

        let place = await model.resolve(suggestion)

        #expect(place?.coordinate == coordinate)
        #expect(place?.label == suggestion.title)
        #expect(service.resolvedSuggestions == [suggestion])
    }

    @Test("Una dirección fuera de Vigo se rechaza antes de planificar")
    func outsideCoverageFails() async {
        let service = StubAddressSearchService(resolve: { _ in throw AddressSearchError.outsideCoverage })
        let model = AddressSearchModel(service: service, debounce: .zero)

        let place = await model.resolve(suggestion)

        #expect(place == nil)
        #expect(model.failed)
        #expect(model.failure == .outsideCoverage)
    }

    @Test("Un fallo del geocoder no borra ni bloquea la búsqueda de paradas")
    func failureLeavesThePickerUsable() async {
        let service = StubAddressSearchService(suggestions: { _ in [] })
        let model = AddressSearchModel(service: service, debounce: .zero)

        _ = await model.resolve(suggestion)

        #expect(model.failed)
        #expect(model.suggestions.isEmpty)
        #expect(model.resolving == nil)
    }

    @Test("La región cubre Vigo, no Santiago ni Oporto")
    func coverageRegion() {
        #expect(VigoSearchRegion.contains(Coordinate(latitude: 42.2257, longitude: -8.7413)))
        #expect(!VigoSearchRegion.contains(Coordinate(latitude: 42.8782, longitude: -8.5448)))
        #expect(!VigoSearchRegion.contains(Coordinate(latitude: 41.1579, longitude: -8.6291)))
    }

    private func settle() async {
        for _ in 0 ..< 10 { await Task.yield() }
    }
}
