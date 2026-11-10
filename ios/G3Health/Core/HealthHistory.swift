import Foundation

enum HistoryKind: String, CaseIterable, Codable, Identifiable {
    case sleep, workout, activitySummary, steps, distance, activeEnergy, exercise, heartRate
    var id: String { rawValue }
    var title: String {
        switch self {
        case .sleep: return "睡眠阶段"
        case .workout: return "运动记录"
        case .activitySummary: return "每日活动三环"
        case .steps: return "步数样本"
        case .distance: return "距离样本"
        case .activeEnergy: return "活动能量"
        case .exercise: return "锻炼时间"
        case .heartRate: return "心率样本"
        }
    }
}
struct HealthHistoryRecord: Codable, Identifiable {
    var id: String
    var kind: String
    var startedAt: Date
    var endedAt: Date
    var day: String
    var timeZone: String
    var sourceID: String
    var sourceName: String
    var device: String
    var isAppleWatch: Bool
    var value: Double?
    var unit: String
    var category: Int?
    var label: String
    var metrics: [String: Double] = [:]
}
struct HealthHistoryBatch: Codable {
    var schemaVersion = 1
    var epoch: String
    var kind: String
    var records: [HealthHistoryRecord]
    var deletedIDs: [String]
}
struct HealthHistoryStatus: Decodable {
    var epoch: String
    var count: Int
    var counts: [String: Int]
    var earliest: Date?
    var latest: Date?
}
struct HealthHistoryRow: Decodable, Identifiable {
    var rowID: Int64
    var sample: HealthHistoryRecord
    var receivedAt: Date
    var id: Int64 { rowID }
}
struct HealthHistoryPage: Decodable {
    var items: [HealthHistoryRow]
    var total: Int
    var nextCursor: String
}
struct HistoryCheckpoint: Codable {
    var endpoint = ""
    var epoch = ""
    var anchors: [String: Data] = [:]
    mutating func prepare(endpoint: String, epoch: String, rescan: Bool) {
        if self.endpoint != endpoint || self.epoch != epoch || rescan { anchors = [:] }
        self.endpoint = endpoint; self.epoch = epoch
    }
}
struct HistoryDayWindow {
    static func reference(_ day: Date, now: Date = Date(), calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        return min(now, end.addingTimeInterval(-0.001))
    }
}
