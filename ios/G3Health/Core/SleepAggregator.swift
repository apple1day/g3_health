import Foundation

/// Independent of HealthKit so overlapping samples, source selection and DST windows can be tested.
enum SleepStage: Int, Sendable, Hashable {
    case inBed, awake, unspecified, core, rem, deep
    var isAsleep: Bool { self != .inBed && self != .awake }
    var precedence: Int {
        switch self {
        case .inBed: return 0
        case .unspecified: return 1
        case .awake: return 2
        case .core: return 3
        case .rem: return 4
        case .deep: return 5
        }
    }
}

struct SleepSegment: Sendable {
    var start: Date
    var end: Date
    var stage: SleepStage
    var sourceID: String
    var sourceName: String
    var isAppleWatch: Bool
}

struct SleepWindow {
    let start: Date
    let end: Date

    /// The overnight period belonging to today's morning: yesterday noon → today noon.
    /// Query only as far as now if today noon is still in the future.
    static func overnight(now: Date, calendar: Calendar = .current) -> Self {
        let day = calendar.startOfDay(for: now)
        let todayNoon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: day) ?? day
        let yesterdayNoon = calendar.date(byAdding: .day, value: -1, to: todayNoon) ?? todayNoon.addingTimeInterval(-86400)
        return Self(start: yesterdayNoon, end: min(now, todayNoon))
    }
}

struct SleepAggregator {
    static func summarize(_ samples: [SleepSegment], window: SleepWindow) -> SleepSummary {
        let clipped = samples.compactMap { sample -> SleepSegment? in
            var sample = sample
            sample.start = max(sample.start, window.start)
            sample.end = min(sample.end, window.end)
            return sample.end > sample.start && sample.stage != .inBed ? sample : nil
        }
        let groups = Dictionary(grouping: clipped, by: \.sourceID)
        // One source per night. A watch source with real sleep is preferred over third-party copies.
        let candidates = groups.values.filter { $0.contains { $0.stage.isAsleep } }
        let chosen = candidates.sorted { a, b in
            let aWatch = a.contains { $0.isAppleWatch }, bWatch = b.contains { $0.isAppleWatch }
            if aWatch != bWatch { return aWatch }
            let aDuration = unionDuration(a.filter { $0.stage.isAsleep })
            let bDuration = unionDuration(b.filter { $0.stage.isAsleep })
            if aDuration != bDuration { return aDuration > bDuration }
            return (a.first?.sourceID ?? "") < (b.first?.sourceID ?? "")
        }.first ?? []
        let asleep = chosen.filter { $0.stage.isAsleep }
        guard let start = asleep.map(\.start).min(), let end = asleep.map(\.end).max(), end > start else {
            return SleepSummary()
        }
        let relevant = chosen.filter { $0.end > start && $0.start < end }
        let boundaries = Set(relevant.flatMap { [max(start, $0.start), min(end, $0.end)] }).sorted()
        var resolved: [(start: Date, end: Date, stage: SleepStage)] = []
        for (left, right) in zip(boundaries, boundaries.dropFirst()) where right > left {
            let active = relevant.filter { $0.start < right && $0.end > left }
            // Detailed sleep AND awake override legacy broad asleep-unspecified intervals.
            // If malformed stage overlaps exist, use a stable priority rather than inflating totals.
            guard let selected = active.map(\.stage).max(by: { $0.precedence < $1.precedence }) else { continue }
            resolved.append((left, right, selected))
        }
        let asleepResolved = resolved.filter { $0.stage.isAsleep }
        guard let sleepStart = asleepResolved.first?.start, let sleepEnd = asleepResolved.last?.end else {
            return SleepSummary()
        }
        var seconds: [SleepStage: Double] = [:]
        for item in resolved where item.start >= sleepStart && item.end <= sleepEnd {
            seconds[item.stage, default: 0] += item.end.timeIntervalSince(item.start)
        }
        let asleepSeconds = seconds.filter { $0.key.isAsleep }.values.reduce(0, +)
        guard asleepSeconds > 0 else { return SleepSummary() }
        let hasStages = chosen.contains { [.core, .rem, .deep].contains($0.stage) }
        let knowsAwake = hasStages || chosen.contains { $0.stage == .awake }
        return SleepSummary(status: .ok, startedAt: sleepStart, endedAt: sleepEnd,
            totalMinutes: asleepSeconds / 60,
            coreMinutes: hasStages ? seconds[.core, default: 0] / 60 : nil,
            deepMinutes: hasStages ? seconds[.deep, default: 0] / 60 : nil,
            remMinutes: hasStages ? seconds[.rem, default: 0] / 60 : nil,
            unspecifiedMinutes: seconds[.unspecified, default: 0] / 60,
            awakeMinutes: knowsAwake ? seconds[.awake, default: 0] / 60 : nil,
            sourceName: chosen.first?.sourceName)
    }

    private static func unionDuration(_ segments: [SleepSegment]) -> Double {
        let sorted = segments.sorted { $0.start < $1.start }
        guard let first = sorted.first else { return 0 }
        var start = first.start, end = first.end, total: Double = 0
        for item in sorted.dropFirst() {
            if item.start <= end { end = max(end, item.end) }
            else { total += end.timeIntervalSince(start); start = item.start; end = item.end }
        }
        return total + end.timeIntervalSince(start)
    }
}
