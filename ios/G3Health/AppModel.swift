import Foundation
import Combine
import UIKit

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    private let health = HealthKitService()
    private let relay = RelayClient()
    private let tokenStore = TokenStore()
    private let cache = SnapshotCache()
    private let defaults = UserDefaults.standard

    @Published private(set) var realSnapshot: HealthSnapshot?
    @Published private(set) var isDemo = false
    @Published private(set) var isCached = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var isAuthorizing = false
    @Published private(set) var isUploading = false
    @Published private(set) var hasRequestedReadAccess = false
    @Published private(set) var backgroundEnabled = false
    @Published private(set) var serverURL = ""
    @Published private(set) var hasToken = false
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
    var serverConfigured: Bool { !serverURL.isEmpty && hasToken }
    var mayUpload: Bool { !isDemo && !isCached && realSnapshot != nil && serverConfigured && !isRefreshing && !isUploading }

    private init() {
        hasRequestedReadAccess = defaults.bool(forKey: "health.requestedReadAccess")
        backgroundEnabled = defaults.bool(forKey: "health.backgroundEnabled")
        autoUpload = defaults.bool(forKey: "relay.autoUpload")
        serverURL = defaults.string(forKey: "relay.baseURL") ?? ""
        hasToken = tokenStore.read() != nil
        realSnapshot = cache.read()
        isCached = realSnapshot != nil
        lastUploadAt = defaults.object(forKey: "relay.lastUploadAt") as? Date
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

    func savedToken() -> String { tokenStore.read() ?? "" }

    func saveConnection(base: String, token: String) {
        do {
            _ = try RelayClient.endpoint(base: base)
            let clean = try RelayClient.validateToken(token)
            try tokenStore.save(clean)
            serverURL = base.trimmingCharacters(in: .whitespacesAndNewlines)
            defaults.set(serverURL, forKey: "relay.baseURL")
            hasToken = true
            notice = "同步配置已保存；点击“同步到眼镜服务”发送摘要。"
            errorMessage = nil
        } catch let error as RelayFailure { errorMessage = error.message; lastFailureCode = error.code }
        catch { errorMessage = "令牌无法保存到钥匙串，请解锁手机后重试。"; lastFailureCode = "keychain" }
    }

    func disconnect() {
        autoUpload = false
        tokenStore.delete()
        serverURL = ""; hasToken = false
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
        guard !isUploading, !isDemo, let token = tokenStore.read() else { return }
        isUploading = true
        defer { isUploading = false }
        do {
            try await relay.upload(snapshot, base: serverURL, token: token)
            lastUploadAt = Date()
            defaults.set(lastUploadAt, forKey: "relay.lastUploadAt")
            notice = "摘要已同步。可在眼镜插件中刷新查看。"
            lastFailureCode = nil; errorMessage = nil
        } catch let error as RelayFailure { lastFailureCode = error.code; errorMessage = error.message }
        catch { lastFailureCode = "uploadFailed"; errorMessage = "摘要同步失败，请稍后重试。" }
    }

    func deleteRemote() async {
        guard !isUploading, let token = tokenStore.read() else { return }
        autoUpload = false
        isUploading = true
        defer { isUploading = false }
        do {
            try await relay.delete(base: serverURL, token: token)
            notice = "服务端摘要已删除，自动上传已关闭。Apple 健康原始数据保持不变。"
            errorMessage = nil
            lastUploadAt = nil
            defaults.removeObject(forKey: "relay.lastUploadAt")
        } catch let error as RelayFailure { lastFailureCode = error.code; errorMessage = error.message }
        catch { lastFailureCode = "deleteFailed"; errorMessage = "未能删除服务端摘要，请稍后重试。" }
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
            "autoUploadEnabled": autoUpload,
            "backgroundDeliveryEnabled": backgroundEnabled,
            "lastFailureCode": lastFailureCode ?? "none"
        ]
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
