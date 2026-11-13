import Foundation
import HealthKit

/// Unfiltered anchored pages: first run covers every accessible sample, not the last 30 days.
@MainActor
final class HealthHistoryReader {
    private let store = HKHealthStore()
    struct Page {
        let records: [HealthHistoryRecord]
        let deletedIDs: [String]
        let anchor: HKQueryAnchor
        let returnedCount: Int
    }
    static func sampleType(_ kind: HistoryKind) -> HKSampleType? {
        switch kind {
        case .sleep: return HKObjectType.categoryType(forIdentifier: .sleepAnalysis)
        case .workout: return HKObjectType.workoutType()
        case .steps: return HKQuantityType(.stepCount)
        case .distance: return HKQuantityType(.distanceWalkingRunning)
        case .activeEnergy: return HKQuantityType(.activeEnergyBurned)
        case .exercise: return HKQuantityType(.appleExerciseTime)
        case .heartRate: return HKQuantityType(.heartRate)
        case .activitySummary: return nil
        }
    }
    func page(kind: HistoryKind, anchor: HKQueryAnchor?) async throws -> Page {
        guard let type = Self.sampleType(kind) else { throw HealthFailure.unavailable }
        let result: ([HKSample], [HKDeletedObject], HKQueryAnchor) = try await withCheckedThrowingContinuation { continuation in
            let query = HKAnchoredObjectQuery(type: type, predicate: nil, anchor: anchor, limit: 200) { _, samples, deleted, next, error in
                if let error { continuation.resume(throwing: error); return }
                guard let next else { continuation.resume(throwing: HealthFailure.unavailable); return }
                continuation.resume(returning: (samples ?? [], deleted ?? [], next))
            }
            store.execute(query)
        }
        let deleted = Set(result.1.map { $0.uuid.uuidString })
        // A sample created and deleted within one batch must not be resurrected.
        let records = try result.0.filter { !deleted.contains($0.uuid.uuidString) }.map { try self.record($0, kind: kind) }
        return Page(records: records, deletedIDs: deleted.sorted(), anchor: result.2, returnedCount: result.0.count + result.1.count)
    }
    private func record(_ sample: HKSample, kind: HistoryKind) throws -> HealthHistoryRecord {
        let source = sample.sourceRevision.source
        let device = sample.device?.model ?? sample.sourceRevision.productType ?? ""
        let metadataZone = sample.metadata?[HKMetadataKeyTimeZone] as? String
        let zone = metadataZone.flatMap(TimeZone.init(identifier:)) ?? .current
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        var r = HealthHistoryRecord(id: sample.uuid.uuidString, kind: kind.rawValue,
            startedAt: sample.startDate, endedAt: sample.endDate,
            day: HealthSnapshot.dayString(sample.startDate, calendar: calendar), timeZone: zone.identifier,
            sourceID: String(source.bundleIdentifier.prefix(160)), sourceName: clean(source.name), device: clean(device),
            isAppleWatch: HealthSourceIdentity.isAppleWatch(productType: sample.sourceRevision.productType,
                model: sample.device?.model, manufacturer: sample.device?.manufacturer),
            unit: "", label: kind.title)
        if let s = sample as? HKCategorySample {
            r.category = s.value; r.unit = "min"; r.value = max(0, s.endDate.timeIntervalSince(s.startDate) / 60)
            switch HKCategoryValueSleepAnalysis(rawValue: s.value) {
            case .inBed: r.label = "卧床（不计入睡眠总时长）"
            case .awake: r.label = "清醒"
            case .asleepCore: r.label = "核心睡眠"
            case .asleepDeep: r.label = "深度睡眠"
            case .asleepREM: r.label = "REM 睡眠"
            case .asleepUnspecified: r.label = "睡眠（未分类）"
            default: r.label = "其他睡眠分类 \(s.value)"
            }
        } else if let s = sample as? HKWorkout {
            r.unit = "s"; r.value = s.duration
            r.label = workoutName(s.workoutActivityType)
            if let q = s.totalDistance { r.metrics["distanceMeters"] = q.doubleValue(for: .meter()) }
            if let q = s.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity() { r.metrics["activeEnergyKcal"] = q.doubleValue(for: .kilocalorie()) }
        } else if let s = sample as? HKQuantitySample {
            let unit: HKUnit
            switch kind {
            case .steps: unit = .count(); r.unit = "count"
            case .distance: unit = .meter(); r.unit = "m"
            case .activeEnergy: unit = .kilocalorie(); r.unit = "kcal"
            case .exercise: unit = .minute(); r.unit = "min"
            case .heartRate: unit = .count().unitDivided(by: .minute()); r.unit = "bpm"
            default: throw HealthFailure.unavailable
            }
            r.value = s.quantity.doubleValue(for: unit)
        } else { throw HealthFailure.unavailable }
        return r
    }
    func activitySummaries() async throws -> [HealthHistoryRecord] {
        let summaries: [HKActivitySummary] = try await withCheckedThrowingContinuation { continuation in
            let query = HKActivitySummaryQuery(predicate: nil) { _, rows, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: rows ?? []) }
            }
            store.execute(query)
        }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current
        return summaries.compactMap { s in
            guard let date = calendar.date(from: s.dateComponents(for: calendar)) else { return nil }
            let day = HealthSnapshot.dayString(date, calendar: calendar)
            var r = HealthHistoryRecord(id: day, kind: HistoryKind.activitySummary.rawValue,
                startedAt: date, endedAt: date, day: day, timeZone: calendar.timeZone.identifier,
                sourceID: "healthkit.activitySummary", sourceName: "Apple 健康活动摘要", device: "", isAppleWatch: false,
                unit: "day", label: s.activityMoveMode == .appleMoveTime ? "每日活动三环（活动时间模式）" : "每日活动三环")
            r.metrics = ["activeEnergyKcal": s.activeEnergyBurned.doubleValue(for: .kilocalorie()),
                "exerciseMinutes": s.appleExerciseTime.doubleValue(for: .minute()),
                "standHours": s.appleStandHours.doubleValue(for: .count()),
                "activeEnergyGoalKcal": s.activeEnergyBurnedGoal.doubleValue(for: .kilocalorie())]
            if let q = s.exerciseTimeGoal { r.metrics["exerciseGoalMinutes"] = q.doubleValue(for: .minute()) }
            if let q = s.standHoursGoal { r.metrics["standGoalHours"] = q.doubleValue(for: .count()) }
            if s.activityMoveMode == .appleMoveTime {
                r.metrics["moveMinutes"] = s.appleMoveTime.doubleValue(for: .minute())
                r.metrics["moveGoalMinutes"] = s.appleMoveTimeGoal.doubleValue(for: .minute())
            }
            r.metrics = r.metrics.filter { $0.value.isFinite && $0.value >= 0 }
            return r
        }.sorted { $0.startedAt < $1.startedAt }
    }
    private func clean(_ text: String) -> String { String(text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\0", with: "").prefix(160)) }
    private func workoutName(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .running: return "跑步"
        case .walking: return "步行"
        case .cycling: return "骑行"
        case .swimming: return "游泳"
        case .hiking: return "徒步"
        case .yoga: return "瑜伽"
        case .traditionalStrengthTraining, .functionalStrengthTraining: return "力量训练"
        case .badminton: return "羽毛球"
        case .basketball: return "篮球"
        default: return "体能训练（类型 \(type.rawValue)）"
        }
    }
}
