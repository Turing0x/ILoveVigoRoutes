import Foundation
import MapKit
import VigoCore

/// Address lookup through MapKit. The only file in the app that talks to Apple's geocoder.
///
/// Two APIs, two jobs. `MKLocalSearchCompleter` gives cheap as-you-type completions but no
/// coordinates; `MKLocalSearch` turns one chosen completion into a real point. Resolving only
/// on tap is what keeps full searches down to one per journey planned — "ser buen ciudadano
/// con las fuentes" applies to Apple as much as to Vitrasa.
///
/// The class is `@MainActor` rather than an actor because the completer, its delegate
/// callbacks and `MKLocalSearchCompletion` are all main-thread APIs; an actor would only add
/// hops and force `assumeIsolated` gymnastics at every turn.
///
/// Nothing here is covered by tests. The delegate plumbing, the continuation invariant and
/// `MKLocalSearch` cannot be exercised without hitting Apple's servers, so this is the
/// highest-risk code in the feature and it is verified by hand in the simulator only. What
/// *is* tested lives above the `AddressSearching` seam, in `AddressSearchModel`.
@MainActor
final class MapKitAddressSearchService: NSObject, AddressSearching, MKLocalSearchCompleterDelegate {
    /// Below this, completions are noise and every keystroke is a round trip.
    private static let minimumQueryLength = 3

    /// One completer for the whole lifetime of the service. Recreating it per keystroke would
    /// throw away the session MapKit keeps behind it; it is idle whenever `queryFragment` is
    /// empty, so keeping it costs nothing.
    private let completer = MKLocalSearchCompleter()

    /// The MapKit objects behind the tokens handed out in `AddressSuggestion`, replaced
    /// wholesale on every query so the table cannot grow without bound.
    private var completions: [String: MKLocalSearchCompletion] = [:]

    /// The caller waiting on the current `queryFragment`. At most one may exist, and it must
    /// be resumed exactly once — resuming twice traps.
    private var pending: CheckedContinuation<[AddressSuggestion], Never>?

    /// Bumped every time a new continuation is installed, so a cancellation handler that
    /// fires after the query it belongs to has already been superseded (H-15) can tell and
    /// leave the new one alone — `withTaskCancellationHandler`'s `onCancel` runs on an
    /// arbitrary executor and has to hop to the main actor before it can touch `pending`,
    /// and by the time it lands a newer query may have already taken that continuation's
    /// place.
    private var generation = 0

    private var activeSearch: MKLocalSearch?

    override init() {
        super.init()
        completer.delegate = self
        // All three are set before the first `queryFragment`, because assigning any of them
        // restarts whatever query MapKit has in flight.
        completer.region = VigoSearchRegion.region
        completer.regionPriority = .required
        // `.query` completions are search *terms* ("farmacias"): they resolve to a list, not
        // to a point, so there is nothing to hand the planner. They are included by default,
        // hence the explicit set.
        completer.resultTypes = [.address, .pointOfInterest]
    }

    // MARK: - Suggestions

    /// Why a continuation and not an `AsyncStream`: the completer emits refinements, several
    /// `completerDidUpdateResults` calls for one fragment. A stream would model that
    /// faithfully but then something above would have to decide which emission belongs to
    /// which query and when to stop listening — state we would have to invent. Debounce
    /// already collapses keystrokes, so "the best answer so far, shortly after you stopped
    /// typing" maps one-to-one onto a single `await`. Later refinements really are dropped
    /// — `completeResults()` below only acts while a continuation is still waiting for one,
    /// so a refinement that lands after that continuation has already been resumed touches
    /// nothing (H-13/H-14: this used to replace `completions` unconditionally, so a
    /// refinement arriving after the resume could invalidate the very tokens just handed to
    /// the caller — a suggestion visible on screen would resolve to "not found").
    func suggestions(for query: String) async -> [AddressSuggestion] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= Self.minimumQueryLength else {
            cancelPending()
            return []
        }

