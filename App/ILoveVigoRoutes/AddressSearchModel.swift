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
    /// never even starts a debounce timer. Not `private`: `MapSearchSheet` reads it to tell
    /// "too short to have searched" apart from "searched and found nothing" (H-22).
    static let minimumQueryLength = 3

    private(set) var suggestions: [AddressSuggestion] = []
    private(set) var isSearching = false
    /// A simple state for the view; `failure` retains the reason needed for the copy.
    private(set) var failed = false
    private(set) var failure: AddressSearchError?
    private(set) var resolving: AddressSuggestion.ID?

    private let service: any AddressSearching
    private let debounce: Duration
    private let timeout: Duration
    private var task: Task<Void, Never>?

    /// `debounce` and `timeout` are injectable only so tests can pass short values and not
    /// sleep for real.
    init(service: any AddressSearching, debounce: Duration = .milliseconds(300),
         timeout: Duration = .seconds(5)) {
        self.service = service
        self.debounce = debounce
        self.timeout = timeout
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
        task = Task { [weak self, service, debounce, timeout] in
            // Unlike the stop search, this one costs a round trip to Apple, so it waits until
            // the typing stops. 300 ms is the usual "finished a word" pause: shorter fires
            // mid-word, longer feels like the list has got stuck.
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            // H-16: nothing upstream ever times out the completer on its own — no network,
            // or an Apple throttle that never calls the delegate back, left `isSearching`
            // true forever, with no way out except typing something new. Racing the real
            // call against a generous ceiling turns that silent hang into a stated failure.
            let found = await Self.withTimeout(timeout) { await service.suggestions(for: trimmed) }
            guard !Task.isCancelled, let self else { return }
            self.isSearching = false
            if let found {
                self.suggestions = found
            } else {
                self.suggestions = []
                self.failed = true
                self.failure = .unavailable
            }
        }
    }

    /// Races `operation` against `duration`; `nil` means the timeout won rather than
    /// `operation` returning.
    ///
    /// Not `withTaskGroup`: its children must be `@Sendable`, which would force `service` —
    /// deliberately *not* `Sendable`, per `AddressSearching`'s own doc comment, because the
    /// only real implementation is bound to a main-thread delegate API — across an actor
    /// boundary it was built never to cross. `operation` is typed `@MainActor` instead, so
    /// the closure that calls it can capture `service` exactly as the caller already does.
    /// Two ordinary `Task`s inherit that same main-actor isolation from this method (a static
    /// member of a `@MainActor` class), and `resumed` — read and written only on the main
    /// actor — is enough to resume the continuation exactly once. The losing task is left to
    /// finish on its own: for the timeout branch that is a `Task.sleep` with nothing to clean
    /// up, and for `operation` that is `service.suggestions(for:)`, whose own next call
    /// already retires whatever the previous one left waiting (`resumePending(with: [])` in
    /// `MapKitAddressSearchService`).
    private static func withTimeout<T: Sendable>(
        _ duration: Duration, operation: @MainActor @escaping () async -> T
    ) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            var resumed = false
            Task {
                let result = await operation()
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: result)
            }
            Task {
                try? await Task.sleep(for: duration)
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: nil)
            }
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
