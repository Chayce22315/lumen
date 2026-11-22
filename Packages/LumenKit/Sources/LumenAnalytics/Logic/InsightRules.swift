import Foundation
import LumenFoundation
import LumenCore

/// One rule per insight kind. Each returns `nil` unless its evidence threshold is met.
///
/// Priorities (higher ranks first): growing workload 80, weekly trend 70–80 (stronger changes
/// higher), quiet period 75, streak 60–70 (longer higher), low consistency 55, clearing
/// workload 50, high consistency 45, best weekday 35, best hour 30, automation share 25,
/// balanced workload 15, middling consistency 10.
enum InsightRules {
    typealias Format = AnalyticsFormatting

    /// **streak** — the current run of days with at least one completion, when it is at least
    /// `minimumStreak` days long. A streak that ends yesterday is still alive (today is not over)
    /// and is reported with a nudge. Mentions a record only when an earlier, shorter streak exists.
    static func streak(_ context: InsightContext) -> InsightCandidate? {
        guard !context.completions.isEmpty,
              let streak = StreakCalculator.currentStreak(activeDays: context.completionDays, today: context.today),
              streak.length >= context.thresholds.minimumStreak else { return nil }
        let length = streak.length
        let unit = context.unit
        let endsToday = streak.end == context.today
        var detail = endsToday
            ? "You've completed at least one \(unit.singular) every day for \(length) days."
            : "You completed at least one \(unit.singular) on each of the \(length) days up to yesterday. Complete one today to keep it going."
        if let earliest = context.completionDays.min(), earliest < streak.start,
           let previousBest = StreakCalculator.longestStreak(
               activeDays: context.completionDays,
               in: DayRange(start: earliest, end: streak.start.adding(days: -1))
           ),
           length > previousBest.length {
            detail += " It's your longest streak so far."
        }
        return context.insight(
            .streak,
            parameters: ["start": streak.start.description, "length": String(length)],
            title: "\(length)-day streak",
            detail: detail,
            tone: endsToday ? .positive : .neutral,
            metric: Double(length),
            priority: 60 + Double(min(length, 30)) / 3
        )
    }

    /// **weeklyTrend** — completions this week so far versus the same days of last week. Needs
    /// at least `minimumTrendEvents` completions in *each* period and both periods fully
    /// recorded. Changes under `steadyTrendPercent` are "about the same".
    static func weeklyTrend(_ context: InsightContext) -> InsightCandidate? {
        guard !context.completions.isEmpty else { return nil }
        let thisWeek = DayRange.thisWeek(today: context.today, calendar: context.calendar)
        let lastWeek = thisWeek.shifted(byDays: -7)
        guard context.isFullyRecorded(lastWeek) else { return nil }
        let current = context.counts.total(names: context.completions, in: thisWeek)
        let previous = context.counts.total(names: context.completions, in: lastWeek)
        let minimum = context.thresholds.minimumTrendEvents
        guard current >= minimum, previous >= minimum,
              let change = Comparison(current: Double(current), previous: Double(previous)).percentChange else { return nil }

        let baseline = thisWeek.dayCount == 7 ? "last week" : "by this point last week"
        let opening = "You completed \(Format.count(current, context.unit)) this week"
        let title: String
        let detail: String
        let tone: Insight.Tone
        if abs(change) < context.thresholds.steadyTrendPercent || Format.roundedInt(change) == 0 {
            title = "Steady week"
            detail = "\(opening), about the same as \(baseline) (\(previous))."
            tone = .neutral
        } else if change > 0 {
            title = "Up \(Format.percent(change)) on last week"
            detail = "\(opening), \(Format.percent(change)) more than \(baseline)."
            tone = .positive
        } else {
            title = "Down \(Format.percent(change)) on last week"
            detail = "\(opening), \(Format.percent(change)) fewer than \(baseline) (\(previous))."
            tone = .attention
        }
        return context.insight(
            .weeklyTrend,
            parameters: ["week": thisWeek.start.description, "current": String(current), "previous": String(previous)],
            title: title,
            detail: detail,
            tone: tone,
            metric: change,
            priority: 70 + min(abs(change), 100) / 10
        )
    }

