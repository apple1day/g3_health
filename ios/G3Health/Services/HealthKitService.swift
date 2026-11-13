import Foundation
import HealthKit

@MainActor
final class HealthKitService {
    private let store = HKHealthStore()
    private var observers: [HKObserverQuery] = []
    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private let quantities: [HKQuantityTypeIdentifier] = [
        .stepCount, .distanceWalkingRunning, .activeEnergyBurned, .appleExerciseTime, .heartRate
    ]
    var readTypes: Set<HKObjectType> {
        var result: Set<HKObjectType> = [HKObjectType.workoutType(), HKObjectType.activitySummaryType()]
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { result.insert(sleep) }
        quantities.compactMap { HKQuantityType.quantityType(forIdentifier: $0) }.forEach { result.insert($0) }
        return result
    }

    func requestReadAccess() async throws {
        guard isAvailable else { throw HealthFailure.unavailable }
        try await store.requestAuthorization(toShare: [], read: readTypes)
        // Successful presentation is NOT confirmation that any read permission was granted.
    }

    func snapshot(now: Date = Date(), calendar: Calendar = .current) async -> HealthSnapshot {
        var snapshot = HealthSnapshot.empty(now: now, calendar: calendar)
        guard isAvailable else {
            snapshot.sleep.status = .error; snapshot.activity.status = .error
            snapshot.heartRate.status = .error; snapshot.workout.status = .error
            snapshot.warnings = ["此设备无法使用 Apple 健康；请用 iPhone 真机测试。"]
            return snapshot
        }
        do { snapshot.sleep = try await sleep(now: now, calendar: calendar) }
        catch { snapshot.sleep.status = .error; snapshot.warnings.append("睡眠读取暂未完成，请解锁 iPhone 后重试。") }
        let (activity, activityWarnings) = await activity(now: now, calendar: calendar)
        snapshot.activity = activity
        snapshot.warnings += activityWarnings
        do { snapshot.heartRate = try await heartRate(now: now) }
        catch { snapshot.heartRate.status = .error; snapshot.warnings.append("心率读取暂未完成，请稍后重试。") }
        do { snapshot.workout = try await workout(now: now, calendar: calendar) }
        catch { snapshot.workout.status = .error; snapshot.warnings.append("最近运动读取暂未完成，请稍后重试。") }
        // Keep the query start instant aligned with its calendar-day window across midnight.
        snapshot.generatedAt = now
        return snapshot
    }

