import Testing
import Foundation
@testable import VigoCore

@Suite("Disposición del buscador (H-44)")
struct SearchLayoutTests {

    // MARK: - Shortcuts (campo vacío)

    @Test("Sin datos importados, ninguna sección y el aviso de feed vacío")
    func shortcutsNoFeed() {
        let layout = SearchLayoutBuilder.shortcuts(
            showsSavedJourneys: true, hasData: false,
            savedJourneys: 3, savedPlaces: 3, favourites: 3, nearby: 3, lines: 45)
        #expect(layout.sections.isEmpty)
        #expect(layout.emptyState == .noFeed)
    }

    /// H-23: el texto de ayuda ignoraba "Cerca de ti" y "Líneas con servicio" — con 45
    /// líneas siempre presentes en un feed importado, el mensaje casi nunca debía verse.
    @Test("Con cercanía o líneas ya hay algo que enseñar, aunque nada esté guardado")
    func shortcutsNearbyOrLinesCountAsContent() {
        let onlyLines = SearchLayoutBuilder.shortcuts(
            showsSavedJourneys: true, hasData: true,
            savedJourneys: 0, savedPlaces: 0, favourites: 0, nearby: 0, lines: 45)
        #expect(onlyLines.sections == [.lines])
        #expect(onlyLines.emptyState == .none)

        let onlyNearby = SearchLayoutBuilder.shortcuts(
            showsSavedJourneys: true, hasData: true,
            savedJourneys: 0, savedPlaces: 0, favourites: 0, nearby: 4, lines: 0)
        #expect(onlyNearby.sections == [.nearby])
        #expect(onlyNearby.emptyState == .none)
    }

    @Test("Nada guardado, ni cerca, ni líneas: la instalación recién estrenada")
    func shortcutsGettingStarted() {
        let layout = SearchLayoutBuilder.shortcuts(
            showsSavedJourneys: true, hasData: true,
            savedJourneys: 0, savedPlaces: 0, favourites: 0, nearby: 0, lines: 0)
        #expect(layout.sections.isEmpty)
        #expect(layout.emptyState == .gettingStarted)
    }

    @Test("Orden fijo: trayectos, lugares, favoritas, cerca de ti, líneas")
    func shortcutsOrder() {
        let layout = SearchLayoutBuilder.shortcuts(
            showsSavedJourneys: true, hasData: true,
            savedJourneys: 1, savedPlaces: 1, favourites: 1, nearby: 1, lines: 1)
        #expect(layout.sections == [.savedJourneys, .savedPlaces, .favourites, .nearby, .lines])
    }

    /// `.standalone` no ofrece trayectos guardados (no hay origen/destino que emparejar) —
    /// aunque existan, no deben aparecer cuando el llamante dice que no tocan.
    @Test("showsSavedJourneys en falso oculta la sección aunque haya trayectos")
    func shortcutsHidesSavedJourneysWhenPurposeSaysNo() {
        let layout = SearchLayoutBuilder.shortcuts(
            showsSavedJourneys: false, hasData: true,
            savedJourneys: 5, savedPlaces: 0, favourites: 0, nearby: 0, lines: 0)
        #expect(!layout.sections.contains(.savedJourneys))
        #expect(layout.emptyState == .gettingStarted, "5 trayectos ocultos no cuentan como contenido")
    }

    // MARK: - Results (consulta no vacía)

    @Test("Sin datos importados, el resultado también dice noFeed")
    func resultsNoFeed() {
        let layout = SearchLayoutBuilder.results(
            hasData: false, stops: 3, matchingLines: 1,
            addressesQueryTooShort: false, addressesSearching: false, addresses: 2, addressesFailed: false)
        #expect(layout.sections.isEmpty)
        #expect(layout.emptyState == .noFeed)
    }

    /// H-22: con una consulta demasiado corta para el geocoder, el estado vacío tiene que
    /// distinguirse de un "no hay resultados" real — el buscador de direcciones no llegó a
    /// preguntar nada.
    @Test("Consulta corta sin resultados: queryTooShortForAddresses, no noResults")
    func resultsQueryTooShort() {
        let layout = SearchLayoutBuilder.results(
            hasData: true, stops: 0, matchingLines: 0,
            addressesQueryTooShort: true, addressesSearching: false, addresses: 0, addressesFailed: false)
        #expect(layout.emptyState == .queryTooShortForAddresses)
        #expect(!layout.sections.contains(.addresses), "la sección no se dibuja si nunca se buscó")
    }

    @Test("Consulta larga sin resultados en ningún sitio: noResults")
    func resultsGenuinelyEmpty() {
        let layout = SearchLayoutBuilder.results(
            hasData: true, stops: 0, matchingLines: 0,
            addressesQueryTooShort: false, addressesSearching: false, addresses: 0, addressesFailed: false)
        #expect(layout.emptyState == .noResults)
    }

    /// H-21: la sección "Direcciones" solo se dibuja cuando hay algo que enseñar en ella —
    /// buscando, con resultados, o con un fallo que explicar — nunca cuando la consulta es
    /// demasiado corta para haber empezado.
    @Test("La sección de direcciones aparece buscando, con resultados, o al fallar")
    func addressesSectionAppearsWhenRelevant() {
        for (searching, count, failed) in [(true, 0, false), (false, 3, false), (false, 0, true)] {
            let layout = SearchLayoutBuilder.results(
                hasData: true, stops: 0, matchingLines: 0,
                addressesQueryTooShort: false, addressesSearching: searching,
                addresses: count, addressesFailed: failed)
            #expect(layout.sections.contains(.addresses),
                    "searching=\\(searching) count=\\(count) failed=\\(failed)")
        }
    }

    /// Un fallo ya dice lo que pasó en su propia fila; no hace falta que el estado general
    /// también anuncie "no resultados" encima.
    @Test("Un fallo de direcciones no cuenta como noResults")
    func addressFailureDoesNotAlsoClaimNoResults() {
        let layout = SearchLayoutBuilder.results(
            hasData: true, stops: 0, matchingLines: 0,
            addressesQueryTooShort: false, addressesSearching: false, addresses: 0, addressesFailed: true)
        #expect(layout.emptyState == .none)
    }

    @Test("Buscando todavía no es 'sin resultados'")
    func searchingIsNotEmpty() {
        let layout = SearchLayoutBuilder.results(
            hasData: true, stops: 0, matchingLines: 0,
            addressesQueryTooShort: false, addressesSearching: true, addresses: 0, addressesFailed: false)
        #expect(layout.emptyState == .none)
    }

    @Test("Orden fijo: paradas, líneas, direcciones")
    func resultsOrder() {
        let layout = SearchLayoutBuilder.results(
            hasData: true, stops: 1, matchingLines: 1,
            addressesQueryTooShort: false, addressesSearching: false, addresses: 1, addressesFailed: false)
        #expect(layout.sections == [.stops, .matchingLines, .addresses])
    }
}