    /// **bestWeekday** — the weekday with the highest average completions per occurrence. Needs
    /// `minimumPatternDays` recorded days (two weeks by default, so every weekday occurs twice),
    /// `minimumWeekdayEvents` completions, a sole leader (no tie) and an average at least
    /// `minimumWeekdayLift` times the other days' average.
    static func bestWeekday(_ context: InsightContext) -> InsightCandidate? {
        guard !context.completions.isEmpty,
              let observed = context.observed(context.window),
              observed.dayCount >= context.thresholds.minimumPatternDays else { return nil }
        let values = context.counts.valuesByDay(names: context.completions, in: observed)
        let total = values.values.reduce(0, +)
        guard total >= Double(context.thresholds.minimumWeekdayEvents) else { return nil }
        let ranked = DistributionCalculator.rankedWeekdays(
            DistributionCalculator.weekdays(values, in: observed, calendar: context.calendar),
            calendar: context.calendar
        )
        guard let best = ranked.first, best.total > 0 else { return nil }
        if ranked.count > 1, ranked[1].average >= best.average { return nil }
        let otherDays = observed.dayCount - best.dayCount
        let otherAverage = otherDays > 0 ? (total - best.total) / Double(otherDays) : 0
        guard best.average >= otherAverage * context.thresholds.minimumWeekdayLift else { return nil }

        let name = best.weekday.fullName
        return context.insight(
            .bestWeekday,
            parameters: ["weekday": name.lowercased(), "days": String(observed.dayCount)],
            title: "\(name) is your best day",
            detail: "\(Format.span(observed.dayCount, "Over")) you completed \(Format.averageCount(best.average, context.unit)) on an average \(name), compared with \(Format.decimal(otherAverage)) on other days.",
            tone: .neutral,
            metric: best.average,
            priority: 35
        )
    }

    /// **bestHour** — the hour of day holding the most completion and focus events. Needs
    /// `minimumPatternDays` recorded days, `minimumHourEvents` events, a sole leader and at least
    /// `minimumHourShare` of all such events.
    static func bestHour(_ context: InsightContext) -> InsightCandidate? {
        let names = context.completions.union(context.signals.focusEvents)
        guard !names.isEmpty,
              let observed = context.observed(context.window),
              observed.dayCount >= context.thresholds.minimumPatternDays else { return nil }
        var totals: [Int: Double] = [:]
        for count in context.hourly where names.contains(count.name) {
            totals[count.hour, default: 0] += Double(count.count)
        }
        guard totals.values.reduce(0, +) >= Double(context.thresholds.minimumHourEvents) else { return nil }
        let ranked = DistributionCalculator.rankedHours(DistributionCalculator.hours(totals))
        guard let best = ranked.first, best.total > 0,
              best.share >= context.thresholds.minimumHourShare else { return nil }
        if ranked.count > 1, ranked[1].total >= best.total { return nil }

        let work = context.signals.focusEvents.isEmpty
            ? "your completed \(context.unit.plural)"
            : "your completions and focus activity"
        return context.insight(
            .bestHour,
            parameters: ["hour": String(best.hour), "days": String(observed.dayCount)],
            title: "Most productive around \(Format.hour(best.hour))",
            detail: "\(Format.percent(best.share * 100)) of \(work) \(Format.span(observed.dayCount, "over")) happened between \(Format.hour(best.hour)) and \(Format.hour(best.hour + 1)).",
            tone: .neutral,
            metric: best.share * 100,
            priority: 30
        )
    }

    /// **consistency** — share of the last `consistencyDays` days with at least one completion,
    /// counting only recorded days and needing `minimumPatternDays` of them. When today has no
    /// completion yet the period ends yesterday, so an unfinished day does not count against it.
    static func consistency(_ context: InsightContext) -> InsightCandidate? {
        guard !context.completions.isEmpty else { return nil }
        let includesToday = context.completionDays.contains(context.today)
        let end = includesToday ? context.today : context.today.adding(days: -1)
        guard let observed = context.observed(DayRange.lastDays(context.thresholds.consistencyDays, endingOn: end)),
              observed.dayCount >= context.thresholds.minimumPatternDays else { return nil }
        let active = context.completionDays.filter(observed.contains).count
        let share = DistributionCalculator.consistency(activeDays: context.completionDays, in: observed)
        let period = includesToday ? "of the last \(observed.dayCount) days" : "of the \(observed.dayCount) days before today"
        let detail = "You completed at least one \(context.unit.singular) on \(active) \(period)."
        let title: String
        let tone: Insight.Tone
        let priority: Double
        if share >= context.thresholds.highConsistency {
            (title, tone, priority) = ("Consistent rhythm", .positive, 45)
        } else if share <= context.thresholds.lowConsistency {
            (title, tone, priority) = ("An irregular rhythm", .attention, 55)
        } else {
            (title, tone, priority) = ("A mixed rhythm", .neutral, 10)
        }
        return context.insight(
            .consistency,
            parameters: ["active": String(active), "days": String(observed.dayCount), "end": observed.end.description],
            title: title,
            detail: detail,
            tone: tone,
            metric: share * 100,
            priority: priority
        )
    }

