import Foundation

/// The one place a `PlanOutcome` becomes something to show a person.
///
/// Before this existed the eight outcomes were translated **twice**, in `PlannerView` and in
/// `SavedJourneyPlanModel`, and the two had already drifted: the saved-journey copy dropped
/// the feed's coverage dates from `outsideFeedWindow` ("no cubren esta fecha") and the walk
/// radius from the two "no stops nearby" cases. Those are the only facts in those messages
/// that tell the user what to do next, so the drift was not cosmetic. The map screen would
/// have been the third copy.
///
/// This lives in `VigoCore`, next to the type it describes, for two reasons. `ServiceDate`
/// already carries `humanReadable` here, so the package is not string-free to begin with; and
/// a pure function of an outcome is exactly the kind of thing `swift test` can check on the
/// Mac, which is where this project's verification happens now.
public enum PlanOutcomeMessage {

    /// Only changes the wording of the two "no stops nearby" cases, where naming *which*
    /// endpoint is at fault is the difference between an actionable message and a shrug.
    public enum Context: Sendable {
        /// The planner tab and the map, where the user just picked the two ends.
        case interactive
        /// A saved journey, where the ends came from something stored earlier — worth
        /// saying, because the fix is to edit the saved journey, not the current query.
        case savedJourney
    }

    /// The message for an outcome that is not a journey, or `nil` when the outcome *is* one.
    ///
    /// `nil` is a deliberate part of the contract: `.journeys` and `.walkOnly` are answers,
    /// not failures, and a caller that renders this string unconditionally would be
    /// apologising for a successful search.
    public static func failure(_ outcome: PlanOutcome, context: Context = .interactive) -> String? {
        switch outcome {
        case .journeys, .walkOnly:
            return nil

        case .noStopsNearOrigin(let radius):
            return "No hay ninguna parada a menos de \(metres(radius)) m del \(origin(context))."

        case .noStopsNearDestination(let radius):
            return "No hay ninguna parada a menos de \(metres(radius)) m del \(destination(context))."

        case .outsideFeedWindow(let window):
            // The dates are the whole message. "No data for that date" without saying which
            // dates *do* work leaves the user with nothing to act on.
            //
            // Since A2 this outcome is much rarer and means something narrower than it used
            // to: not "the feed is a week long" — days past the window are estimated now —
            // but "not even an estimate is possible here", i.e. a date in the past or far
            // enough ahead that reusing an old week would be fiction. The wording says
            // "confirmados" because dates outside the window are no longer simply refused.
            return """
                No tengo datos confirmados para esa fecha, ni forma de estimarla. Los \
                horarios importados cubren del \(window.lowerBound.humanReadable) al \
                \(window.upperBound.humanReadable).
                """

        case .noServiceOnDay(let day):
            return "No hay servicio programado el \(day.humanReadable)."

        case .noJourneyFound(let horizon):
            return notFound(horizon: horizon)

        case .noData:
            return "Todavía no se han importado los datos del Concello."
        }
    }

    /// Why the only alternative is a walk. Not a failure — the walk is a real answer — but
    /// it needs saying, or it reads like the search gave up. Since H-19, `.walkOnly` fires
    /// exactly when no bus reaches the destination at all — a walk that merely arrives
    /// before a real bus alternative is shown alongside it in `.journeys` instead, so this
    /// explanation no longer has to speak of buses that were merely slower.
    public static let walkOnlyExplanation =
        "Ningún autobús llega hasta aquí."

    /// The sentence that has to accompany a projected timetable (A2), or `nil` when the
    /// schedule is the operator's own data.
    ///
    /// Returning `nil` for `.observed` is the same contract as `failure`: a caller that shows
    /// this unconditionally would be hedging an answer that needs no hedge, and a warning
    /// that appears every time stops being read.
    ///
    /// The template's date is in the text on purpose. "Estimated" alone is not actionable —
    /// it tells the user to distrust the answer without telling them how much. Naming the day
    /// the times actually come from lets them judge it: a Tuesday borrowed from last Tuesday
    /// is worth acting on, the same Tuesday borrowed from two months ago is worth checking.
    public static func estimateNotice(_ schedule: ServiceDaySource) -> String? {
        switch schedule {
        case .observed:
            return nil
        case .projected(let template):
            return """
                Horario estimado: los datos del Concello no llegan a esta fecha, así que se                 han reutilizado los del \(template.humanReadable). Confírmalo antes de contar                 con él.
                """
        }
    }

    // MARK: - Detalles

    private static func origin(_ context: Context) -> String {
        context == .savedJourney ? "origen guardado" : "origen"
    }

    private static func destination(_ context: Context) -> String {
        context == .savedJourney ? "destino guardado" : "destino"
    }

    private static func metres(_ radius: Double) -> Int {
        Int(radius.rounded())
    }

    /// Wording for "found nothing", scaled to how far the search actually looked.
    ///
    /// A horizon under an hour must not become "en las próximas 0 horas": callers use a zero
    /// horizon to mean "the search came back empty right now" — `MapNavigationState` does
    /// exactly that when it folds an empty `.journeys` list — and rounding that into a
    /// sentence about hours would be nonsense the user cannot act on.
    private static func notFound(horizon: TimeInterval) -> String {
        guard horizon >= 3_600 else { return "No he encontrado ninguna ruta ahora mismo." }
        let hours = Int((horizon / 3_600).rounded())
        return hours == 1
            ? "No he encontrado ninguna ruta en la próxima hora."
            : "No he encontrado ninguna ruta en las próximas \(hours) horas."
    }
}
