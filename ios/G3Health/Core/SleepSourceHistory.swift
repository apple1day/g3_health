import Foundation

struct SleepHistorySource: Identifiable, Codable {
    let sourceID: String
    let name: String
    let count: Int
    let earliest: Date
    let latest: Date
    let isOPPOCandidate: Bool
    var id: String { sourceID }
}

struct SleepHistoryDay: Identifiable {
    let day: String
    let timeZone: String
    let summary: SleepSummary
    let records: [HealthHistoryRecord]
    var id: String { day }
    var recordCount: Int { records.count }
}

/// HealthKit UUIDs identify records across pagination, updates and repeated scans.
/// Brand matching is only a UI hint; users can select every actual source.
struct SleepHistoryCatalog {
    private var byID: [String: HealthHistoryRecord] = [:]
    var count: Int { byID.count }

    mutating func apply(records: [HealthHistoryRecord], deletedIDs: [String]) {
        let deleted = Set(deletedIDs)
        for record in records where record.kind == HistoryKind.sleep.rawValue && !deleted.contains(record.id) {
            byID[record.id] = record
        }
        for id in deleted { byID.removeValue(forKey: id) }
    }

    var records: [HealthHistoryRecord] { Self.sorted(Array(byID.values)) }

    var sources: [SleepHistorySource] {
        Dictionary(grouping: byID.values, by: \.sourceID).compactMap { entry -> SleepHistorySource? in
            let (id, rows) = entry
            guard let latestRecord = rows.max(by: { $0.endedAt < $1.endedAt }),
                  let earliest = rows.map(\.startedAt).min(),
                  let latest = rows.map(\.endedAt).max() else { return nil }
            return SleepHistorySource(sourceID: id, name: latestRecord.sourceName, count: rows.count,
                earliest: earliest, latest: latest,
                isOPPOCandidate: rows.contains { Self.isOPPOCandidate(sourceID: $0.sourceID, name: $0.sourceName) })
        }.sorted {
            if $0.isOPPOCandidate != $1.isOPPOCandidate { return $0.isOPPOCandidate }
            if $0.latest != $1.latest { return $0.latest > $1.latest }
            return $0.sourceID < $1.sourceID
        }
    }

    func records(sourceID: String) -> [HealthHistoryRecord] {
        Self.sorted(byID.values.filter { $0.sourceID == sourceID })
    }

    static func isOPPOCandidate(sourceID: String, name: String) -> Bool {
        let value = (sourceID + " " + name).lowercased()
        return ["oppo", "heytap", "ohealth", "欢太", "oplus.health"].contains { value.contains($0) }
    }

    /// Groups one source in noon-to-noon windows, labelled by the window's ending day.
    /// The current display time zone controls the grouping; original sample time zones are preserved.
    static func days(records: [HealthHistoryRecord], sourceID: String, calendar: Calendar = .current) -> [SleepHistoryDay] {
        var groups: [Date: [HealthHistoryRecord]] = [:]
        for record in records where record.sourceID == sourceID && record.kind == HistoryKind.sleep.rawValue {
            guard record.startedAt.timeIntervalSince1970.isFinite, record.endedAt.timeIntervalSince1970.isFinite,
                  record.endedAt > record.startedAt,
                  let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: record.startedAt) else { continue }
            var end = record.startedAt < noon ? noon : calendar.date(byAdding: .day, value: 1, to: noon) ?? noon
            guard end > record.startedAt else { continue }
            while let start = calendar.date(byAdding: .day, value: -1, to: end), start < record.endedAt {
                if end > record.startedAt { groups[end, default: []].append(record) }
                guard let next = calendar.date(byAdding: .day, value: 1, to: end), next > end else { break }
                end = next
            }
        }
        return groups.keys.sorted(by: >).compactMap { end in
            guard let start = calendar.date(byAdding: .day, value: -1, to: end), let rows = groups[end] else { return nil }
            let segments = rows.compactMap { record -> SleepSegment? in
                guard let category = record.category, let stage = stage(category) else { return nil }
                return SleepSegment(start: record.startedAt, end: record.endedAt, stage: stage,
                    sourceID: record.sourceID, sourceName: record.sourceName, isAppleWatch: record.isAppleWatch)
            }
            return SleepHistoryDay(day: HealthSnapshot.dayString(end, calendar: calendar), timeZone: calendar.timeZone.identifier,
                summary: SleepAggregator.summarize(segments, window: SleepWindow(start: start, end: end)),
                records: sorted(rows))
        }
    }

    /// HealthKit's category values differ from the internal SleepStage raw values.
    private static func stage(_ category: Int) -> SleepStage? {
        switch category {
        case 0: return .inBed
        case 1: return .unspecified
        case 2: return .awake
        case 3: return .core
        case 4: return .deep
        case 5: return .rem
        default: return nil
        }
    }

    private static func sorted(_ rows: [HealthHistoryRecord]) -> [HealthHistoryRecord] {
        rows.sorted {
            if $0.startedAt != $1.startedAt { return $0.startedAt > $1.startedAt }
            if $0.endedAt != $1.endedAt { return $0.endedAt > $1.endedAt }
            return $0.id < $1.id
        }
    }
}

