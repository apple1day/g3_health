import Foundation
import HealthKit
import Combine
import UIKit

@MainActor
final class HistorySyncModel: ObservableObject {
    static let shared = HistorySyncModel()
    @Published private(set) var isRunning = false
    @Published private(set) var progress = "尚未同步历史。首次不限定日期，以后读取新增与删除记录。"
    @Published private(set) var errorMessage: String?
    @Published private(set) var loadError: String?
    @Published private(set) var processed = 0
    @Published private(set) var completedTypes = 0
    @Published private(set) var status: HealthHistoryStatus?
    @Published private(set) var rows: [HealthHistoryRow] = []
    @Published private(set) var nextCursor = ""
    @Published private(set) var total = 0
    @Published private(set) var loading = false
    private let reader = HealthHistoryReader()
    private let relay = RelayClient()
    private var stopRequested = false
    private var generation = 0
    private var pageScope = ""
    private var checkpointURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("history-checkpoint-v1.json")
    }
    func pause() { stopRequested = true }
    func invalidateView() { generation += 1; rows = []; nextCursor = ""; total = 0; status = nil; loading = false }
    private func readCheckpoint() -> HistoryCheckpoint {
        guard let data = try? Data(contentsOf: checkpointURL), let value = try? JSONDecoder().decode(HistoryCheckpoint.self, from: data) else { return HistoryCheckpoint() }
        return value
    }
    private func save(_ value: HistoryCheckpoint) throws {
        let url = checkpointURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: url, options: [.atomic, .completeFileProtection])
        var privateURL = url; var options = URLResourceValues(); options.isExcludedFromBackup = true
        try privateURL.setResourceValues(options)
    }
    func synchronize(base: String, rescan: Bool = false) async {
        guard !isRunning else { return }
        isRunning = true; stopRequested = false; errorMessage = nil; processed = 0; completedTypes = 0
        let oldIdle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { isRunning = false; UIApplication.shared.isIdleTimerDisabled = oldIdle }
        do {
            guard UIApplication.shared.isProtectedDataAvailable else { throw RelayFailure(code: "locked", message: "请解锁 iPhone 后同步历史。") }
            let endpoint = try RelayClient.endpoint(base: base).deletingLastPathComponent().deletingLastPathComponent().absoluteString
            progress = "检查历史接口…"
            let initial: HealthHistoryStatus = try await relay.historyGET(base: base, path: "history/status")
            status = initial
            var checkpoint = readCheckpoint()
            checkpoint.prepare(endpoint: endpoint, epoch: initial.epoch, rescan: rescan)
            try save(checkpoint)
            try await HealthKitService().requestReadAccess()
            for kind in HistoryKind.allCases {
                if shouldPause { break }
                progress = "\(kind.title)：正在读取；已处理 \(processed) 条变更"
                if kind == .activitySummary {
                    // Activity summaries have no anchored-query API. Re-read and idempotently upsert each day.
                    let records = try await reader.activitySummaries()
                    for offset in stride(from: 0, to: records.count, by: 200) {
                        if shouldPause { break }
                        let page = Array(records[offset..<min(offset + 200, records.count)])
                        try await relay.uploadHistory(HealthHistoryBatch(epoch: initial.epoch, kind: kind.rawValue, records: page, deletedIDs: []), base: base)
                        processed += page.count
                        progress = "\(kind.title)：已处理 \(processed) 条变更"
                    }
                } else {
                    var anchor: HKQueryAnchor?
                    if let data = checkpoint.anchors[kind.rawValue] {
                        // Corrupt/incompatible local anchors safely fall back to an idempotent full scan.
                        anchor = try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
                    }
                    while !shouldPause {
                        let page = try await reader.page(kind: kind, anchor: anchor)
                        if page.returnedCount > 0 {
                            try await send(records: page.records, deleted: page.deletedIDs, kind: kind, epoch: initial.epoch, base: base)
                        }
                        // Advance ONLY after server acknowledgement; a lost response retries the same UUIDs.
                        checkpoint.anchors[kind.rawValue] = try NSKeyedArchiver.archivedData(withRootObject: page.anchor, requiringSecureCoding: true)
                        try save(checkpoint)
                        anchor = page.anchor; processed += page.returnedCount
                        progress = "\(kind.title)：已处理 \(processed) 条变更；完成 \(completedTypes)/8 类"
                        if page.returnedCount == 0 { break }
                    }
                }
                if shouldPause { break }
                completedTypes += 1
            }
            status = try await relay.historyGET(base: base, path: "history/status")
            progress = completedTypes < HistoryKind.allCases.count ? "已暂停，已确认批次已保存。再次同步可继续。" : "本轮完成 8 类查询，服务器共 \(status?.count ?? 0) 条记录。空类型可能无数据或未授权；这不代表获得了全部读取权限。"
        } catch let error as RelayFailure { errorMessage = error.message; progress = "同步中断，已成功的批次保留。修复后点击继续。" }
        catch { errorMessage = "历史读取或保存进度失败。请保持手机解锁，核对健康权限后重试；已确认的数据不会丢失。"; progress = "尚未完成全量历史同步。" }
    }
    private func send(records: [HealthHistoryRecord], deleted: [String], kind: HistoryKind, epoch: String, base: String) async throws {
        // Some HealthKit versions may deliver deletions separately from the sample limit.
        for offset in stride(from: 0, to: records.count, by: 200) {
            try await relay.uploadHistory(HealthHistoryBatch(epoch: epoch, kind: kind.rawValue,
                records: Array(records[offset..<min(offset+200,records.count)]), deletedIDs: []), base: base)
        }
        for offset in stride(from: 0, to: deleted.count, by: 200) {
            try await relay.uploadHistory(HealthHistoryBatch(epoch: epoch, kind: kind.rawValue,
                records: [], deletedIDs: Array(deleted[offset..<min(offset+200,deleted.count)])), base: base)
        }
    }
    private var shouldPause: Bool { stopRequested || UIApplication.shared.applicationState != .active }
    func load(base: String, kind: HistoryKind, more: Bool = false) async {
        let scope = base + "|" + kind.rawValue
        if more && (loading || pageScope != scope || nextCursor.isEmpty) { return }
        generation += 1; let g = generation
        let cursor = more ? nextCursor : ""
        if !more { rows = []; nextCursor = ""; total = 0; status = nil }
        pageScope = scope; loading = true; loadError = nil
        defer { if g == generation { loading = false } }
        do {
            let s: HealthHistoryStatus = try await relay.historyGET(base: base, path: "history/status")
            let p: HealthHistoryPage = try await relay.historyGET(base: base, path: "history/records", query: [URLQueryItem(name: "kind", value: kind.rawValue), URLQueryItem(name: "limit", value: "50"), URLQueryItem(name: "cursor", value: cursor)])
            guard g == generation else { return }
            status = s; rows = more ? rows + p.items : p.items; total = p.total; nextCursor = p.nextCursor
        } catch let e as RelayFailure { if g == generation { loadError = e.message } }
        catch { if g == generation { loadError = "历史记录读取失败，请检查后端版本及网络。" } }
    }
}
