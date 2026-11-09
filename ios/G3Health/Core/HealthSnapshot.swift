import Foundation

enum DataMode: String, Codable, Sendable { case healthkit, demo }
enum SectionStatus: String, Codable, Sendable { case ok, empty, error }
enum MoveMode: String, Codable, Sendable { case energy, time, unknown }

struct SleepSummary: Codable, Sendable {
    var status: SectionStatus = .empty
    var startedAt: Date?
    var endedAt: Date?
    var totalMinutes: Double?
    var coreMinutes: Double?
    var deepMinutes: Double?
    var remMinutes: Double?
    var unspecifiedMinutes: Double?
    var awakeMinutes: Double?
    var sourceName: String?
}

struct ActivitySummary: Codable, Sendable {
    var status: SectionStatus = .empty
    var steps: Double?
    var distanceMeters: Double?
    var activeEnergyKcal: Double?
    var exerciseMinutes: Double?
    var standHours: Double?
    var activeEnergyGoalKcal: Double?
    var exerciseGoalMinutes: Double?
    var standGoalHours: Double?
    var moveMode: MoveMode = .unknown
    var moveMinutes: Double?
    var moveGoalMinutes: Double?
}

struct HeartRateSummary: Codable, Sendable {
    var status: SectionStatus = .empty
    var bpm: Double?
    var measuredAt: Date?
}

struct WorkoutSummary: Codable, Sendable {
    var status: SectionStatus = .empty
    var kind: String?
    var startedAt: Date?
    var endedAt: Date?
    var durationSeconds: Double?
    var distanceMeters: Double?
    var activeEnergyKcal: Double?
}

struct HealthSnapshot: Codable, Sendable {
    var schemaVersion = 1
    var dataMode: DataMode = .healthkit
    var generatedAt: Date
    var timeZone: String
    var day: String
    var sourcePolicy = "healthKit"
    var sleep = SleepSummary()
    var activity = ActivitySummary()
    var heartRate = HeartRateSummary()
    var workout = WorkoutSummary()
    var warnings: [String] = []

    var hasQueryError: Bool {
        [sleep.status, activity.status, heartRate.status, workout.status].contains(.error)
    }

    static func empty(now: Date = Date(), calendar: Calendar = .current) -> Self {
        Self(generatedAt: now, timeZone: calendar.timeZone.identifier, day: dayString(now, calendar: calendar))
    }

    static func dayString(_ date: Date, calendar: Calendar) -> String {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let parts = gregorian.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            try container.encode(formatter.string(from: date))
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: text) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO8601 date")
        }
        return decoder
    }

    static func demo(now: Date = Date()) -> Self {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: now)
        var result = empty(now: now)
        result.dataMode = .demo
        result.sleep = SleepSummary(
            status: .ok,
            startedAt: dayStart.addingTimeInterval(-50 * 60),
            endedAt: dayStart.addingTimeInterval(7 * 3600 + 10 * 60),
            totalMinutes: 430,
            coreMinutes: 245,
            deepMinutes: 70,
            remMinutes: 100,
            unspecifiedMinutes: 15,
            awakeMinutes: 30,
            sourceName: "演示 Apple Watch"
        )
        result.activity = ActivitySummary(status: .ok, steps: 6820, distanceMeters: 4810,
            activeEnergyKcal: 328, exerciseMinutes: 24, standHours: 7,
            activeEnergyGoalKcal: 500, exerciseGoalMinutes: 30, standGoalHours: 12,
            moveMode: .energy)
        result.heartRate = HeartRateSummary(status: .ok, bpm: 72, measuredAt: now.addingTimeInterval(-8 * 60))
        result.workout = WorkoutSummary(status: .ok, kind: "户外跑步",
            startedAt: dayStart.addingTimeInterval(-14 * 3600),
            endedAt: dayStart.addingTimeInterval(-14 * 3600 + 1920),
            durationSeconds: 1920, distanceMeters: 5020, activeEnergyKcal: 320)
        result.warnings = ["演示数据，仅用于界面测试，不代表你的健康记录；不会上传。"]
        return result
    }
}
