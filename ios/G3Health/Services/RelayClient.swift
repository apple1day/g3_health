import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct RelayFailure: LocalizedError {
    let code: String
    let message: String
    var reachedServer = false
    var networkCode: Int? = nil
    var errorDescription: String? { message }
    var isTransportFailure: Bool {
        !reachedServer && (networkCode != nil || code == "network" || code == "uploadUnconfirmed")
    }

    static func transport(_ error: Error) -> RelayFailure {
        let value = error as NSError
        let code = value.domain == NSURLErrorDomain ? value.code : nil
        if error is CancellationError || code == URLError.cancelled.rawValue {
            return RelayFailure(code: "cancelled", message: "请求已取消；不代表服务无法连接。", networkCode: code)
        }
        switch code {
        case URLError.timedOut.rawValue:
            return RelayFailure(code: "networkTimeout", message: "请求超时，尚未收到服务确认。", networkCode: code)
        case URLError.networkConnectionLost.rawValue:
            return RelayFailure(code: "networkInterrupted", message: "响应途中连接中断，结果尚未确认。", networkCode: code)
        case URLError.notConnectedToInternet.rawValue:
            return RelayFailure(code: "networkOffline", message: "本次请求没有可用网络；已保存的数据不受影响。", networkCode: code)
        case URLError.cannotConnectToHost.rawValue, URLError.cannotFindHost.rawValue, URLError.dnsLookupFailed.rawValue:
            return RelayFailure(code: "networkHost", message: "本次未能访问服务地址，请检查服务进程、地址和局域网权限。", networkCode: code)
        case URLError.secureConnectionFailed.rawValue, URLError.serverCertificateUntrusted.rawValue, URLError.serverCertificateHasBadDate.rawValue:
            return RelayFailure(code: "networkTLS", message: "本次 HTTPS 验证失败，请检查服务证书。", networkCode: code)
        default:
            return RelayFailure(code: "network", message: "本次请求未收到完整响应，请检查网络后重试。", networkCode: code)
        }
    }
}

