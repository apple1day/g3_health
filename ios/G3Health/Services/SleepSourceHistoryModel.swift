import Foundation
import HealthKit
import Combine

@MainActor
final class SleepSourceHistoryModel: ObservableObject {
    @Published private(set) var sources: [SleepHistorySource] = []
    @Published private(set) var records: [HealthHistoryRecord] = []
    @Published private(set) var isScanning = false
    @Published private(set) var isComplete = false
    @Published private(set) var progress = "读取 Apple 健康中实际可访问的睡眠来源；不需要连接服务器。"
    @Published private(set) var errorMessage: String?
    @Published private(set) var scannedAt: Date?
    @Published var selectedSourceID: String?

    typealias ReadPage = (HKQueryAnchor?) async throws -> HealthHistoryReader.Page
    private let requestAccess: () async throws -> Void
    private let readPage: ReadPage
    private var stopRequested = false

    init() {
        let reader = HealthHistoryReader()
        requestAccess = {
            guard HKHealthStore.isHealthDataAvailable(),
                  let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { throw HealthFailure.unavailable }
            try await HKHealthStore().requestAuthorization(toShare: [], read: Set<HKObjectType>([sleep]))
        }
        readPage = { try await reader.page(kind: .sleep, anchor: $0) }
    }

    /// Injectable boundaries keep pagination and cancellation testable without a real health store.
    init(requestAccess: @escaping () async throws -> Void, readPage: @escaping ReadPage) {
        self.requestAccess = requestAccess
        self.readPage = readPage
    }

    var selectedSource: SleepHistorySource? { sources.first { $0.sourceID == selectedSourceID } }
    var selectedRecords: [HealthHistoryRecord] {
        guard let id = selectedSourceID else { return [] }
        return records.filter { $0.sourceID == id }
    }
    var selectedDays: [SleepHistoryDay] {
        guard let id = selectedSourceID else { return [] }
        return SleepHistoryCatalog.days(records: records, sourceID: id)
    }

    func stop() {
        guard isScanning else { return }
        stopRequested = true
        progress = "正在停止，当前查询结束后保留已读记录。"
    }

    func scan() async {
        guard !isScanning else { return }
        let previousSelection = selectedSourceID
        isScanning = true; stopRequested = false; isComplete = false; errorMessage = nil; scannedAt = nil
        records = []; sources = []
        var catalog = SleepHistoryCatalog()
        var anchor: HKQueryAnchor?
        var pageCount = 0
        progress = "检查睡眠读取权限…"
        defer { isScanning = false }
        do {
            try await requestAccess()
            while !shouldStop {
                let page = try await readPage(anchor)
                catalog.apply(records: page.records, deletedIDs: page.deletedIDs)
                anchor = page.anchor
                pageCount += 1
                // Publishing periodically avoids repeatedly sorting a large multi-year history.
                if pageCount == 1 || pageCount % 10 == 0 || page.returnedCount == 0 || shouldStop {
                    publish(catalog)
                }
                progress = "已读到 \(catalog.count) 条睡眠样本；正在查询更早或后续记录…"
                if page.returnedCount == 0 {
                    if !shouldStop {
                        isComplete = true
                        scannedAt = Date()
                    }
                    break
                }
            }
            publish(catalog)
            selectedSourceID = sources.contains(where: { $0.sourceID == previousSelection })
                ? previousSelection : sources.first?.sourceID
            if isComplete {
                progress = catalog.count == 0
                    ? "本次没有读到睡眠样本。可能尚未共享、读取未获授权，或当前可访问范围没有数据。"
                    : "本次扫描完成：\(sources.count) 个来源、\(catalog.count) 条可读取睡眠样本。日期范围不代表 OPPO 云端全部历史。"
            } else {
                progress = "扫描已停止，目前显示 \(catalog.count) 条已读样本，尚未完成全部可读范围。再次扫描将从头核对。"
            }
        } catch is CancellationError {
            publish(catalog)
            progress = "扫描已停止，目前显示 \(catalog.count) 条已读样本，尚未完成全部可读范围。再次扫描将从头核对。"
        } catch {
            publish(catalog)
            progress = "扫描未完成；已读到 \(catalog.count) 条样本。"
            errorMessage = "无法完成睡眠读取。请保持 iPhone 解锁，检查苹果健康中的睡眠读取设置后重试；这不能判断 OPPO App 或云端是否有历史数据。"
        }
    }

    func exportJSON() throws -> Data {
        guard isComplete, let source = selectedSource, let scannedAt else { throw SleepSourceExportError.incomplete }
        return try SleepHistoryExport.json(records: records, source: source, scannedAt: scannedAt)
    }

    func exportCSV() -> Data {
        guard isComplete, let source = selectedSource else { return Data() }
        return SleepHistoryExport.csv(records: records, sourceID: source.sourceID)
    }

    private var shouldStop: Bool { stopRequested || Task.isCancelled }

    private func publish(_ catalog: SleepHistoryCatalog) {
        records = catalog.records
        sources = catalog.sources
        if !sources.contains(where: { $0.sourceID == selectedSourceID }) {
            selectedSourceID = sources.first?.sourceID
        }
    }
}

enum SleepSourceExportError: Error { case incomplete }
