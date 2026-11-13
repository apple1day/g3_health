import XCTest
import HealthKit
@testable import G3Health

final class SleepSourceHistoryTests: XCTestCase {
    private let oppo = "com.heytap.health"
    private let apple = "com.apple.health"

    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    private func sample(_ id: String, source: String = "com.heytap.health", name: String = "OPPO 健康",
                        start: String = "2026-11-01T22:00:00Z", end: String = "2026-11-02T06:00:00Z",
                        category: Int = 1) -> HealthHistoryRecord {
        let started = date(start), ended = date(end)
        return HealthHistoryRecord(id: id, kind: "sleep", startedAt: started, endedAt: ended,
            day: "2026-11-01", timeZone: "UTC", sourceID: source, sourceName: name, device: "OnePlus Watch",
            isAppleWatch: false, value: ended.timeIntervalSince(started) / 60, unit: "min", category: category, label: "睡眠")
    }

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func testSourceIsolationAndBrandHintNeverHidesOtherSources() {
        var catalog = SleepHistoryCatalog()
        catalog.apply(records: [sample("a"), sample("b", source: apple, name: "Apple 健康"),
                                sample("c", source: "other", name: "我的睡眠记录")], deletedIDs: [])
        XCTAssertEqual(catalog.sources.count, 3)
        XCTAssertEqual(catalog.sources.first?.sourceID, oppo)
        XCTAssertTrue(catalog.sources.first?.isOPPOCandidate == true)
        XCTAssertEqual(catalog.records(sourceID: oppo).map(\.id), ["a"])
        XCTAssertEqual(catalog.records(sourceID: "other").map(\.id), ["c"])
        XCTAssertFalse(SleepHistoryCatalog.isOPPOCandidate(sourceID: apple, name: "Apple 健康"))
        XCTAssertTrue(SleepHistoryCatalog.isOPPOCandidate(sourceID: "unknown", name: "欢太健康"))
        XCTAssertTrue(SleepHistoryCatalog.isOPPOCandidate(sourceID: "unknown", name: "OHealth"))
    }

    func testPagesUpsertAndDeletionWinsOverAdditionInSamePage() {
        var catalog = SleepHistoryCatalog()
        catalog.apply(records: [sample("a"), sample("a"), sample("b")], deletedIDs: [])
        XCTAssertEqual(catalog.count, 2)
        var updated = sample("a"); updated.sourceName = "新名称"
        catalog.apply(records: [updated, sample("b")], deletedIDs: ["b"])
        XCTAssertEqual(catalog.count, 1)
        XCTAssertEqual(catalog.records.first?.sourceName, "新名称")
        catalog.apply(records: [], deletedIDs: ["a"])
        XCTAssertTrue(catalog.sources.isEmpty)
    }

    func testSummaryUsesOneSourceAndDoesNotDoubleCountBroadAndDetailedSleep() throws {
        let broad = sample("broad")
        let core = sample("core", end: "2026-11-02T02:00:00Z", category: 3)
        let deep = sample("deep", start: "2026-11-02T02:00:00Z", category: 4)
        let other = sample("apple", source: apple, name: "Apple 健康",
                           start: "2026-11-01T20:00:00Z", end: "2026-11-02T08:00:00Z")
        let days = SleepHistoryCatalog.days(records: [broad, core, deep, other], sourceID: oppo, calendar: utc)
        let day = try XCTUnwrap(days.first)
        XCTAssertEqual(days.count, 1)
        XCTAssertEqual(day.day, "2026-11-02")
        XCTAssertEqual(day.recordCount, 3)
        XCTAssertEqual(try XCTUnwrap(day.summary.totalMinutes), 480, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(day.summary.deepMinutes), 240, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(day.summary.coreMinutes), 240, accuracy: 0.01)
    }

    func testCrossNoonRecordIsClippedPerDayButPreservedRaw() throws {
        let record = sample("cross", start: "2026-11-02T11:00:00Z", end: "2026-11-02T13:00:00Z")
        let days = SleepHistoryCatalog.days(records: [record], sourceID: oppo, calendar: utc)
        XCTAssertEqual(days.map(\.day), ["2026-11-03", "2026-11-02"])
        for day in days {
            XCTAssertEqual(try XCTUnwrap(day.summary.totalMinutes), 60, accuracy: 0.01)
            XCTAssertEqual(day.records.first?.startedAt, record.startedAt)
            XCTAssertEqual(day.records.first?.endedAt, record.endedAt)
        }
    }

    func testUnknownAndInBedRecordsRemainVisibleWithoutInventingSleep() {
        let days = SleepHistoryCatalog.days(records: [sample("unknown", category: 99), sample("in-bed", category: 0)],
                                           sourceID: oppo, calendar: utc)
        XCTAssertEqual(days.first?.recordCount, 2)
        XCTAssertNil(days.first?.summary.totalMinutes)
    }