/// Local single-user relay: no token/cookies; health payloads never follow redirects.
final class RelayClient: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let configuration: URLSessionConfiguration

    init(configuration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration.copy() as! URLSessionConfiguration
        super.init()
    }

    static var allowsLocalHTTP: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    static func endpoint(base: String, allowLocalHTTP: Bool = allowsLocalHTTP) throws -> URL {
        let text = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parts = URLComponents(string: text), let scheme = parts.scheme?.lowercased(),
              let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/",
              parts.port.map({ (1...65535).contains($0) }) ?? true
        else { throw RelayFailure(code: "invalidURL", message: "请填写服务根地址，如 https://health.example.com；不要包含路径、账号或查询参数。") }
        guard scheme == "https" || (scheme == "http" && allowLocalHTTP && isLocalHost(host)) else {
            throw RelayFailure(code: "httpsRequired", message: "正式连接需要 HTTPS。Debug 测试仅允许局域网 IP、localhost 或 .local 地址使用 HTTP。")
        }
        guard let url = parts.url else { throw RelayFailure(code: "invalidURL", message: "服务地址无效。") }
        return url.appendingPathComponent("v1").appendingPathComponent("snapshot")
    }

    private static func isLocalHost(_ host: String) -> Bool {
        if ["localhost", "::1", "[::1]"].contains(host) || host.hasSuffix(".local") { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int(part), (0...255).contains(value) else { return false }
            numbers.append(value)
        }
        return numbers[0] == 10 || numbers[0] == 127
            || (numbers[0] == 192 && numbers[1] == 168)
            || (numbers[0] == 172 && (16...31).contains(numbers[1]))
    }

    static func uploadRequest(snapshot: HealthSnapshot, base: String,
                              allowLocalHTTP: Bool = allowsLocalHTTP) throws -> URLRequest {
        guard snapshot.dataMode == .healthkit else {
            throw RelayFailure(code: "demoBlocked", message: "演示数据不能上传，请先读取 Apple 健康。")
        }
        guard !snapshot.hasQueryError else {
            throw RelayFailure(code: "queryIncomplete", message: "有健康数据尚未读取完成，请解锁并刷新后再同步。")
        }
        var request = URLRequest(url: try endpoint(base: base, allowLocalHTTP: allowLocalHTTP))
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try HealthSnapshot.encoder.encode(snapshot)
        request.timeoutInterval = 30
        return request
    }

    struct UploadReceipt: Sendable {
        let receivedAt: Date
        let recoveredByReadback: Bool
    }
    private struct ReceiptBody: Decodable { let receivedAt: Date }
    private struct StoredSnapshot: Decodable {
        let snapshot: HealthSnapshot
        let receivedAt: Date
    }

    @discardableResult
    func upload(_ snapshot: HealthSnapshot, base: String) async throws -> UploadReceipt {
        let tracker = await RelayStatusStore.shared
        let attempt = await tracker.begin(.snapshot, base: base)
        do {
            let receipt = try await uploadAndConfirm(snapshot, base: base)
            await tracker.succeed(attempt, snapshot: snapshot.generatedAt)
            return receipt
        } catch {
            await tracker.fail(attempt, error: error)
            throw error
        }
    }

    private func uploadAndConfirm(_ snapshot: HealthSnapshot, base: String) async throws -> UploadReceipt {
        let request = try Self.uploadRequest(snapshot: snapshot, base: base)
        do {
            let (data, response) = try await responseData(request)
            try Self.validateSnapshotResponse(response)
            guard let body = try? HealthSnapshot.decoder.decode(ReceiptBody.self, from: data) else {
                throw RelayFailure(code: "invalidReceipt", message: "服务已响应，但上传回执无法验证。", reachedServer: true)
            }
            return UploadReceipt(receivedAt: body.receivedAt, recoveredByReadback: false)
        } catch let failure as RelayFailure {
            // A lost response does not prove that the write failed. Verify exact content, never
            // infer success from HTTP healthz, historical row counts, or a newer timestamp alone.
            guard failure.code != "cancelled", !Task.isCancelled else { throw failure }
            let mayVerify = failure.networkCode != nil || failure.code == "invalidReceipt" || failure.code == "stale"
            var readbackResponded = false
            if mayVerify, let result = try? await storedReceipt(matching: snapshot, base: base) {
                if let receipt = result.receipt { return receipt }
                readbackResponded = true
            }
            try Task.checkCancellation()
            if failure.networkCode != nil {
                throw RelayFailure(code: "uploadUnconfirmed",
                    message: readbackResponded ? "服务可以访问，但未核实到同一份摘要。本次上传仍待确认，请重新读取后同步。" : "本次摘要上传结果尚未确认。服务可能已保存，重试不会重复新增同一份摘要。",
                    reachedServer: readbackResponded, networkCode: failure.networkCode)
            }
            throw failure
        }
    }

    private struct ReadbackResult { let receipt: UploadReceipt? }

    private func storedReceipt(matching expected: HealthSnapshot, base: String) async throws -> ReadbackResult {
        var request = URLRequest(url: try Self.endpoint(base: base))
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        let (data, response) = try await responseData(request)
        guard response.statusCode == 200,
              let stored = try? HealthSnapshot.decoder.decode(StoredSnapshot.self, from: data),
              try HealthSnapshot.encoder.encode(stored.snapshot) == HealthSnapshot.encoder.encode(expected)
        else { return ReadbackResult(receipt: nil) }
        return ReadbackResult(receipt: UploadReceipt(receivedAt: stored.receivedAt, recoveredByReadback: true))
    }

    static func deleteRequest(base: String, allowLocalHTTP: Bool = allowsLocalHTTP) throws -> URLRequest {
        var request = URLRequest(url: try endpoint(base: base, allowLocalHTTP: allowLocalHTTP))
        request.httpMethod = "DELETE"
        request.timeoutInterval = 30
        return request
    }

    func delete(base: String) async throws {
        let tracker = await RelayStatusStore.shared
        let attempt = await tracker.begin(.delete, base: base)
        do {
            let (_, response) = try await responseData(Self.deleteRequest(base: base))
            try Self.validateSnapshotResponse(response)
            await tracker.succeed(attempt)
        } catch {
            await tracker.fail(attempt, error: error)
            throw error
        }
    }

    /// Read-only probe. A successful probe is evidence of reachability, NOT upload completion.
    func checkConnection(base: String) async throws {
        let tracker = await RelayStatusStore.shared
        let attempt = await tracker.begin(.check, base: base)
        do {
            let root = try Self.endpoint(base: base).deletingLastPathComponent().deletingLastPathComponent()
            var request = URLRequest(url: root.appendingPathComponent("healthz"))
            request.timeoutInterval = 10
            let (data, response) = try await responseData(request)
            try Self.validateSnapshotResponse(response)
            struct Health: Decodable { let status: String; let apiVersion: Int }
            guard let health = try? JSONDecoder().decode(Health.self, from: data), health.status == "ok", health.apiVersion == 1 else {
                throw RelayFailure(code: "invalidService", message: "地址有响应，但不是预期的健康同步服务。", reachedServer: true)
            }
            await tracker.succeed(attempt)
        } catch {
            await tracker.fail(attempt, error: error)
            throw error
        }
    }

    // Shared by snapshot and history: same cancellation/error classification, no cookies/cache.
    func responseData(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let config = configuration.copy() as! URLSessionConfiguration
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let result: (Data, URLResponse)
        do { result = try await session.data(for: request) }
        catch { throw RelayFailure.transport(error) }
        guard let http = result.1 as? HTTPURLResponse else {
            throw RelayFailure(code: "invalidResponse", message: "同步服务返回了无法识别的响应。", reachedServer: true)
        }
        return (result.0, http)
    }

    private static func validateSnapshotResponse(_ http: HTTPURLResponse) throws {
        switch http.statusCode {
        case 200..<300: return
        case 401, 403: throw RelayFailure(code: "unauthorized", message: "服务已响应但拒绝请求，请确认使用免 Token 后端及正确的访问地址。", reachedServer: true)
        case 409: throw RelayFailure(code: "stale", message: "服务已有更新或不同内容的摘要，请重新读取健康数据后同步。", reachedServer: true)
        case 400, 413, 422: throw RelayFailure(code: "invalidSnapshot", message: "服务未接受此摘要，请更新 App 与服务到同一版本并导出诊断。", reachedServer: true)
        case 300..<400: throw RelayFailure(code: "redirectBlocked", message: "服务发生重定向，请直接填写最终地址；未向其他地址转发健康信息。", reachedServer: true)
        default: throw RelayFailure(code: "http\(http.statusCode)", message: "服务已响应但未完成请求（HTTP \(http.statusCode)）。", reachedServer: true)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
