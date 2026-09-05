import Foundation

/// Decides which stops the map may draw for a given viewport.
///
/// Pulled out of the view — where it lived as a private method of `StopsMapView` with no
/// test of its own — for two reasons. It is pure geometry, so `swift test` can check it on
/// the Mac; and its old shape hid a real ambiguity.
///
/// **The ambiguity.** The old code returned an empty array both when the viewport genuinely
/// contained no stops and when it contained too many to draw, and the view guessed between
/// the two with `visibleStops.isEmpty && !allStops.isEmpty` — which reads "too many, zoom in"
/// over any empty patch of map as long as the feed has stops somewhere. Panning out to sea
/// or over Redondela produced a "zoom in to see the stops" hint with nothing to zoom into.
/// Returning a two-case answer makes the difference impossible to lose.
public enum MapStopsLayer {

    /// The visible rectangle, in the same terms MapKit's region uses but without MapKit:
    /// this package stays free of it.
    public struct Viewport: Sendable, Hashable {
        public let centreLatitude: Double
        public let centreLongitude: Double
        public let latitudeSpan: Double
        public let longitudeSpan: Double

        public init(centreLatitude: Double, centreLongitude: Double,
                    latitudeSpan: Double, longitudeSpan: Double) {
            self.centreLatitude = centreLatitude
            self.centreLongitude = centreLongitude
            self.latitudeSpan = abs(latitudeSpan)
            self.longitudeSpan = abs(longitudeSpan)
        }

        public func contains(latitude: Double, longitude: Double) -> Bool {
            abs(latitude - centreLatitude) <= latitudeSpan / 2
                && abs(longitude - centreLongitude) <= longitudeSpan / 2
        }
    }

    public enum Content: Sendable, Equatable {
        /// Draw these. An empty array means this patch of map really has no stops — not
        /// that the map is too far out.
        case stops([Stop])
        /// Too many to be readable. Carries how many, so the hint can say something true.
        case tooMany(count: Int)

        public var stops: [Stop] {
            if case .stops(let stops) = self { return stops }
            return []
        }
    }

    /// Above this many candidates the layer draws nothing. Inherited from `StopsMapView`,
    /// where the reasoning was that plotting 1149 annotations at city scale is unreadable
    /// and janky; the number is unchanged so this step is a refactor, not a retune.
    public static let defaultLimit = 220

    public static func content(from stops: [Stop], in viewport: Viewport,
                               limit: Int = defaultLimit) -> Content {
        // One pass, no early exit. An early exit would need the total anyway to say how many
        // there are, and 1149 stops is not a number worth being clever about — the first
        // attempt at cleverness here cost an accidental O(n²) and bought nothing.
        let inView = stops.filter {
            viewport.contains(latitude: $0.latitude, longitude: $0.longitude)
        }
        return inView.count > limit ? .tooMany(count: inView.count) : .stops(inView)
    }
}
