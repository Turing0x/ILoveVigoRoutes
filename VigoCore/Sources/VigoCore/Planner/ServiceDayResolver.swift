import Foundation

/// Where a day's timetable came from.
public enum ServiceDaySource: Sendable, Hashable {
    /// The feed contains this exact date. The answer is the operator's own data.
    case observed
    /// The feed does not reach this date, so the services of `template` — the most recent
    /// day of the same kind that it does reach — were reused. An estimate, and everything
    /// downstream is obliged to say so.
    case projected(template: ServiceDate)

    public var isProjected: Bool {
        if case .projected = self { return true }
        return false
    }
}

/// A day the planner can actually answer for, and how honestly.
public struct ResolvedServiceDay: Sendable, Hashable {
    /// The day that was asked about.
    public let date: ServiceDate
    /// The day whose `service_id` set is used. Equal to `date` when observed.
    public let template: ServiceDate
    public let source: ServiceDaySource

    public var isProjected: Bool { source.isProjected }

    public init(date: ServiceDate, template: ServiceDate, source: ServiceDaySource) {
        self.date = date; self.template = template; self.source = source
    }
}

/// Decides which day's services answer for a day the feed does not contain.
///
/// **The problem.** Vitrasa's GTFS is a rolling seven-day window: `calendar.txt` is empty and
/// every service is an explicit `calendar_dates` row, 702 of them covering exactly seven
/// dates. Anything past that got `.outsideFeedWindow` — not a bad answer, *no* answer. "How
/// do I get to the airport on the 20th?" was unanswerable. The Concello's own planner answers
/// ninety-four days out (`AUDITORIA-MOTOR-VS-CONCELLO.md` §2.8), so the bar is not theoretical.
///
/// **What is projected, and what is not.** Only the *set of `service_id`s* that run on a day.
/// The trips those services own, and their stop times, are already in the database — this
/// week's feed brought them. Nothing is duplicated, no schema changes, no storage cost. That
/// realisation is what made versioning the feed (the original A1) unnecessary.
///
/// **Why a resolver and not a query.** Every rule here is a judgement about honesty rather
/// than a fact about SQL, and each one is easy to get subtly wrong in a way no end-to-end test
/// would surface. Out here they are a pure function of `(observed days, holidays, date)` and
/// `swift test` can state each one directly.
public struct ServiceDayResolver: Sendable {

    /// The days inside the feed's window that actually have service. Not the window itself:
    /// a date the feed nominally covers but for which every service was cancelled is no use
    /// as a template, and treating it as one would project a day with no buses onto every
    /// future day of that weekday.
    public let observedDays: Set<ServiceDate>
    public let holidays: HolidayCalendar
    public let calendar: Calendar
    /// How far past the last observed day a projection may reach.
    ///
    /// A bound on honesty, not on cost. A projected timetable three months out is fiction
    /// dressed as data: the operator will have changed it, and the further out it goes the
    /// more certainly. Past this the planner says it does not know, which is a true statement
    /// and the one this project's README insists on.
    public let maxProjectionDays: Int

    public init(observedDays: Set<ServiceDate>, holidays: HolidayCalendar,
                calendar: Calendar, maxProjectionDays: Int) {
        self.observedDays = observedDays
        self.holidays = holidays
        self.calendar = calendar
        self.maxProjectionDays = maxProjectionDays
    }

    /// Which day's services answer for `date`, or `nil` when the honest answer is "I do not
    /// know".
    ///
    /// The rules, in order, and the reason for each:
    ///
    /// 1. **An observed day is never projected.** Real data always wins, and this is what
    ///    guarantees that a mistake in the holiday calendar can never corrupt a firm answer.
    /// 2. **The past is refused.** Nobody plans a journey for last Tuesday, and projecting
    ///    backwards would answer a question about history with a guess about it.
    /// 3. **Beyond `maxProjectionDays`, refused.** See above.
    /// 4. **A year the holiday calendar does not cover is refused.** Without it there is no
    ///    way to tell an ordinary Tuesday from Christmas, and projecting blind is exactly the
    ///    silent wrong answer this refuses to give.
    /// 5. **A holiday is projected from a Sunday**, because that is the timetable that runs.
    /// 6. **A holiday is never used as a template** for an ordinary day. This is the
    ///    direction that is easy to miss: a captured week containing the 12th of October
    ///    would otherwise propagate holiday service to every Monday for two months.
    public func resolve(_ date: ServiceDate) -> ResolvedServiceDay? {
        if observedDays.contains(date) {
            return ResolvedServiceDay(date: date, template: date, source: .observed)
        }
        guard let latestObserved = observedDays.max() else { return nil }

        // Rule 2. A date inside the window but with no service is a real "no service today",
        // not a gap to paper over — `JourneyPlanner` already has `.noServiceOnDay` for it,
        // and reaching here at all means the date is outside what the feed describes.
        guard date > latestObserved else { return nil }

        // Rule 3.
        guard let horizon = latestObserved.adding(days: maxProjectionDays, calendar: calendar),
              date <= horizon else { return nil }

        // Rule 4.
        guard holidays.covers(date) else { return nil }

        // Rules 5 and 6.
        let sundayIndex = 6
        let wanted: Int
        if holidays.isHoliday(date) {
            wanted = sundayIndex
        } else {
            guard let weekday = date.gtfsWeekdayIndex(calendar: calendar) else { return nil }
            wanted = weekday
        }

        let matching = observedDays
            .filter { $0.gtfsWeekdayIndex(calendar: calendar) == wanted }
            .sorted()
        guard !matching.isEmpty else { return nil }

        // Prefer a template that is not itself a holiday. A Sunday that happens to be a
        // holiday is still a perfectly good Sunday, so the fallback keeps it rather than
        // giving up — but an ordinary weekday that fell on a holiday is exactly the template
        // rule 6 exists to avoid.
        let template = matching.last { !holidays.isHoliday($0) } ?? matching.last!
        return ResolvedServiceDay(date: date, template: template,
                                  source: .projected(template: template))
    }
}
