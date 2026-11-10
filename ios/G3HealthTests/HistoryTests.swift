import XCTest
import HealthKit
@testable import G3Health

final class HistoryTests: XCTestCase {
    func testCheckpointScopedToServerEpochAndExplicitRescan() {
        var c = HistoryCheckpoint(endpoint: "http://one", epoch: "epoch1", anchors: ["sleep": Data([1])])
        c.prepare(endpoint: "http://one", epoch: "epoch1", rescan: false)
        XCTAssertEqual(c.anchors.count, 1)
        c.prepare(endpoint: "http://two", epoch: "epoch1", rescan: false)
        XCTAssertTrue(c.anchors.isEmpty)
        c.anchors["sleep"] = Data([1]); c.prepare(endpoint: "http://two", epoch: "epoch2", rescan: false)
        XCTAssertTrue(c.anchors.isEmpty)
        c.anchors["sleep"] = Data([1]); c.prepare(endpoint: "http://two", epoch: "epoch2", rescan: true)
        XCTAssertTrue(c.anchors.isEmpty)
    }
    func testHistoryUsesOwnEndpointAndNoToken() throws {
        let b = HealthHistoryBatch(epoch: UUID().uuidString, kind: "sleep", records: [], deletedIDs: [])
        let r = try RelayClient.historyUploadRequest(b, base: "http://192.168.1.10:8787/", allowLocalHTTP: true)
        XCTAssertEqual(r.url?.path, "/v1/history/batch")
        XCTAssertEqual(r.httpMethod, "PUT")
        XCTAssertNil(r.value(forHTTPHeaderField: "Authorization"))
        let decoded = try HealthSnapshot.decoder.decode(HealthHistoryBatch.self, from: XCTUnwrap(r.httpBody))
        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.records.count, 0)
        XCTAssertThrowsError(try RelayClient.historyURL(base: "https://example.com", path: "../snapshot"))
    }
    func testHistoryDayUsesCalendarBoundaryIncludingDST() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let start = cal.date(from: DateComponents(year: 2026, month: 3, day: 8))!
        let ref = HistoryDayWindow.reference(start, now: start.addingTimeInterval(7*86400), calendar: cal)
        XCTAssertEqual(ref.timeIntervalSince(start), 23*3600 - 0.001, accuracy: 0.01)
        XCTAssertEqual(HealthSnapshot.dayString(ref, calendar: cal), "2026-03-08")
        let now = start.addingTimeInterval(3600)
        XCTAssertEqual(HistoryDayWindow.reference(start, now: now, calendar: cal), now)
    }
    func testAnchorsSupportSecureRoundTrip() throws {
        let a = HKQueryAnchor(fromValue: 123)
        let data = try NSKeyedArchiver.archivedData(withRootObject: a, requiringSecureCoding: true)
        XCTAssertNotNil(try NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data))
    }
    @MainActor func testAllSampleKindsHaveTypesExceptRings() {
        XCTAssertEqual(HistoryKind.allCases.count, 8)
        for k in HistoryKind.allCases where k != .activitySummary { XCTAssertNotNil(HealthHistoryReader.sampleType(k)) }
        XCTAssertNil(HealthHistoryReader.sampleType(.activitySummary))
    }
}