    func testJSONIsSingleSourceAndPreservesUnknownStageAndTimeZone() throws {
        var a = sample("a", category: 99); a.timeZone = "Asia/Shanghai"
        var catalog = SleepHistoryCatalog()
        catalog.apply(records: [a, sample("other", source: apple)], deletedIDs: [])
        let source = try XCTUnwrap(catalog.sources.first { $0.id == oppo })
        let data = try SleepHistoryExport.json(records: catalog.records, source: source, scannedAt: date("2026-11-13T00:00:00Z"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rows = try XCTUnwrap(json["records"] as? [[String: Any]])
        XCTAssertEqual(json["recordCount"] as? Int, 1)
        XCTAssertEqual(rows.first?["category"] as? Int, 99)
        XCTAssertEqual(rows.first?["timeZone"] as? String, "Asia/Shanghai")
        XCTAssertEqual(rows.first?["startedAt"] as? String, "2026-11-01T22:00:00.000Z")
    }

    func testCSVQuotesNewlinesAndFormulaLikeSourceNames() throws {
        var a = sample("a", name: "=OPPO,\"Health\"\nApp")
        a.label = "睡眠,未分类"
        let data = SleepHistoryExport.csv(records: [a, sample("other", source: apple)], sourceID: oppo)
        let csv = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(csv.hasPrefix("\u{FEFF}id,"))
        XCTAssertTrue(csv.contains("\"'=OPPO,\"\"Health\"\"\nApp\""))
        XCTAssertTrue(csv.contains("\"睡眠,未分类\""))
        XCTAssertTrue(csv.contains("\"2026-11-01T22:00:00.000Z\""))
        XCTAssertFalse(csv.contains("\"other\""))
    }

    @MainActor func testScannerContinuesAfterAFullPageAndIncludesOldRecords() async throws {
        var calls = 0
        let records = (0..<201).map { sample(String($0), start: "2015-01-01T22:00:00Z", end: "2015-01-02T06:00:00Z") }
        let model = SleepSourceHistoryModel(requestAccess: {}, readPage: { anchor in
            calls += 1
            if calls == 1 {
                XCTAssertNil(anchor)
                return HealthHistoryReader.Page(records: Array(records.prefix(200)), deletedIDs: [], anchor: HKQueryAnchor(fromValue: 200), returnedCount: 200)
            }
            XCTAssertNotNil(anchor)
            if calls == 2 {
                return HealthHistoryReader.Page(records: [records[200]], deletedIDs: [], anchor: HKQueryAnchor(fromValue: 201), returnedCount: 1)
            }
            return HealthHistoryReader.Page(records: [], deletedIDs: [], anchor: HKQueryAnchor(fromValue: 201), returnedCount: 0)
        })
        await model.scan()
        XCTAssertEqual(calls, 3)
        XCTAssertEqual(model.records.count, 201)
        XCTAssertEqual(model.sources.first?.earliest, date("2015-01-01T22:00:00Z"))
        XCTAssertTrue(model.isComplete)
        XCTAssertFalse(try model.exportJSON().isEmpty)
    }

    @MainActor func testStoppedScanCannotExportPartialResultsAsCompleteHistory() async {
        var model: SleepSourceHistoryModel!
        model = SleepSourceHistoryModel(requestAccess: {}, readPage: { _ in
            model.stop()
            return HealthHistoryReader.Page(records: [self.sample("a")], deletedIDs: [], anchor: HKQueryAnchor(fromValue: 1), returnedCount: 1)
        })
        await model.scan()
        XCTAssertEqual(model.records.count, 1)
        XCTAssertFalse(model.isComplete)
        XCTAssertFalse(model.isScanning)
        XCTAssertThrowsError(try model.exportJSON())
        XCTAssertTrue(model.exportCSV().isEmpty)
    }

    @MainActor func testOPPODefaultSelectionCanBeDiscoveredAfterFirstPage() async {
        var calls = 0
        let model = SleepSourceHistoryModel(requestAccess: {}, readPage: { _ in
            calls += 1
            let rows = calls == 1 ? [self.sample("apple", source: self.apple, name: "Apple 健康")]
                : calls == 2 ? [self.sample("oppo")] : []
            return HealthHistoryReader.Page(records: rows, deletedIDs: [], anchor: HKQueryAnchor(fromValue: calls), returnedCount: rows.count)
        })
        await model.scan()
        XCTAssertEqual(model.selectedSourceID, oppo)
        XCTAssertEqual(model.selectedRecords.map(\.id), ["oppo"])
    }

    @MainActor func testEmptyReadableStoreDoesNotClaimDeniedPermissionOrNoCloudHistory() async {
        let model = SleepSourceHistoryModel(requestAccess: {}, readPage: { _ in
            HealthHistoryReader.Page(records: [], deletedIDs: [], anchor: HKQueryAnchor(fromValue: 0), returnedCount: 0)
        })
        await model.scan()
        XCTAssertTrue(model.isComplete)
        XCTAssertTrue(model.sources.isEmpty)
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.progress.contains("可能"))
        XCTAssertNil(model.selectedSource)
    }
}
