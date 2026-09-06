import Foundation

/// A section `MapSearchSheet` can show. What each one contains stays the view's job; this
/// only decides which appear, and in what order.
public enum SearchSection: Sendable, Hashable {
    case savedJourneys, savedPlaces, favourites, nearby, lines
    case stops, matchingLines, addresses
}

/// What to say when a section list is empty. Four different reasons that the view used to
/// collapse into one `ContentUnavailableView`, or into no check at all.
public enum SearchEmptyState: Sendable, Hashable {
    /// Some section already has content, or the query legitimately found something.
    case none
    /// The feed has not been imported yet — nothing below could possibly answer.
    case noFeed
    /// The query is shorter than the address geocoder's own minimum, so "no results" would
    /// claim a search that never ran.
    case queryTooShortForAddresses
    /// A completed search — stops, lines, and (when it ran) addresses — found nothing.
    case noResults
    /// The empty-field shortcuts have nothing to offer either: a fresh install with nothing
    /// saved, favourited, or nearby.
    case gettingStarted
}

public struct SearchLayout: Sendable, Hashable {
    public let sections: [SearchSection]
    public let emptyState: SearchEmptyState

    public init(sections: [SearchSection], emptyState: SearchEmptyState) {
        self.sections = sections
        self.emptyState = emptyState
    }
}

/// The pure half of `MapSearchSheet`'s "what shows" decision, pulled out so it can run under
/// `swift test` instead of only being checkable in the simulator (the audit's H-44).
///
/// Two entry points, one per state the sheet can be in — mirroring its own `shortcuts` and
/// `searchResults` `@ViewBuilder`s exactly, so a change to one has an obvious home here.
public enum SearchLayoutBuilder {
    /// The empty-field state: trayectos, lugares, favoritas, cerca de ti, líneas.
    public static func shortcuts(
        showsSavedJourneys: Bool,
        hasData: Bool,
        savedJourneys: Int,
        savedPlaces: Int,
        favourites: Int,
        nearby: Int,
        lines: Int
    ) -> SearchLayout {
        guard hasData else { return SearchLayout(sections: [], emptyState: .noFeed) }

        var sections: [SearchSection] = []
        if showsSavedJourneys, savedJourneys > 0 { sections.append(.savedJourneys) }
        if savedPlaces > 0 { sections.append(.savedPlaces) }
        if favourites > 0 { sections.append(.favourites) }
        if nearby > 0 { sections.append(.nearby) }
        if lines > 0 { sections.append(.lines) }

        return SearchLayout(sections: sections, emptyState: sections.isEmpty ? .gettingStarted : .none)
    }

    /// The non-empty-query state: paradas, líneas, direcciones.
    ///
    /// `addressesQueryTooShort` gates the "Direcciones" section itself: below the geocoder's
    /// own minimum it never ran, so showing an empty section — or worse, folding it into "no
    /// results" — would claim a search that did not happen. A failed address search still
    /// shows the section (its own row explains the failure) and is deliberately excluded from
    /// `.noResults` for the same reason: the failure message already says what happened, and
    /// stacking a second "no results" view under it would say it twice.
    public static func results(
        hasData: Bool,
        stops: Int,
        matchingLines: Int,
        addressesQueryTooShort: Bool,
        addressesSearching: Bool,
        addresses: Int,
        addressesFailed: Bool
    ) -> SearchLayout {
        guard hasData else { return SearchLayout(sections: [], emptyState: .noFeed) }

        var sections: [SearchSection] = []
        if stops > 0 { sections.append(.stops) }
        if matchingLines > 0 { sections.append(.matchingLines) }
        if !addressesQueryTooShort { sections.append(.addresses) }

        let emptyState: SearchEmptyState
        if stops == 0, matchingLines == 0, addresses == 0, !addressesSearching, !addressesFailed {
            emptyState = addressesQueryTooShort ? .queryTooShortForAddresses : .noResults
        } else {
            emptyState = .none
        }
        return SearchLayout(sections: sections, emptyState: emptyState)
    }
}