    private func sleep(now: Date, calendar: Calendar) async throws -> SleepSummary {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return SleepSummary() }
        let window = SleepWindow.overnight(now: now, calendar: calendar)
        let predicate = HKQuery.predicateForSamples(withStart: window.start, end: window.end)
        let samples = try await querySamples(type: type, predicate: predicate)
        let segments = samples.compactMap { sample -> SleepSegment? in
            guard let sample = sample as? HKCategorySample else { return nil }
            let stage: SleepStage
            switch HKCategoryValueSleepAnalysis(rawValue: sample.value) {
            case .inBed: stage = .inBed
            case .awake: stage = .awake
            case .asleepCore: stage = .core
            case .asleepDeep: stage = .deep
            case .asleepREM: stage = .rem
            case .asleepUnspecified: stage = .unspecified
            default: return nil
            }
            let source = sample.sourceRevision.source
            let product = sample.sourceRevision.productType ?? ""
            let watch = HealthSourceIdentity.isAppleWatch(productType: product,
                model: sample.device?.model, manufacturer: sample.device?.manufacturer)
            let sourceID = source.bundleIdentifier + "|" + (sample.device?.localIdentifier ?? product)
            return SleepSegment(start: sample.startDate, end: sample.endDate, stage: stage,
                sourceID: sourceID, sourceName: watch ? "Apple Watch" : String(source.name.prefix(160)), isAppleWatch: watch)
        }
        return SleepAggregator.summarize(segments, window: window)
    }

    private func activity(now: Date, calendar: Calendar) async -> (ActivitySummary, [String]) {
        var value = ActivitySummary()
        var warnings: [String] = []
        let start = calendar.startOfDay(for: now)
        do { value.steps = try await sum(.stepCount, unit: .count(), start: start, end: now) }
        catch { warnings.append("今日步数暂未读取。") }
        do { value.distanceMeters = try await sum(.distanceWalkingRunning, unit: .meter(), start: start, end: now) }
        catch { warnings.append("今日步行跑步距离暂未读取。") }
        do {
            if let summary = try await activityRingSummary(now: now, calendar: calendar) {
                value.activeEnergyKcal = finite(summary.activeEnergyBurned.doubleValue(for: .kilocalorie()))
                value.exerciseMinutes = finite(summary.appleExerciseTime.doubleValue(for: .minute()))
                value.standHours = finite(summary.appleStandHours.doubleValue(for: .count()))
                value.activeEnergyGoalKcal = positive(summary.activeEnergyBurnedGoal.doubleValue(for: .kilocalorie()))
                value.exerciseGoalMinutes = summary.exerciseTimeGoal.flatMap { positive($0.doubleValue(for: .minute())) }
                value.standGoalHours = summary.standHoursGoal.flatMap { positive($0.doubleValue(for: .count())) }
                switch summary.activityMoveMode {
                case .activeEnergy: value.moveMode = .energy
                case .appleMoveTime:
                    value.moveMode = .time
                    value.moveMinutes = finite(summary.appleMoveTime.doubleValue(for: .minute()))
                    value.moveGoalMinutes = positive(summary.appleMoveTimeGoal.doubleValue(for: .minute()))
                @unknown default: value.moveMode = .unknown
                }
            } else {
                value.activeEnergyKcal = try await sum(.activeEnergyBurned, unit: .kilocalorie(), start: start, end: now)
                value.exerciseMinutes = try await sum(.appleExerciseTime, unit: .minute(), start: start, end: now)
            }
        } catch { warnings.append("活动三环暂未读取；已读取的其他活动数据仍会显示。") }
        let available = [value.steps, value.distanceMeters, value.activeEnergyKcal, value.exerciseMinutes, value.standHours]
            .contains { $0 != nil }
        value.status = warnings.isEmpty ? (available ? .ok : .empty) : .error
        return (value, warnings)
    }

    private func heartRate(now: Date) async throws -> HeartRateSummary {
        let type = HKQuantityType(.heartRate)
        let predicate = HKQuery.predicateForSamples(withStart: now.addingTimeInterval(-30 * 86400), end: now, options: .strictEndDate)
        let samples = try await querySamples(type: type, predicate: predicate, limit: 1,
            sort: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)])
        guard let sample = samples.first as? HKQuantitySample,
              let bpm = positive(sample.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute())))
        else { return HeartRateSummary() }
        return HeartRateSummary(status: .ok, bpm: bpm, measuredAt: sample.endDate)
    }

    private func workout(now: Date, calendar: Calendar) async throws -> WorkoutSummary {
        let window = RecentWorkoutWindow(now: now, calendar: calendar)
        // Filter completed workouts by end, including an activity that crossed the cutoff.
        let time = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "%K >= %@", HKPredicateKeyPathEndDate, window.start as NSDate),
            NSPredicate(format: "%K <= %@", HKPredicateKeyPathEndDate, window.end as NSDate)
        ])
        let samples = try await querySamples(type: HKObjectType.workoutType(), predicate: time, limit: 1,
            sort: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)])
        guard let item = samples.first as? HKWorkout else { return WorkoutSummary() }
        let energy = item.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie())
        return WorkoutSummary(status: .ok, kind: workoutName(item), startedAt: item.startDate, endedAt: item.endDate,
            durationSeconds: finite(item.duration),
            distanceMeters: item.totalDistance.flatMap { finite($0.doubleValue(for: .meter())) },
            activeEnergyKcal: energy.flatMap(finite))
    }

    private func workoutName(_ workout: HKWorkout) -> String {
        let indoor = (workout.metadata?[HKMetadataKeyIndoorWorkout] as? Bool) == true
        switch workout.workoutActivityType {
        case .running: return indoor ? "室内跑步" : "跑步"
        case .walking: return indoor ? "室内步行" : "步行"
        case .cycling: return indoor ? "室内骑行" : "骑行"
        case .swimming: return "游泳"
        case .hiking: return "徒步"
        case .yoga: return "瑜伽"
        case .traditionalStrengthTraining: return "传统力量训练"
        case .functionalStrengthTraining: return "功能性力量训练"
        case .highIntensityIntervalTraining: return "高强度间歇训练"
        case .elliptical: return "椭圆机"
        case .rowing: return "划船"
        case .dance, .cardioDance: return "舞蹈"
        case .pilates: return "普拉提"
        case .badminton: return "羽毛球"
        case .basketball: return "篮球"
        case .soccer: return "足球"
        case .tennis: return "网球"
        case .cooldown: return "放松整理"
        default: return "体能训练"
        }
    }

    private func querySamples(type: HKSampleType, predicate: NSPredicate?, limit: Int = HKObjectQueryNoLimit,
                              sort: [NSSortDescriptor]? = nil) async throws -> [HKSample] {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: limit, sortDescriptors: sort) { _, samples, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: samples ?? []) }
            }
            store.execute(query)
        }
    }

    private func sum(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit, start: Date, end: Date) async throws -> Double? {
        let type = HKQuantityType(identifier)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let quantity: HKQuantity? = try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate, options: .cumulativeSum) { _, result, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: result?.sumQuantity()) }
            }
            store.execute(query)
        }
        return quantity.flatMap { finite($0.doubleValue(for: unit)) }
    }

    private func activityRingSummary(now: Date, calendar: Calendar) async throws -> HKActivitySummary? {
        var day = calendar.dateComponents([.year, .month, .day], from: now)
        day.calendar = calendar
        let predicate = HKQuery.predicateForActivitySummary(with: day)
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKActivitySummaryQuery(predicate: predicate) { _, summaries, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: summaries?.first) }
            }
            store.execute(query)
        }
    }

    /// Install observers synchronously during launch; processing always calls the delivery completion.
    func installObservers(onChange: @escaping @MainActor () async -> Void) {
        guard observers.isEmpty, isAvailable else { return }
        let types: [HKSampleType] = [HKQuantityType(.stepCount), HKQuantityType(.heartRate),
                                    HKQuantityType(.activeEnergyBurned), HKObjectType.workoutType()]
            + [HKObjectType.categoryType(forIdentifier: .sleepAnalysis)].compactMap { $0 }
        for type in types {
            let query = HKObserverQuery(sampleType: type, predicate: nil) { _, completion, error in
                guard error == nil else { completion(); return }
                Task { @MainActor in
                    await onChange()
                    completion()
                }
            }
            observers.append(query)
            store.execute(query)
        }
    }

    func enableBackgroundDelivery() async throws {
        guard isAvailable else { throw HealthFailure.unavailable }
        let types: [HKObjectType] = [HKQuantityType(.stepCount), HKQuantityType(.heartRate),
                                   HKQuantityType(.activeEnergyBurned), HKObjectType.workoutType()]
            + [HKObjectType.categoryType(forIdentifier: .sleepAnalysis)].compactMap { $0 }
        for type in types {
            try await store.enableBackgroundDelivery(for: type, frequency: .hourly)
        }
    }

    func disableBackgroundDelivery() async {
        observers.forEach(store.stop)
        observers.removeAll()
        try? await store.disableAllBackgroundDelivery()
    }

    private func finite(_ value: Double) -> Double? { value.isFinite && value >= 0 ? value : nil }
    private func positive(_ value: Double) -> Double? { value.isFinite && value > 0 ? value : nil }
}

enum HealthFailure: Error { case unavailable }
