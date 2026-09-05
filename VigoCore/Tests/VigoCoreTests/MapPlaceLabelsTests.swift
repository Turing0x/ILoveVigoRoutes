import Foundation
import Testing
@testable import VigoCore

/// Etiquetas de un lugar del mapa.
@Suite("Etiquetas de lugares del mapa")
struct MapPlaceLabelsTests {

    /// Las 73 categorías que declara el SDK instalado (`MKPointOfInterestCategory.h`),
    /// copiadas aquí a propósito.
    ///
    /// Es el único modo de que la tabla no se quede corta en silencio: si un SDK futuro añade
    /// una categoría, el fallo tiene que aparecer como un test rojo y no como un lugar sin
    /// subtítulo que nadie nota. Actualizar esta lista es parte de actualizar Xcode.
    private let sdkCategories: [String] = [
        "ATM",
        "Airport",
        "AmusementPark",
        "AnimalService",
        "Aquarium",
        "AutomotiveRepair",
        "Bakery",
        "Bank",
        "Baseball",
        "Basketball",
        "Beach",
        "Beauty",
        "Bowling",
        "Brewery",
        "Cafe",
        "Campground",
        "CarRental",
        "Castle",
        "ConventionCenter",
        "Distillery",
        "EVCharger",
        "Fairground",
        "FireStation",
        "Fishing",
        "FitnessCenter",
        "FoodMarket",
        "Fortress",
        "GasStation",
        "GoKart",
        "Golf",
        "Hiking",
        "Hospital",
        "Hotel",
        "Kayaking",
        "Landmark",
        "Laundry",
        "Library",
        "Mailbox",
        "Marina",
        "MiniGolf",
        "MovieTheater",
        "Museum",
        "MusicVenue",
        "NationalMonument",
        "NationalPark",
        "Nightlife",
        "Park",
        "Parking",
        "Pharmacy",
        "Planetarium",
        "Police",
        "PostOffice",
        "PublicTransport",
        "RVPark",
        "Restaurant",
        "Restroom",
        "RockClimbing",
        "School",
        "SkatePark",
        "Skating",
        "Skiing",
        "Soccer",
        "Spa",
        "Stadium",
        "Store",
        "Surfing",
        "Swimming",
        "Tennis",
        "Theater",
        "University",
        "Volleyball",
        "Winery",
        "Zoo"
    ]

    @Test("Las 73 categorías del SDK están traducidas")
    func everySDKCategoryTranslates() {
        for name in sdkCategories {
            let translated = MapPlaceLabels.pointOfInterestName(rawCategory: "MKPOICategory\(name)")
            #expect(translated?.isEmpty == false, "sin traducción para \(name)")
        }
        #expect(sdkCategories.count == MapPlaceLabels.categories.count,
                "la tabla y el SDK tienen que cuadrar en los dos sentidos")
    }

    /// Los dos valores que la sonda del paso 0 devolvió de verdad en el iPhone.
    @Test("Los valores crudos que devolvió el dispositivo se traducen")
    func spikeValuesTranslate() {
        #expect(MapPlaceLabels.pointOfInterestName(rawCategory: "MKPOICategoryStore") == "Tienda")
        #expect(MapPlaceLabels.pointOfInterestName(rawCategory: "MKPOICategoryCastle") == "Castillo")
    }

    /// Inventar una etiqueta a partir de un identificador inglés sería peor que no poner
    /// ninguna: la ficha simplemente se queda sin subtítulo.
    @Test("Una categoría desconocida no produce etiqueta")
    func unknownCategoryStaysSilent() {
        #expect(MapPlaceLabels.pointOfInterestName(rawCategory: "MKPOICategoryFuturo") == nil)
        #expect(MapPlaceLabels.pointOfInterestName(rawCategory: nil) == nil)
        #expect(MapPlaceLabels.pointOfInterestName(rawCategory: "") == nil)
    }

    @Test("Un valor sin el prefijo también se resuelve")
    func prefixIsOptional() {
        #expect(MapPlaceLabels.pointOfInterestName(rawCategory: "Hospital") == "Hospital")
    }

    @Test("Bajo un kilómetro, la distancia se redondea a 10 m")
    func shortDistancesRoundToTens() {
        #expect(MapPlaceLabels.straightLineDistance(metres: 0) == "0 m")
        #expect(MapPlaceLabels.straightLineDistance(metres: 12) == "10 m")
        #expect(MapPlaceLabels.straightLineDistance(metres: 247) == "250 m")
        #expect(MapPlaceLabels.straightLineDistance(metres: 999) == "1000 m")
    }

    @Test("A partir de un kilómetro, kilómetros con coma decimal")
    func longDistancesUseKilometres() {
        #expect(MapPlaceLabels.straightLineDistance(metres: 1_000) == "1,0 km")
        #expect(MapPlaceLabels.straightLineDistance(metres: 1_240) == "1,2 km")
        // Coma, no punto: `String(format:)` con el locale por defecto no lo garantiza.
        #expect(!MapPlaceLabels.straightLineDistance(metres: 1_240).contains("."))
    }

    @Test("A partir de diez kilómetros sobra el decimal")
    func veryLongDistancesDropTheDecimal() {
        #expect(MapPlaceLabels.straightLineDistance(metres: 12_400) == "12 km")
        #expect(MapPlaceLabels.straightLineDistance(metres: 9_900) == "9,9 km")
    }

    @Test("Una distancia imposible no pinta basura")
    func nonsenseDistancesAreEmpty() {
        #expect(MapPlaceLabels.straightLineDistance(metres: -5).isEmpty)
        #expect(MapPlaceLabels.straightLineDistance(metres: .nan).isEmpty)
        #expect(MapPlaceLabels.straightLineDistance(metres: .infinity).isEmpty)
    }
}
