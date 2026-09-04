import Foundation
import Observation
import VigoCore

/// Drives the "Direcciones" section: query in, suggestions out, with the debounce and the
/// cancellation rules that the stop search does not need.
///
/// Everything worth testing about address search lives here rather than in the MapKit
/// service, which is why the service sits behind `AddressSearching`.
@MainActor
@Observable
final class AddressSearchModel {
    /// Matches the floor in `MapKitAddressSearchService`, enforced here too so a short query
    /// never even starts a debounce timer.
    private static let minimumQueryLength = 3

    private(set) var suggestions: [AddressSuggestion] = []
    private(set) var isSearching = false
    /// A simple state for the view; `failure` retains the reason needed for the copy.
    private(set) var failed = false
    private(set) var failure: AddressSearchError?
    private(set) var resolving: AddressSuggestion.ID?

    private let service: any AddressSearching
    private let debounce: Duration
    private var task: Task<Void, Never>?

    /// `debounce` is injectable only so tests can pass `.zero` and not sleep.
    init(service: any AddressSearching, debounce: Duration = .milliseconds(300)) {
        self.service = service
        self.debounce = debounce
    }

    func update(query: String) {
        task?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= Self.minimumQueryLength else {
            suggestions = []
            isSearching = false
            failed = false
            failure = nil
            return
        }

        isSearching = true
        failed = false
        failure = nil
        task = Task { [weak self, service, debounce] in
            // Unlike the stop search, this one costs a round trip to Apple, so it waits until
            // the typing stops. 300 ms is the usual "finished a word" pause: shorter fires
            // mid-word, longer feels like the list has got stuck.
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            let found = await service.suggestions(for: trimmed)
            guard !Task.isCancelled, let self else { return }
            self.suggestions = found
            self.isSearching = false
        }
    }

    /// Called from `.onDisappear`, so a search in flight does not outlive the sheet.
    func cancel() {
        task?.cancel()
        task = nil
        isSearching = false
    }

    func resolve(_ suggestion: AddressSuggestion) async -> Place? {
        resolving = suggestion.id
        failed = false
        failure = nil
        defer { resolving = nil }
        do {
            return try await service.resolve(suggestion)
        } catch let error as AddressSearchError {
            failed = true
            failure = error
            return nil
        } catch {
            failed = true
            failure = .unavailable
            return nil
        }
    }
}
