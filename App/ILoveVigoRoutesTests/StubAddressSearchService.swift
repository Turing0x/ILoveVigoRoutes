import Foundation
@testable import ILoveVigoRoutes
import VigoCore

/// A main-actor stub instead of `URLProtocol`: the model does not know or care how MapKit
/// gets its answer, and tests should not pretend to exercise Apple's network client.
@MainActor
final class StubAddressSearchService: AddressSearching {
    typealias Suggestions = @MainActor (String) async -> [AddressSuggestion]
    typealias Resolution = @MainActor (AddressSuggestion) async throws -> Place

    private(set) var suggestionQueries: [String] = []
    private(set) var resolvedSuggestions: [AddressSuggestion] = []
    private let suggestionsResult: Suggestions
    private let resolutionResult: Resolution

    init(suggestions: @escaping Suggestions = { _ in [] },
         resolve: @escaping Resolution = { _ in throw AddressSearchError.notFound }) {
        self.suggestionsResult = suggestions
        self.resolutionResult = resolve
    }

    func suggestions(for query: String) async -> [AddressSuggestion] {
        suggestionQueries.append(query)
        return await suggestionsResult(query)
    }

    func resolve(_ suggestion: AddressSuggestion) async throws -> Place {
        resolvedSuggestions.append(suggestion)
        return try await resolutionResult(suggestion)
    }
}