        generation += 1
        let mine = generation
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<[AddressSuggestion], Never>) in
                // A previous query may still be waiting. Retire it before taking its place,
                // so that "at most one pending continuation" holds and its caller does not
                // hang forever.
                resumePending(with: [])
                pending = continuation
                completer.queryFragment = trimmed
            }
        } onCancel: {
            // The pending slot is main-actor state, so cancellation cannot resume it from
            // here. Hop, and let `resumePending` decide whether anything is left to resume
            // — guarded by `generation` so this stale hop cannot cancel a *newer* query that
            // has since taken the pending slot (H-15).
            Task { @MainActor in
                guard self.generation == mine else { return }
                self.cancelPending()
            }
        }
    }

    private func resumePending(with suggestions: [AddressSuggestion]) {
        guard let continuation = pending else { return }
        pending = nil
        continuation.resume(returning: suggestions)
    }

    private func cancelPending() {
        completer.cancel()
        resumePending(with: [])
    }

    /// Keeps MapKit's completion objects on the main actor and resumes the continuation with
    /// only the small, `Sendable` values the caller needs. Passing MapKit classes through a
    /// continuation is both unnecessary and rejected by strict concurrency.
    private func completeResults() {
        // Nothing is waiting: either the answer already went out and this is a late
        // refinement, or the query was cancelled. Touching `completions` here would
        // invalidate tokens a caller may already be resolving (H-13).
        guard pending != nil else { return }

        // MapKit's order is its relevance ranking, so keep it rather than round-tripping
        // through a dictionary and showing a different list on every keystroke. Deduplicated
        // by content (H-19's id): two completions that render identically would otherwise
        // collide in `completions` and in `ForEach`, keeping the first — MapKit's own best
        // guess — matches how the ranking already works everywhere else here.
        var seen = Set<String>()
        var suggestions: [AddressSuggestion] = []
        var tokened: [(String, MKLocalSearchCompletion)] = []
        for completion in completer.results {
            let suggestion = AddressSuggestion(title: completion.title, subtitle: completion.subtitle)
            guard seen.insert(suggestion.id).inserted else { continue }
            suggestions.append(suggestion)
            tokened.append((suggestion.id, completion))
        }
        completions = Dictionary(uniqueKeysWithValues: tokened)
        resumePending(with: suggestions)
    }

    // MARK: - Completer delegate

    // `MainActor.assumeIsolated` rather than the `Task { @MainActor in }` hop `LocationProvider`
    // uses: here the order between "results arrived" and "the next query started" matters, and
    // a deferred task could resume a continuation that already belongs to the next query.
    //
    // It is an assertion about MapKit's threading, which is documented as main-thread. Were a
    // future SDK to call these off-main it would trap rather than misbehave — the right
    // failure. The fallback if that ever happens is checking `generation` inside the hop,
    // the same guard `suggestions(for:)`'s `onCancel` already uses for the same reason.

    nonisolated func completerDidUpdateResults(_: MKLocalSearchCompleter) {
        MainActor.assumeIsolated { self.completeResults() }
    }

    nonisolated func completer(_: MKLocalSearchCompleter, didFailWithError _: any Error) {
        // A failed completion is not worth an error banner: the user is mid-word and the next
        // keystroke will try again. An empty list next to the stop results is a better answer
        // than an alarm.
        MainActor.assumeIsolated { resumePending(with: []) }
    }

    // MARK: - Resolution

    func resolve(_ suggestion: AddressSuggestion) async throws -> Place {
        guard let completion = completions[suggestion.id] else { throw AddressSearchError.notFound }

        // Only one resolution in flight; a second tap replaces the first.
        activeSearch?.cancel()
        let request = MKLocalSearch.Request(completion: completion)
        request.region = VigoSearchRegion.region
        request.regionPriority = .required
        request.resultTypes = [.address, .pointOfInterest]
        let search = MKLocalSearch(request: request)
        activeSearch = search
        defer { if activeSearch === search { activeSearch = nil } }

        let response: MKLocalSearch.Response
        do {
            response = try await search.start()
        } catch {
            throw AddressSearchError.unavailable
        }

        // `MKMapItem` is not `Sendable`, but it never leaves this method — only `Coordinate`
        // and `String` cross out.
        guard let item = response.mapItems.first else { throw AddressSearchError.notFound }
        let point = item.placemark.coordinate
        let coordinate = Coordinate(latitude: point.latitude, longitude: point.longitude)

        // `regionPriority` is Apple's promise; this is ours. A destination outside the box
        // would only ever produce "no hay ninguna parada a menos de 800 m", several taps
        // later — better to say so now.
        guard VigoSearchRegion.contains(coordinate) else { throw AddressSearchError.outsideCoverage }

        return .coordinate(coordinate, label: item.name ?? suggestion.title)
    }
}
