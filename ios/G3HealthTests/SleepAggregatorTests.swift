import XCTest
@testable import G3Health

final class SleepAggregatorTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)
    private func segment(_ start: Double, _ end: Double, _ stage: SleepStage, source: String = "watch", watch: Bool = true) -> SleepSegment {
        SleepSegment(start: origin.addingTimeInterval(start * 60), end: origin.addingTimeInterval(end * 60),
                     stage: stage, sourceID: source, sourceName: source, isAppleWatch: watch)
    }
    private var window: SleepWindow { SleepWindow(start: origin, end: origin.addingTimeInterval(600 * 60)) }

    func testInBedAndDuplicateSamplesDoNotInflateSleep() {
        let result = SleepAggregator.summarize([
            segment(0, 480, .inBed), segment(20, 200, .core), segment(100, 200, .core),
            segment(200, 220, .awake), segment(220, 280, .deep), segment(280, 400, .rem)
        ], window: window)
        XCTAssertEqual(result.status, .ok)
        XCTAssertEqual(result.totalMinutes, 360)
        XCTAssertEqual(result.coreMinutes, 180)
        XCTAssertEqual(result.deepMinutes, 60)
        XCTAssertEqual(result.remMinutes, 120)
        XCTAssertEqual(result.awakeMinutes, 20)
    }

    func testDetailedAwakeOverridesBroadLegacyAsleep() {
        let result = SleepAggregator.summarize([
            segment(0, 180, .unspecified), segment(0, 60, .core),
            segment(60, 90, .awake), segment(90, 180, .rem)
        ], window: window)
        XCTAssertEqual(result.totalMinutes, 150)
        XCTAssertEqual(result.awakeMinutes, 30)
        XCTAssertEqual(result.unspecifiedMinutes, 0)
        XCTAssertEqual(result.coreMinutes, 60)
    }

    func testUnclassifiedSleepKeepsUnknownStagesNil() {
        let result = SleepAggregator.summarize([segment(10, 100, .unspecified)], window: window)
        XCTAssertEqual(result.totalMinutes, 90)
        XCTAssertEqual(result.unspecifiedMinutes, 90)
        XCTAssertNil(result.coreMinutes)
        XCTAssertNil(result.deepMinutes)
        XCTAssertNil(result.remMinutes)
        XCTAssertNil(result.awakeMinutes)
    }

    func testAppleWatchPreferredOverLongerThirdPartyCopy() {
        let result = SleepAggregator.summarize([
            segment(0, 480, .unspecified, source: "another-app", watch: false),
            segment(50, 150, .core)
        ], window: window)
        XCTAssertEqual(result.totalMinutes, 100)
        XCTAssertEqual(result.sourceName, "watch")
    }

    func testAnInBedOnlyWatchDoesNotHideOtherRealSleep() {
        let result = SleepAggregator.summarize([
            segment(0, 400, .inBed), segment(20, 100, .unspecified, source: "other", watch: false)
        ], window: window)
        XCTAssertEqual(result.totalMinutes, 80)
        XCTAssertEqual(result.sourceName, "other")
    }

    func testClipsAtWindowAndIgnoresInvertedSegments() {
        let result = SleepAggregator.summarize([
            segment(-20, 20, .core), segment(580, 650, .deep), segment(100, 90, .rem)
        ], window: window)
        XCTAssertEqual(result.totalMinutes, 40)
        XCTAssertEqual(result.startedAt, origin)
        XCTAssertEqual(result.endedAt, window.end)
    }

    func testEmptyAndOnlyInBedAreUnknownRatherThanZero() {
        for samples in [[], [segment(0, 480, .inBed)]] {
            let result = SleepAggregator.summarize(samples, window: window)
            XCTAssertEqual(result.status, .empty)
            XCTAssertNil(result.totalMinutes)
        }
    }

    func testNoonWindowUsesCalendarDaysAcrossDST() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let formatter = ISO8601DateFormatter()
        let morning = try XCTUnwrap(formatter.date(from: "2026-03-08T14:00:00Z"))
        let result = SleepWindow.overnight(now: morning, calendar: calendar)
        XCTAssertEqual(result.start, formatter.date(from: "2026-03-07T17:00:00Z"))
        XCTAssertEqual(result.end, morning)
        let afternoon = try XCTUnwrap(formatter.date(from: "2026-03-08T20:00:00Z"))
        let later = SleepWindow.overnight(now: afternoon, calendar: calendar)
        XCTAssertEqual(later.end, formatter.date(from: "2026-03-08T16:00:00Z"))
        XCTAssertEqual(later.end.timeIntervalSince(later.start), 23 * 3600)
    }
}
