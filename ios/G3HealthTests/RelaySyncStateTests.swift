import XCTest
@testable import G3Health

final class RelaySyncStateTests: XCTestCase {
    private let base = "https://health-test.invalid"
    private func initial() -> RelaySyncState {
        var state = RelaySyncState(); state.configure(base); return state
    }
    func testHistorySuccessResolvesStaleConnectionWarningWithoutClaimingSummarySuccess() throws {
        var state = initial()
        let summary = try XCTUnwrap(state.begin(.snapshot, base: base))
        state.fail(summary, code: "network", message: "old network failure", transport: true)
        XCTAssertTrue(state.contactUnconfirmed)
        let history = try XCTUnwrap(state.begin(.historyUpload, base: base))
        state.succeed(history)
        XCTAssertFalse(state.contactUnconfirmed)
        XCTAssertNotNil(state.lastHistoryBatchAt)
        XCTAssertNil(state.lastSnapshotAt)
        XCTAssertEqual(state.headline, "服务最近已响应")
        XCTAssertFalse(try XCTUnwrap(state.detail(for: .snapshot)).contains("old network failure"))
        XCTAssertTrue(try XCTUnwrap(state.detail(for: .snapshot)).contains("上次未获确认"))
    }
    func testLateFailureCannotOverrideNewerSameOperationSuccess() throws {
        var state = initial()
        let old = try XCTUnwrap(state.begin(.snapshot, base: base))
        let new = try XCTUnwrap(state.begin(.snapshot, base: base))
        let now = Date()
        state.succeed(new, at: now, snapshot: now)
        state.fail(old, code: "network", message: "late", transport: true)
        XCTAssertTrue(state.issues.isEmpty)
        XCTAssertEqual(state.lastSnapshotAt, now)
    }
    func testLateOtherOperationFailureDoesNotOverrideNewerContact() throws {
        var state = initial()
        let summary = try XCTUnwrap(state.begin(.snapshot, base: base))
        let history = try XCTUnwrap(state.begin(.historyUpload, base: base))
        state.succeed(history)
        state.fail(summary, code: "network", message: "late", transport: true)
        XCTAssertFalse(state.contactUnconfirmed)
        XCTAssertNil(state.lastSnapshotAt)
    }
    func testNewFailureAfterSuccessRemainsVisibleAndPreservesReceipt() throws {
        var state = initial()
        state.succeed(try XCTUnwrap(state.begin(.snapshot, base: base)))
        state.fail(try XCTUnwrap(state.begin(.snapshot, base: base)), code: "network", message: "new failure", transport: true)
        XCTAssertTrue(state.contactUnconfirmed)
        XCTAssertNotNil(state.lastSnapshotAt)
        XCTAssertTrue(try XCTUnwrap(state.detail(for: .snapshot)).contains("new failure"))
    }
    func testChangingServerRejectsOldCompletionsEvenAfterSwitchingBack() throws {
        var state = initial()
        let old = try XCTUnwrap(state.begin(.snapshot, base: base))
        state.configure("https://different.invalid")
        state.configure(base)
        state.succeed(old)
        state.fail(old, code: "network", message: "old", transport: true)
        XCTAssertNil(state.lastContactAt)
        XCTAssertNil(state.lastSnapshotAt)
        XCTAssertTrue(state.issues.isEmpty)
    }
    func testNormalizationDoesNotEraseSameServerEvidence() throws {
        var state = initial()
        state.succeed(try XCTUnwrap(state.begin(.snapshot, base: base)))
        let generation = state.generation
        state.configure(" HTTPS://HEALTH-TEST.INVALID:443/ ")
        XCTAssertEqual(state.generation, generation)
        XCTAssertNotNil(state.lastSnapshotAt)
    }
    func testCancellationIsNotOffline() throws {
        var state = initial()
        state.fail(try XCTUnwrap(state.begin(.snapshot, base: base)), code: "cancelled", message: "cancelled", transport: true)
        XCTAssertFalse(state.contactUnconfirmed)
        XCTAssertTrue(state.issues.isEmpty)
        XCTAssertFalse(state.isBusy)
        XCTAssertNil(state.lastSnapshotAt)
    }
    func testReadOnlyCheckAndHistoryReadNeverConfirmUploads() throws {
        var state = initial()
        state.succeed(try XCTUnwrap(state.begin(.check, base: base)))
        state.succeed(try XCTUnwrap(state.begin(.historyRead, base: base)))
        XCTAssertNotNil(state.lastContactAt)
        XCTAssertNil(state.lastSnapshotAt)
        XCTAssertNil(state.lastHistoryBatchAt)
    }
    func testHTTPFailureMeansReachableNotUploaded() throws {
        var state = initial()
        state.fail(try XCTUnwrap(state.begin(.snapshot, base: base)), code: "http503", message: "HTTP 503", transport: false, responseReceived: true)
        XCTAssertFalse(state.contactUnconfirmed)
        XCTAssertNotNil(state.lastContactAt)
        XCTAssertNil(state.lastSnapshotAt)
        XCTAssertNotNil(state.detail(for: .snapshot))
    }
    func testDeleteClearsReceiptsAndInvalidatesOutstandingHistory() throws {
        var state = initial()
        state.succeed(try XCTUnwrap(state.begin(.snapshot, base: base)))
        let history = try XCTUnwrap(state.begin(.historyUpload, base: base))
        state.succeed(try XCTUnwrap(state.begin(.delete, base: base)))
        state.succeed(history)
        XCTAssertNil(state.lastSnapshotAt)
        XCTAssertNil(state.lastHistoryBatchAt)
        XCTAssertNotNil(state.lastContactAt)
    }
    func testOldAddressTaskCannotReconfigureState() {
        var state = initial()
        XCTAssertNil(state.begin(.snapshot, base: "https://old.invalid"))
        XCTAssertEqual(state.endpoint, base)
    }
    func testLocalValidationIsNeitherOfflineNorServerResponse() throws {
        var state = initial()
        state.fail(try XCTUnwrap(state.begin(.snapshot, base: base)), code: "demoBlocked", message: "demo", transport: false)
        XCTAssertNil(state.lastContactAt)
        XCTAssertFalse(state.contactUnconfirmed)
    }
}
