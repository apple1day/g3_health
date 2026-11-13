import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import G3Health

/// Synthetic replies only; no device data, real server, credentials or real network access.
private final class RelayProtocolStub: URLProtocol {
    enum Reply { case http(Int, Data); case failure(URLError.Code) }
    private static let lock = NSLock()
    private static var replies: [Reply] = []
    private static var captured: [URLRequest] = []
    static func reset(_ values: [Reply]) { lock.lock(); defer { lock.unlock() }; replies = values; captured = [] }
    static var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return captured }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.captured.append(request)
        let reply = Self.replies.isEmpty ? Reply.failure(.resourceUnavailable) : Self.replies.removeFirst()
        Self.lock.unlock()
        switch reply {
        case .http(let code, let data):
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let code): client?.urlProtocol(self, didFailWithError: URLError(code))
        }
    }
    override func stopLoading() {}
}

final class RelayConfirmationTests: XCTestCase {
    private let base = "https://health-test.invalid"
    private var snapshot: HealthSnapshot {
        var value = HealthSnapshot.empty(now: Date(timeIntervalSince1970: 1_700_000_000.123))
        value.activity.steps = 123; value.activity.status = .ok
        return value
    }
    private var client: RelayClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RelayProtocolStub.self]
        return RelayClient(configuration: config)
    }
    override func setUp() async throws {
        RelayProtocolStub.reset([])
        await MainActor.run {
            RelayStatusStore.shared.configure("")
            RelayStatusStore.shared.configure(base)
        }
    }
    private func json(_ text: String) -> Data { Data(text.utf8) }
    private func envelope(_ value: HealthSnapshot) throws -> Data {
        let object = try JSONSerialization.jsonObject(with: HealthSnapshot.encoder.encode(value))
        return try JSONSerialization.data(withJSONObject: ["snapshot": object, "receivedAt": "2023-11-14T22:13:21Z"])
    }
    private func state() async -> RelaySyncState { await RelayStatusStore.shared.state }

    func testAcknowledgedUploadRecordsSuccessWithoutToken() async throws {
        RelayProtocolStub.reset([.http(200, json("{\"receivedAt\":\"2023-11-14T22:13:21Z\"}"))])
        let receipt = try await client.upload(snapshot, base: base)
        XCTAssertFalse(receipt.recoveredByReadback)
        let status = await state()
        XCTAssertNotNil(status.lastSnapshotAt)
        XCTAssertEqual(RelayProtocolStub.requests.count, 1)
        XCTAssertNil(RelayProtocolStub.requests.first?.value(forHTTPHeaderField: "Authorization"))
    }
    func testTimedOutButSavedUploadConfirmedByExactReadback() async throws {
        RelayProtocolStub.reset([.failure(.timedOut), .http(200, try envelope(snapshot))])
        let receipt = try await client.upload(snapshot, base: base)
        XCTAssertTrue(receipt.recoveredByReadback)
        XCTAssertEqual(RelayProtocolStub.requests.map(\.httpMethod), ["PUT", "GET"])
        let status = await state()
        XCTAssertNotNil(status.lastSnapshotAt)
        XCTAssertTrue(status.issues.isEmpty)
    }
    func testLostConnectionCanRecoverFromSavedSnapshot() async throws {
        RelayProtocolStub.reset([.failure(.networkConnectionLost), .http(200, try envelope(snapshot))])
        let receipt = try await client.upload(snapshot, base: base)
        XCTAssertTrue(receipt.recoveredByReadback)
    }
    func testSameTimestampDifferentContentIsNotSuccess() async throws {
        var different = snapshot; different.activity.steps = 999
        RelayProtocolStub.reset([.failure(.timedOut), .http(200, try envelope(different))])
        do { try await client.upload(snapshot, base: base); XCTFail("must not infer success") }
        catch let error as RelayFailure { XCTAssertEqual(error.code, "uploadUnconfirmed"); XCTAssertEqual(error.networkCode, URLError.timedOut.rawValue) }
        let status = await state()
        XCTAssertNil(status.lastSnapshotAt)
        XCTAssertFalse(status.contactUnconfirmed)
        XCTAssertNotNil(status.lastContactAt)
    }
    func testNewerServerRecordIsNotProofOfThisUpload() async throws {
        var newer = snapshot; newer.generatedAt = newer.generatedAt.addingTimeInterval(60)
        RelayProtocolStub.reset([.failure(.timedOut), .http(200, try envelope(newer))])
        do { try await client.upload(snapshot, base: base); XCTFail("must not infer success") }
        catch let error as RelayFailure { XCTAssertEqual(error.code, "uploadUnconfirmed") }
        let status = await state(); XCTAssertNil(status.lastSnapshotAt)
    }
    func testMissingRecordAfterTimeoutRemainsUnconfirmed() async throws {
        RelayProtocolStub.reset([.failure(.timedOut), .http(404, json("{}"))])
        do { try await client.upload(snapshot, base: base); XCTFail("missing record") }
        catch let error as RelayFailure { XCTAssertEqual(error.code, "uploadUnconfirmed") }
        let status = await state(); XCTAssertNil(status.lastSnapshotAt)
    }
    func testCancellationDoesNotProbeOrShowOffline() async throws {
        RelayProtocolStub.reset([.failure(.cancelled)])
        do { try await client.upload(snapshot, base: base); XCTFail("cancelled") }
        catch let error as RelayFailure { XCTAssertEqual(error.code, "cancelled") }
        let status = await state()
        XCTAssertTrue(status.issues.isEmpty); XCTAssertFalse(status.contactUnconfirmed)
        XCTAssertEqual(RelayProtocolStub.requests.count, 1)
    }
    func testHTTPRejectedUploadNotMisreportedAsNetworkFailure() async throws {
        RelayProtocolStub.reset([.http(422, json("{}"))])
        do { try await client.upload(snapshot, base: base); XCTFail("rejected") }
        catch let error as RelayFailure { XCTAssertTrue(error.reachedServer); XCTAssertEqual(error.code, "invalidSnapshot") }
        let status = await state()
        XCTAssertNotNil(status.lastContactAt); XCTAssertNil(status.lastSnapshotAt)
        XCTAssertFalse(status.contactUnconfirmed)
    }
    func testMalformedAcknowledgementDoesNotTurnGreen() async throws {
        RelayProtocolStub.reset([.http(200, json("{}")), .http(404, json("{}"))])
        do { try await client.upload(snapshot, base: base); XCTFail("invalid receipt") }
        catch let error as RelayFailure { XCTAssertEqual(error.code, "invalidReceipt") }
        let status = await state(); XCTAssertNil(status.lastSnapshotAt)
    }
    func testProbeDoesNotClaimUploadSuccess() async throws {
        RelayProtocolStub.reset([.http(200, json("{\"status\":\"ok\",\"apiVersion\":1}"))])
        try await client.checkConnection(base: base)
        let status = await state()
        XCTAssertNotNil(status.lastContactAt); XCTAssertNil(status.lastSnapshotAt); XCTAssertNil(status.lastHistoryBatchAt)
        XCTAssertEqual(RelayProtocolStub.requests.first?.url?.path, "/healthz")
    }
    func testProbeRejectsUnrelatedWebServer() async throws {
        RelayProtocolStub.reset([.http(200, json("{}"))])
        do { try await client.checkConnection(base: base); XCTFail("wrong service") }
        catch let error as RelayFailure { XCTAssertEqual(error.code, "invalidService") }
        let status = await state(); XCTAssertNotNil(status.issues[.check]); XCTAssertNil(status.lastSnapshotAt)
    }
    func testHistoryReadSuccessDoesNotClaimBatchWasUploaded() async throws {
        RelayProtocolStub.reset([.http(200, json("{\"epoch\":\"test-epoch\",\"count\":40,\"counts\":{\"sleep\":40}}"))])
        let _: HealthHistoryStatus = try await client.historyGET(base: base, path: "history/status")
        let status = await state()
        XCTAssertNotNil(status.lastContactAt); XCTAssertNil(status.lastHistoryBatchAt); XCTAssertNil(status.lastSnapshotAt)
    }
    func testHistoryBatchReceiptUpdatesSharedStateAndClearsOldConnectionMessage() async throws {
        await MainActor.run {
            let old = RelayStatusStore.shared.begin(.snapshot, base: base)
            RelayStatusStore.shared.fail(old, error: RelayFailure.transport(URLError(.timedOut)))
        }
        RelayProtocolStub.reset([.http(200, json("{\"accepted\":0,\"deleted\":1,\"epoch\":\"test-epoch\"}"))])
        try await client.uploadHistory(HealthHistoryBatch(epoch: "test-epoch", kind: "sleep", records: [], deletedIDs: ["synthetic-id"]), base: base)
        let status = await state()
        XCTAssertFalse(status.contactUnconfirmed); XCTAssertNotNil(status.lastHistoryBatchAt); XCTAssertNil(status.lastSnapshotAt)
    }
    func testInvalidHistoryReceiptKeepsCheckpointUnconfirmed() async throws {
        RelayProtocolStub.reset([.http(200, json("{\"accepted\":0,\"deleted\":1,\"epoch\":\"wrong-epoch\"}"))])
        do {
            try await client.uploadHistory(HealthHistoryBatch(epoch: "test-epoch", kind: "sleep", records: [], deletedIDs: ["synthetic-id"]), base: base)
            XCTFail("invalid receipt")
        } catch let error as RelayFailure { XCTAssertEqual(error.code, "historyReceipt") }
        let status = await state(); XCTAssertNil(status.lastHistoryBatchAt)
    }
}
