import Foundation

/// Turns the raw identifiers Apple's map features carry into text a person can read, and
/// distances into text that does not overstate what this app knows.
///
/// Lives in `VigoCore`, and takes the category as a plain `String`, so MapKit stays out of
/// this package and both halves stay checkable by `swift test` on the Mac.
public enum MapPlaceLabels {

    /// Spanish name for a `MKPointOfInterestCategory` raw value, or `nil` when it is not one
    /// this table knows.
    ///
    /// The raw values are `MKPOICategory` + the constant's name — `MKPOICategoryStore`,
    /// `MKPOICategoryCastle` — which is exactly what came back from the Fase 5 spike on
    /// device, and exactly what must never reach the screen.
    ///
    /// **`nil` rather than a guess.** An unknown category shows no subtitle at all, which is
    /// honest; echoing `MKPOICategoryFoo` or de-camel-casing it into "Foo" would be inventing
    /// a Spanish label out of an English identifier.
    ///
    /// The table covers all 73 categories the installed SDK declares, and
    /// `MapPlaceLabelsTests` pins that list so a new SDK adding one shows up as a failing
    /// test rather than as a place with no subtitle.
    public static func pointOfInterestName(rawCategory: String?) -> String? {
        guard let rawCategory else { return nil }
        let key = rawCategory.hasPrefix(categoryPrefix)
            ? String(rawCategory.dropFirst(categoryPrefix.count))
            : rawCategory
        return categories[key]
    }

    private static let categoryPrefix = "MKPOICategory"

    static let categories: [String: String] = [
        "ATM": "Cajero automático",
        "Airport": "Aeropuerto",
        "AmusementPark": "Parque de atracciones",
        "AnimalService": "Servicios para animales",
        "Aquarium": "Acuario",
        "AutomotiveRepair": "Taller mecánico",
        "Bakery": "Panadería",
        "Bank": "Banco",
        "Baseball": "Béisbol",
        "Basketball": "Baloncesto",
        "Beach": "Playa",
        "Beauty": "Belleza",
        "Bowling": "Bolera",
        "Brewery": "Cervecería",
        "Cafe": "Cafetería",
        "Campground": "Camping",
        "CarRental": "Alquiler de coches",
        "Castle": "Castillo",
        "ConventionCenter": "Palacio de congresos",
        "Distillery": "Destilería",
        "EVCharger": "Punto de recarga",
        "Fairground": "Recinto ferial",
        "FireStation": "Parque de bomberos",
        "Fishing": "Pesca",
        "FitnessCenter": "Gimnasio",
        "FoodMarket": "Mercado",
        "Fortress": "Fortaleza",
        "GasStation": "Gasolinera",
        "GoKart": "Karting",
        "Golf": "Golf",
        "Hiking": "Senderismo",
        "Hospital": "Hospital",
        "Hotel": "Hotel",
        "Kayaking": "Piragüismo",
        "Landmark": "Lugar de interés",
        "Laundry": "Lavandería",
        "Library": "Biblioteca",
        "Mailbox": "Buzón",
        "Marina": "Puerto deportivo",
        "MiniGolf": "Minigolf",
        "MovieTheater": "Cine",
        "Museum": "Museo",
        "MusicVenue": "Sala de conciertos",
        "NationalMonument": "Monumento nacional",
        "NationalPark": "Parque nacional",
        "Nightlife": "Ocio nocturno",
        "Park": "Parque",
        "Parking": "Aparcamiento",
        "Pharmacy": "Farmacia",
        "Planetarium": "Planetario",
        "Police": "Policía",
        "PostOffice": "Oficina de correos",
        "PublicTransport": "Transporte público",
        "RVPark": "Área de autocaravanas",
        "Restaurant": "Restaurante",
        "Restroom": "Aseos",
        "RockClimbing": "Escalada",
        "School": "Colegio",
        "SkatePark": "Skatepark",
        "Skating": "Patinaje",
        "Skiing": "Esquí",
        "Soccer": "Fútbol",
        "Spa": "Balneario",
        "Stadium": "Estadio",
        "Store": "Tienda",
        "Surfing": "Surf",
        "Swimming": "Natación",
        "Tennis": "Tenis",
        "Theater": "Teatro",
        "University": "Universidad",
        "Volleyball": "Voleibol",
        "Winery": "Bodega",
        "Zoo": "Zoo",
    ]

    /// Straight-line distance, worded so it cannot be mistaken for a walking route.
    ///
    /// This app has no street graph — the same reason `PlannerOptions.walkDetourFactor`
    /// exists — so the only honest distance it can put on a card is the one as the crow
    /// flies. Under a kilometre it rounds to 10 m, because a metre of precision on a
    /// straight line between two rounded coordinates is precision this app does not have.
    public static func straightLineDistance(metres: Double) -> String {
        guard metres.isFinite, metres >= 0 else { return "" }
        if metres < 1_000 {
            let rounded = Int((metres / 10).rounded()) * 10
            return "\(rounded) m"
        }
        let kilometres = metres / 1_000
        if kilometres >= 10 {
            return "\(Int(kilometres.rounded())) km"
        }
        // Coma decimal: es el separador en castellano, y `String(format:)` con el locale por
        // defecto no lo garantiza.
        return String(format: "%.1f", kilometres).replacingOccurrences(of: ".", with: ",") + " km"
    }
}
