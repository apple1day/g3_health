import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

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
        let tracker = await RelayStatusStore.shared
        let attempt = await tracker.begin(.historyRead, base: base)
        do {
            var request = URLRequest(url: try Self.historyURL(base: base, path: path, query: query))
            request.timeoutInterval = 30
            let data = try await historyData(request)
            guard let value = try? HealthSnapshot.decoder.decode(T.self, from: data) else {
                throw RelayFailure(code: "historyResponse", message: "历史服务已响应，但数据格式未通过验证。", reachedServer: true)
            }
            await tracker.succeed(attempt)
            return value
        } catch {
            await tracker.fail(attempt, error: error)
            throw error
        }
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
        let tracker = await RelayStatusStore.shared
        let attempt = await tracker.begin(.historyUpload, base: base)
        do {
            let data = try await historyData(Self.historyUploadRequest(batch, base: base))
            struct Receipt: Decodable { let accepted: Int; let deleted: Int; let epoch: String }
            guard let receipt = try? JSONDecoder().decode(Receipt.self, from: data),
                  receipt.accepted == batch.records.count, receipt.deleted == batch.deletedIDs.count,
                  receipt.epoch == batch.epoch else {
                throw RelayFailure(code: "historyReceipt", message: "历史批次回执未通过验证，进度未前移；已保存的数据可安全重试。", reachedServer: true)
            }
            await tracker.succeed(attempt)
        } catch {
            await tracker.fail(attempt, error: error)
            throw error
        }
    }
    private func historyData(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await responseData(request)
        switch response.statusCode {
        case 200..<300: return data
        case 404: throw RelayFailure(code: "historyUpgrade", message: "服务没有历史接口，请先拉取新版并运行 setup-backend.sh，重启 Go 服务。", reachedServer: true)
        case 409: throw RelayFailure(code: "historyReset", message: "服务器历史已重置，请再次点击同步，从头重建归档。", reachedServer: true)
        case 400, 413, 422: throw RelayFailure(code: "historyInvalid", message: "服务拒绝历史批次，请确认 App 与后端均为 0.4.0 或更新版本。", reachedServer: true)
        case 300..<400: throw RelayFailure(code: "redirectBlocked", message: "历史服务发生重定向，已停止传送健康信息。", reachedServer: true)
        default: throw RelayFailure(code: "historyHTTP", message: "历史服务已响应但请求未完成（HTTP \(response.statusCode)）。已确认批次保留。", reachedServer: true)
        }
    }
}
