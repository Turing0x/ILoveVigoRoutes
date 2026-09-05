import Foundation

/// Which end of a route a search is filling in.
enum PlacePickerRole: Hashable { case origin, destination }

/// `MapRouteSheet` presents its endpoint search with `.sheet(item:)`.
extension PlacePickerRole: Identifiable {
    var id: Self { self }
}