enum SleepHistoryExport {
    struct Document: Codable {
        let schemaVersion: Int
        let dataSource: String
        let scope: String
        let scanCompletedAt: Date
        let source: SleepHistorySource
        let recordCount: Int
        let notice: String
        let records: [HealthHistoryRecord]
    }

    static func json(records: [HealthHistoryRecord], source: SleepHistorySource, scannedAt: Date) throws -> Data {
        let selected = records.filter { $0.kind == HistoryKind.sleep.rawValue && $0.sourceID == source.sourceID }
        let document = Document(schemaVersion: 1, dataSource: "healthkit", scope: "one-source-readable-sleep",
            scanCompletedAt: scannedAt, source: source, recordCount: selected.count,
            notice: "仅包含本次从 Apple 健康读取到的该来源睡眠样本，不表示已取得 OPPO 云端全部历史。时间戳为 UTC；timeZone 优先采用样本时区，缺失或无法解析时采用读取时手机时区。未知睡眠分期保留原值。",
            records: selected)
        let encoder = JSONEncoder()
        let formatter = timestampFormatter()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        return try encoder.encode(document)
    }

    static func csv(records: [HealthHistoryRecord], sourceID: String) -> Data {
        let header = ["id", "started_at_utc", "ended_at_utc", "time_zone", "source_id", "source_name",
                      "device", "healthkit_category", "label", "sample_minutes", "unit", "is_apple_watch"]
        let formatter = timestampFormatter()
        var lines = [header.joined(separator: ",")]
        for record in records where record.kind == HistoryKind.sleep.rawValue && record.sourceID == sourceID {
            let row = [
                record.id, formatter.string(from: record.startedAt), formatter.string(from: record.endedAt), record.timeZone,
                record.sourceID, record.sourceName, record.device, record.category.map(String.init) ?? "",
                record.label, record.value.map { String($0) } ?? "", record.unit, record.isAppleWatch ? "true" : "false"
            ]
            lines.append(row.enumerated().map { index, value in
                // A spreadsheet must not execute a formula supplied by another app's source name.
                // JSON preserves the exact original strings if a CSV text cell needs this prefix.
                let isText = [3, 4, 5, 6, 8, 10].contains(index)
                return csvCell(value, protectFormula: isText)
            }.joined(separator: ","))
        }
        return Data(("\u{FEFF}" + lines.joined(separator: "\r\n") + "\r\n").utf8)
    }

    private static func timestampFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }

    private static func csvCell(_ value: String, protectFormula: Bool) -> String {
        var value = value
        if protectFormula, let first = value.trimmingCharacters(in: .whitespacesAndNewlines).first,
           "=+-@".contains(first) { value = "'" + value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