    /// **workloadBalance** — items created versus completed over the last `workloadDays` recorded
    /// days. Needs both kinds of events configured and `minimumWorkloadEvents` of them. Growing
    /// when created ≥ `workloadGrowthRatio` × completed; clearing when more were completed.
    static func workloadBalance(_ context: InsightContext) -> InsightCandidate? {
        let creations = context.signals.creationEvents
        guard !context.completions.isEmpty, !creations.isEmpty,
              let observed = context.observed(DayRange.lastDays(context.thresholds.workloadDays, endingOn: context.today)) else { return nil }
        let created = context.counts.total(names: creations, in: observed)
        let completed = context.counts.total(names: context.completions, in: observed)
        guard created + completed >= context.thresholds.minimumWorkloadEvents else { return nil }
        let span = Format.span(observed.dayCount, "in")
        let unit = context.unit
        let title: String
        let detail: String
        let tone: Insight.Tone
        let priority: Double
        if created > 0, Double(created) >= Double(completed) * context.thresholds.workloadGrowthRatio {
            title = "Your list is growing"
            detail = "You added \(Format.count(created, unit)) and completed \(completed) \(span)."
            (tone, priority) = (.attention, 80)
        } else if completed > created {
            title = "You're clearing your list"
            detail = "You completed \(Format.count(completed, unit)) and added \(created) \(span)."
            (tone, priority) = (.positive, 50)
        } else {
            title = "Keeping pace"
            detail = "You added \(Format.count(created, unit)) and completed \(completed) \(span)."
            (tone, priority) = (.neutral, 15)
        }
        return context.insight(
            .workloadBalance,
            parameters: ["added": String(created), "completed": String(completed), "days": String(observed.dayCount), "end": observed.end.description],
            title: title,
            detail: detail,
            tone: tone,
            metric: Double(created - completed),
            priority: priority
        )
    }

    /// **automationShare** — the share of created and completed items whose events were caused
    /// by automations over the last `automationDays` recorded days. Needs
    /// `minimumAutomationEvents` items and at least `minimumAutomationShare` automated.
    static func automationShare(_ context: InsightContext) -> InsightCandidate? {
        let creations = context.signals.creationEvents
        let names = context.completions.union(creations)
        guard !names.isEmpty,
              let observed = context.observed(DayRange.lastDays(context.thresholds.automationDays, endingOn: context.today)) else { return nil }
        let total = context.counts.total(names: names, in: observed)
        let automated = context.counts.total(names: names, in: observed, actors: [.automation])
        guard total >= context.thresholds.minimumAutomationEvents, automated > 0 else { return nil }
        let share = Double(automated) / Double(total)
        guard share >= context.thresholds.minimumAutomationShare else { return nil }
        let verb: String
        switch (context.completions.isEmpty, creations.isEmpty) {
        case (false, false): verb = "created or completed"
        case (false, true): verb = "completed"
        default: verb = "created"
        }
        return context.insight(
            .automationShare,
            parameters: ["automated": String(automated), "total": String(total), "days": String(observed.dayCount), "end": observed.end.description],
            title: "Automations at work",
            detail: "Automations \(verb) \(automated) of \(Format.count(total, context.unit)) (\(Format.percent(share * 100))) \(Format.span(observed.dayCount, "in")).",
            tone: .positive,
            metric: share * 100,
            priority: 25
        )
    }

    /// **quietPeriod** — at least `quietPeriodDays` full days (today excluded, it is not over)
    /// without a recorded completion, for users with at least `minimumQuietPeriodHistory` days
    /// of completions. The text says "recorded" because analytics cannot know about work done
    /// while collection was off.
    static func quietPeriod(_ context: InsightContext) -> InsightCandidate? {
        guard !context.completions.isEmpty,
              context.completionDays.count >= context.thresholds.minimumQuietPeriodHistory,
              let last = context.completionDays.max() else { return nil }
        let daysSince = context.today.days(since: last)
        guard daysSince - 1 >= context.thresholds.quietPeriodDays else { return nil }
        return context.insight(
            .quietPeriod,
            parameters: ["last": last.description],
            title: "Quiet stretch",
            detail: "No completed \(context.unit.plural) recorded since \(Format.shortDay(last)), \(Format.days(daysSince)) ago.",
            tone: .attention,
            metric: Double(daysSince),
            priority: 75
        )
    }
}
