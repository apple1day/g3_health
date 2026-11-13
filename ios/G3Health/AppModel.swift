import Foundation
import Combine
import UIKit

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    private let health = HealthKitService()
    private let relay = RelayClient()
    private let cache = SnapshotCache()
    private let defaults = UserDefaults.standard

    @Published private(set) var realSnapshot: HealthSnapshot?
    @Published private(set) var isDemo = false
    @Published private(set) var isCached = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var isAuthorizing = false
    @Published private(set) var isUploading = false
    @Published private(set) var isCheckingConnection = false
    @Published private(set) var hasRequestedReadAccess = false
    @Published private(set) var backgroundEnabled = false
    @Published private(set) var serverURL = ""
    @Published var autoUpload = false {
        didSet { defaults.set(autoUpload, forKey: "relay.autoUpload") }
    }
    @Published var notice: String?
    @Published var errorMessage: String?
    @Published private(set) var lastQueryAt: Date?
    @Published private(set) var lastUploadAt: Date?
    @Published private(set) var diagnosticsURL: URL?
    private var demoSnapshot = HealthSnapshot.demo()
    private var lastFailureCode: String?

    var displayedSnapshot: HealthSnapshot? { isDemo ? demoSnapshot : realSnapshot }
    var healthAvailable: Bool { health.isAvailable }
    var serverConfigured: Bool { !serverURL.isEmpty }
    var mayUpload: Bool { !isDemo && !isCached && realSnapshot != nil && serverConfigured && !isRefreshing && !isUploading }

    private init() {
        hasRequestedReadAccess = defaults.bool(forKey: "health.requestedReadAccess")
        backgroundEnabled = defaults.bool(forKey: "health.backgroundEnabled")
        autoUpload = defaults.bool(forKey: "relay.autoUpload")
        serverURL = defaults.string(forKey: "relay.baseURL") ?? ""
        LegacyRelayCredential.remove()
        realSnapshot = cache.read()
        isCached = realSnapshot != nil
        // Old timestamps were not tied to a server address and are not proof of a current upload.
        defaults.removeObject(forKey: "relay.lastUploadAt")
        RelayStatusStore.shared.configure(serverURL)
    }

    func authorize() async {
        guard !isAuthorizing, !isRefreshing else { return }
        isAuthorizing = true; errorMessage = nil; notice = nil
        defer { isAuthorizing = false }
        do {
            try await health.requestReadAccess()
            hasRequestedReadAccess = true
            defaults.set(true, forKey: "health.requestedReadAccess")
            isDemo = false
            await refresh()
        } catch {
            lastFailureCode = "authorizationRequestFailed"
            errorMessage = health.isAvailable ? "无法打开健康读取授权，请检查系统设置后重试。" : "此设备不支持 Apple 健康。请连接 iPhone 真机，或使用演示模式。"
        }
    }

    func refresh(background: Bool = false) async {
        guard !isRefreshing, !isAuthorizing || !background else { return }
        if background && (isDemo || !backgroundEnabled) { return }
        if !UIApplication.shared.isProtectedDataAvailable {
            if !background { errorMessage = "请先解锁 iPhone，再读取健康数据。当前保留上次内容。" }
            lastFailureCode = "protectedDataUnavailable"
            return
        }
        isRefreshing = true
        if !background { isDemo = false; errorMessage = nil; notice = nil }
        defer { isRefreshing = false }
        let snapshot = await health.snapshot()
        lastQueryAt = Date()
        if snapshot.hasQueryError && realSnapshot != nil {
            isCached = true
            lastFailureCode = "healthQueryIncomplete"
            errorMessage = "部分健康数据暂未读取成功，已保留上次摘要。解锁手机后下拉刷新，或检查健康中的数据访问设置。"
            return
        }
        realSnapshot = snapshot
        isCached = false
        if snapshot.hasQueryError {
            lastFailureCode = "healthQueryIncomplete"
            errorMessage = "部分健康数据读取失败；已有结果已显示。请解锁手机后重试。"
        } else {
            lastFailureCode = nil
            if !background { notice = "读取完成。空白项目表示暂无可读取数据，不代表数值为零。" }
            do { try cache.write(snapshot) }
            catch { notice = "本次读取完成，但暂时无法保存本机缓存。" }
            if autoUpload && serverConfigured && !isDemo { await upload(snapshot: snapshot) }
        }
    }

    func foregroundRefresh() async {
        guard hasRequestedReadAccess, !isDemo, !isRefreshing, !isAuthorizing else { return }
        guard lastQueryAt.map({ Date().timeIntervalSince($0) >= 30 }) ?? true else { return }
        await refresh()
    }

    func showDemo() {
        guard !isRefreshing, !isAuthorizing else { return }
        demoSnapshot = .demo()
        isDemo = true
        notice = nil; errorMessage = nil
    }

    func leaveDemo() {
        isDemo = false
        notice = realSnapshot == nil ? "已退出演示，请连接 Apple 健康读取你的数据。" : "已回到本机健康摘要，可下拉刷新。"
    }

    func saveConnection(base: String) {
        guard !HistorySyncModel.shared.isRunning else { errorMessage = "请先暂停历史同步，再修改服务地址。"; return }
        do {
            _ = try RelayClient.endpoint(base: base)
            let next = base.trimmingCharacters(in: .whitespacesAndNewlines)
            if RelaySyncState.normalized(next) != RelaySyncState.normalized(serverURL) {
                lastUploadAt = nil
                HistorySyncModel.shared.invalidateView()
            }
            serverURL = next
            RelayStatusStore.shared.configure(serverURL)
            defaults.set(serverURL, forKey: "relay.baseURL")
            LegacyRelayCredential.remove()
            notice = "服务地址已保存；免 Token 模式，点击“同步到眼镜服务”发送摘要。"
            errorMessage = nil
            lastFailureCode = nil
        } catch let error as RelayFailure { errorMessage = error.message; lastFailureCode = error.code }
        catch { errorMessage = "服务地址无效，请检查后重试。"; lastFailureCode = "invalidURL" }
    }

    func disconnect() {
        guard !HistorySyncModel.shared.isRunning else { errorMessage = "请先暂停历史同步。"; return }
        HistorySyncModel.shared.invalidateView()
        autoUpload = false
        LegacyRelayCredential.remove()
        serverURL = ""
        RelayStatusStore.shared.configure("")
        lastUploadAt = nil
        errorMessage = nil; lastFailureCode = nil
        defaults.removeObject(forKey: "relay.baseURL")
        notice = "已移除本机同步配置。服务端旧摘要如需删除，请先使用原配置执行删除。"
    }

    func uploadNow() async {
        guard !isDemo else { errorMessage = "演示数据不会上传，请先读取 Apple 健康。"; return }
        guard !isCached else { errorMessage = "请先刷新真实数据，再同步到服务。"; return }
        guard let snapshot = realSnapshot else { errorMessage = "请先读取 Apple 健康。"; return }
        await upload(snapshot: snapshot)
    }

    private func upload(snapshot: HealthSnapshot) async {
        guard !isUploading, !isDemo else { return }
        guard serverConfigured else { errorMessage = "请先在设置中保存同步服务地址。"; return }
        isUploading = true
        let base = serverURL
        let generation = RelayStatusStore.shared.state.generation
        defer { isUploading = false }
        do {
            let receipt = try await relay.upload(snapshot, base: base)
            guard generation == RelayStatusStore.shared.state.generation else { return }
            lastUploadAt = receipt.receivedAt
            notice = receipt.recoveredByReadback ? "已回查服务器，确认这份摘要已保存。" : "摘要已获服务端确认。可在眼镜插件中刷新查看。"
            // Do not clear an unrelated HealthKit failure produced while this request was in flight.
        } catch {
            // RelayStatusStore owns request-scoped failures for BOTH summary and history.
            // A failed request must not leave a global "cannot connect" banner after recovery.
            guard generation == RelayStatusStore.shared.state.generation else { return }
            notice = nil
        }
    }

    func checkConnection() async {
        guard serverConfigured, !isCheckingConnection else { return }
        isCheckingConnection = true
        defer { isCheckingConnection = false }
        do { try await relay.checkConnection(base: serverURL) }
        catch { /* The shared request state displays the precise result; never mark an upload successful. */ }
    }

    func deleteRemote() async {
        guard !isUploading, serverConfigured, !HistorySyncModel.shared.isRunning else { errorMessage = "请先暂停历史同步后再删除。"; return }
        autoUpload = false
        isUploading = true
        let base = serverURL
        defer { isUploading = false }
        do {
            try await relay.delete(base: base)
            guard RelaySyncState.normalized(base) == RelaySyncState.normalized(serverURL) else { return }
            HistorySyncModel.shared.invalidateView()
            notice = "服务端全部摘要与原始历史已删除，自动上传已关闭。Apple 健康原始数据保持不变。"
            lastUploadAt = nil
            defaults.removeObject(forKey: "relay.lastUploadAt")
        } catch { notice = nil }
    }

    func setupBackgroundAtLaunch() {
        guard backgroundEnabled, hasRequestedReadAccess else { return }
        health.installObservers { [weak self] in await self?.refresh(background: true) }
    }

    func setBackgroundEnabled(_ enabled: Bool) async {
        if enabled {
            guard hasRequestedReadAccess else { errorMessage = "请先完成一次 Apple 健康读取授权。"; return }
            do {
                health.installObservers { [weak self] in await self?.refresh(background: true) }
                try await health.enableBackgroundDelivery()
                backgroundEnabled = true
                defaults.set(true, forKey: "health.backgroundEnabled")
                notice = "已请求后台更新。实际送达由系统决定，锁屏时可能延后；打开 App 仍会主动刷新。"
            } catch {
                await health.disableBackgroundDelivery()
                backgroundEnabled = false
                defaults.set(false, forKey: "health.backgroundEnabled")
                errorMessage = "后台更新未能启用。请检查 HealthKit Background Delivery 签名能力；前台读取仍可使用。"
                lastFailureCode = "backgroundDelivery"
            }
        } else {
            backgroundEnabled = false
            defaults.set(false, forKey: "health.backgroundEnabled")
            await health.disableBackgroundDelivery()
        }
    }

    func clearLocalCache() {
        cache.delete()
        realSnapshot = nil; isCached = false
        diagnosticsURL = nil
        notice = "本机摘要缓存已清除。下次读取会重新生成。"
    }

    func exportDiagnostics() {
        // Intentionally no metric values, sample times, source names, server URL, identifiers or tokens.
        var report: [String: Any] = [
            "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            "build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
            "osVersion": UIDevice.current.systemVersion,
            "healthKitAvailable": healthAvailable,
            "readAuthorizationRequested": hasRequestedReadAccess,
            "readAuthorizationResult": "not_disclosed_by_HealthKit",
            "displayMode": isDemo ? "demo" : "healthkit",
            "displayingCache": isCached,
            "relayConfigured": serverConfigured,
            "relayAuthMode": "none",
            "autoUploadEnabled": autoUpload,
            "backgroundDeliveryEnabled": backgroundEnabled,
            "lastFailureCode": lastFailureCode ?? "none"
        ]
        let sync = RelayStatusStore.shared.state
        report["relayContactConfirmedThisSession"] = sync.lastContactAt != nil
        report["snapshotConfirmedThisSession"] = sync.lastSnapshotAt != nil
        report["historyBatchConfirmedThisSession"] = sync.lastHistoryBatchAt != nil
        report["relayRequestIssues"] = sync.issues.mapValues { issue -> [String: Any] in
            var value: [String: Any] = ["code": issue.code, "transport": issue.transport]
            if let code = issue.networkCode { value["urlErrorCode"] = code }
            return value
        }.reduce(into: [String: [String: Any]]()) { $0[$1.key.rawValue] = $1.value }
        if let snapshot = realSnapshot {
            report["sectionStatuses"] = ["sleep": snapshot.sleep.status.rawValue,
                "activity": snapshot.activity.status.rawValue, "heartRate": snapshot.heartRate.status.rawValue,
                "workout": snapshot.workout.status.rawValue]
        }
        let formatter = ISO8601DateFormatter()
        report["exportedAt"] = formatter.string(from: Date())
        if let lastQueryAt { report["lastQueryAttemptAt"] = formatter.string(from: lastQueryAt) }
        if let lastUploadAt { report["lastUploadAt"] = formatter.string(from: lastUploadAt) }
        do {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("G3Health-diagnostics.json")
            try data.write(to: file, options: [.atomic, .completeFileProtection])
            diagnosticsURL = file
        } catch { errorMessage = "暂时无法生成诊断文件，请稍后重试。" }
    }
}
