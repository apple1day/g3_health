import Foundation

extension RelayClient {
    static func historyURL(base: String, path: String, query: [URLQueryItem] = [], allowLocalHTTP: Bool = allowsLocalHTTP) throws -> URL {
        guard ["history/status", "history/records", "history/batch"].contains(path) else {
            throw RelayFailure(code: "invalidURL", message: "无效的历史接口。")
        }
        let root = try endpoint(base: base, allowLocalHTTP: allowLocalHTTP).deletingLastPathComponent()
        var parts = URLComponents(url: root.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        parts.queryItems = query.isEmpty ? nil : query
        guard let url = parts.url else { throw RelayFailure(code: "invalidURL", message: "历史服务地址无效。") }
        return url
    }
    func historyGET<T: Decodable>(base: String, path: String, query: [URLQueryItem] = []) async throws -> T {
        var request = URLRequest(url: try Self.historyURL(base: base, path: path, query: query))
        request.timeoutInterval = 30
        return try HealthSnapshot.decoder.decode(T.self, from: await historyData(request))
    }
    static func historyUploadRequest(_ batch: HealthHistoryBatch, base: String, allowLocalHTTP: Bool = allowsLocalHTTP) throws -> URLRequest {
        guard batch.records.count + batch.deletedIDs.count <= 200 else { throw RelayFailure(code: "batchTooLarge", message: "历史批次过大。") }
        var request = URLRequest(url: try historyURL(base: base, path: "history/batch", allowLocalHTTP: allowLocalHTTP))
        request.httpMethod = "PUT"; request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let encoder = HealthSnapshot.encoder; encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        request.httpBody = try encoder.encode(batch)
        return request
    }
    func uploadHistory(_ batch: HealthHistoryBatch, base: String) async throws {
        _ = try await historyData(Self.historyUploadRequest(batch, base: base))
    }
    private func historyData(_ request: URLRequest) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let result: (Data, URLResponse)
        do { result = try await session.data(for: request) }
        catch { throw RelayFailure(code: "historyNetwork", message: "历史同步网络中断。请保持手机与 Mac 互通，再点击继续。") }
        guard let response = result.1 as? HTTPURLResponse else { throw RelayFailure(code: "historyResponse", message: "历史服务响应无法识别。") }
        switch response.statusCode {
        case 200..<300: return result.0
        case 404: throw RelayFailure(code: "historyUpgrade", message: "服务没有历史接口，请先拉取新版并运行 setup-backend.sh，重启 Go 服务。")
        case 409: throw RelayFailure(code: "historyReset", message: "服务器历史已重置，请再次点击同步，从头重建归档。")
        case 400, 413, 422: throw RelayFailure(code: "historyInvalid", message: "服务拒绝历史批次，请确认 App 与后端均为 0.4.0 或更新版本。")
        case 300..<400: throw RelayFailure(code: "redirectBlocked", message: "历史服务发生重定向，已停止传送健康信息。")
        default: throw RelayFailure(code: "historyHTTP", message: "历史服务暂不可用（HTTP \(response.statusCode)）。已确认批次保留。")
        }
    }
}
