import Foundation

struct RelayFailure: LocalizedError {
    let code: String
    let message: String
    var errorDescription: String? { message }
}

/// A scoped bearer token never enters a URL or a redirected request.
final class RelayClient: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
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

    static func validateToken(_ value: String) throws -> String {
        let token = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (32...256).contains(token.count), token.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else {
            throw RelayFailure(code: "invalidToken", message: "请填写服务生成的 UPLOAD_TOKEN（至少 32 位），不要填写 READ_TOKEN。")
        }
        return token
    }

    static func uploadRequest(snapshot: HealthSnapshot, base: String, token: String,
                              allowLocalHTTP: Bool = allowsLocalHTTP) throws -> URLRequest {
        guard snapshot.dataMode == .healthkit else {
            throw RelayFailure(code: "demoBlocked", message: "演示数据不能上传，请先读取 Apple 健康。")
        }
        guard !snapshot.hasQueryError else {
            throw RelayFailure(code: "queryIncomplete", message: "有健康数据尚未读取完成，请解锁并刷新后再同步。")
        }
        var request = URLRequest(url: try endpoint(base: base, allowLocalHTTP: allowLocalHTTP))
        request.httpMethod = "PUT"
        request.setValue("Bearer " + (try validateToken(token)), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try HealthSnapshot.encoder.encode(snapshot)
        request.timeoutInterval = 15
        return request
    }

    func upload(_ snapshot: HealthSnapshot, base: String, token: String) async throws {
        try await execute(Self.uploadRequest(snapshot: snapshot, base: base, token: token))
    }

    func delete(base: String, token: String) async throws {
        var request = URLRequest(url: try Self.endpoint(base: base))
        request.httpMethod = "DELETE"
        request.setValue("Bearer " + (try Self.validateToken(token)), forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        try await execute(request)
    }

    private func execute(_ request: URLRequest) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let response: URLResponse
        do { (_, response) = try await session.data(for: request) }
        catch {
            throw RelayFailure(code: "network", message: "无法连接同步服务。请检查地址、同一 Wi-Fi、证书和本地网络权限后重试。")
        }
        guard let http = response as? HTTPURLResponse else {
            throw RelayFailure(code: "invalidResponse", message: "同步服务返回了无法识别的响应。")
        }
        switch http.statusCode {
        case 200..<300: return
        case 401, 403: throw RelayFailure(code: "unauthorized", message: "同步令牌不正确或角色不匹配，请核对 UPLOAD_TOKEN。")
        case 409: throw RelayFailure(code: "stale", message: "服务已有更新的数据，请重新读取健康数据后再同步，并检查手机时间。")
        case 400, 413, 422: throw RelayFailure(code: "invalidSnapshot", message: "服务未接受此摘要，请更新 App 与服务到同一版本并导出诊断。")
        case 300..<400: throw RelayFailure(code: "redirectBlocked", message: "服务发生了重定向，请直接填写最终 HTTPS 地址。")
        default: throw RelayFailure(code: "http\(http.statusCode)", message: "同步服务暂时不可用（HTTP \(http.statusCode)）。")
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
