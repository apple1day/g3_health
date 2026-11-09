import XCTest
@testable import G3Health

final class SnapshotAndRelayTests: XCTestCase {
    func testSnapshotRoundTripKeepsMissingValuesAndFractionalDate() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000.123)
        let snapshot = HealthSnapshot.empty(now: now)
        let encoded = try HealthSnapshot.encoder.encode(snapshot)
        let decoded = try HealthSnapshot.decoder.decode(HealthSnapshot.self, from: encoded)
        XCTAssertEqual(decoded.generatedAt.timeIntervalSince1970, now.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(decoded.activity.status, .empty)
        XCTAssertNil(decoded.activity.steps)
        XCTAssertNil(decoded.sleep.totalMinutes)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(json["dataMode"] as? String, "healthkit")
        XCTAssertEqual(json["schemaVersion"] as? Int, 1)
        XCTAssertTrue((json["generatedAt"] as? String ?? "").contains(".123Z"))
    }

    func testWireDayUsesGregorianInNonGregorianSystemCalendar() throws {
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-09T02:00:00Z"))
        XCTAssertEqual(HealthSnapshot.empty(now: now, calendar: buddhist).day, "2026-11-09")
    }

    func testWorkoutWindowHasInclusiveCompletedBoundaryAndRejectsFuture() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let window = RecentWorkoutWindow(now: now, calendar: calendar)
        XCTAssertTrue(window.containsCompletion(now))
        XCTAssertTrue(window.containsCompletion(window.start))
        XCTAssertFalse(window.containsCompletion(window.start.addingTimeInterval(-0.01)))
        XCTAssertFalse(window.containsCompletion(now.addingTimeInterval(0.01)))
        XCTAssertEqual(window.end.timeIntervalSince(window.start), 30 * 86400)
    }

    func testDemoCannotCreateAnUploadRequest() {
        XCTAssertThrowsError(try RelayClient.uploadRequest(snapshot: .demo(), base: "https://example.com", token: String(repeating: "a", count: 43))) { error in
            XCTAssertEqual((error as? RelayFailure)?.code, "demoBlocked")
        }
    }

    func testIncompleteHealthReadCannotUpload() {
        var snapshot = HealthSnapshot.empty()
        snapshot.sleep.status = .error
        XCTAssertThrowsError(try RelayClient.uploadRequest(snapshot: snapshot, base: "https://example.com", token: String(repeating: "a", count: 43))) { error in
            XCTAssertEqual((error as? RelayFailure)?.code, "queryIncomplete")
        }
    }

    func testRequestUsesAuthorizationHeaderNotQueryString() throws {
        let token = String(repeating: "a", count: 43)
        let request = try RelayClient.uploadRequest(snapshot: .empty(), base: "https://example.com/", token: token)
        XCTAssertEqual(request.url?.absoluteString, "https://example.com/v1/snapshot")
        XCTAssertNil(request.url?.query)
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + token)
        XCTAssertFalse(String(data: try XCTUnwrap(request.httpBody), encoding: .utf8)?.contains(token) ?? true)
    }

    func testHTTPAllowedOnlyForLocalDebugEndpoints() throws {
        for host in ["localhost", "127.0.0.1", "10.0.0.8", "192.168.1.6", "172.16.0.5", "test.local"] {
            XCTAssertNoThrow(try RelayClient.endpoint(base: "http://\(host):8000", allowLocalHTTP: true))
            XCTAssertThrowsError(try RelayClient.endpoint(base: "http://\(host):8000", allowLocalHTTP: false))
        }
        for host in ["example.com", "192.168.example.com", "172.32.0.1", "10.0.0.999", "localhost.example.com"] {
            XCTAssertThrowsError(try RelayClient.endpoint(base: "http://\(host)", allowLocalHTTP: true))
        }
    }

    func testEndpointRejectsCredentialsQueriesAndAPIPaths() {
        for base in ["https://user:pass@example.com", "https://example.com?token=secret", "https://example.com/#token", "https://example.com/v1/snapshot"] {
            XCTAssertThrowsError(try RelayClient.endpoint(base: base))
        }
    }

    func testTokenBoundsAndHeaderInjectionRejected() {
        XCTAssertNoThrow(try RelayClient.validateToken(String(repeating: "a", count: 32)))
        XCTAssertNoThrow(try RelayClient.validateToken(String(repeating: "a", count: 256)))
        XCTAssertThrowsError(try RelayClient.validateToken(String(repeating: "a", count: 257)))
        XCTAssertThrowsError(try RelayClient.validateToken(String(repeating: "a", count: 31)))
        XCTAssertThrowsError(try RelayClient.validateToken(String(repeating: "a", count: 40) + "\nX-Test: injected"))
    }
}
