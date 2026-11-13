import Foundation

/// Request-scoped evidence, not a long-lived "connected" flag. HealthKit reads are independent.
struct RelaySyncState {
    enum Operation: String, CaseIterable, Sendable {
        case snapshot, historyUpload, historyRead, check, delete
        var title: String {
            switch self {
            case .snapshot: return "每日摘要"
            case .historyUpload: return "历史批次"
            case .historyRead: return "历史查询"
            case .check: return "连接检查"
            case .delete: return "删除请求"
            }
        }
    }
    struct Attempt: Equatable, Sendable {
        let generation: Int
        let sequence: Int
        let operation: Operation
    }
    struct Issue: Sendable {
        let sequence: Int
        let code: String
        let message: String
        let transport: Bool
        let networkCode: Int?
    }

    private(set) var endpoint = ""
    private(set) var generation = 0
    private var sequence = 0
    private var active: [Operation: Attempt] = [:]
    private(set) var issues: [Operation: Issue] = [:]
    private(set) var lastContactAt: Date?
    private(set) var lastContactSequence = 0
    private(set) var lastSnapshotAt: Date?
    private(set) var snapshotGeneratedAt: Date?
    private(set) var lastHistoryBatchAt: Date?
    var isBusy: Bool { !active.isEmpty }
    var configured: Bool { !endpoint.isEmpty }
    var contactUnconfirmed: Bool {
        issues.values.contains { $0.transport && $0.sequence > lastContactSequence }
    }
    var headline: String {
        if !configured { return "尚未配置同步服务" }
        if isBusy { return "正在与服务通信…" }
        if contactUnconfirmed { return "最近请求未获确认" }
        if lastContactAt != nil { return "服务最近已响应" }
        return "服务地址已保存，尚未验证"
    }

    static func normalized(_ base: String) -> String {
        guard var parts = URLComponents(string: base.trimmingCharacters(in: .whitespacesAndNewlines)) else { return base }
        parts.scheme = parts.scheme?.lowercased()
        parts.host = parts.host?.lowercased()
        if parts.path == "/" { parts.path = "" }
        if (parts.scheme == "http" && parts.port == 80) || (parts.scheme == "https" && parts.port == 443) { parts.port = nil }
        return parts.string ?? base
    }

    mutating func configure(_ base: String) {
        let value = Self.normalized(base)
        guard value != endpoint else { return }
        generation += 1
        endpoint = value
        active.removeAll(); issues.removeAll()
        lastContactAt = nil; lastContactSequence = 0
        lastSnapshotAt = nil; snapshotGeneratedAt = nil; lastHistoryBatchAt = nil
    }

    mutating func begin(_ operation: Operation, base: String) -> Attempt? {
        // A late task for a previous address must not reconfigure the active service.
        guard configured, Self.normalized(base) == endpoint else { return nil }
        sequence += 1
        let attempt = Attempt(generation: generation, sequence: sequence, operation: operation)
        active[operation] = attempt
        issues.removeValue(forKey: operation)
        return attempt
    }
    func isCurrent(_ attempt: Attempt) -> Bool {
        attempt.generation == generation && active[attempt.operation] == attempt
    }
    mutating func succeed(_ attempt: Attempt, at: Date = Date(), snapshot: Date? = nil) {
        guard isCurrent(attempt) else { return }
        active.removeValue(forKey: attempt.operation)
        issues.removeValue(forKey: attempt.operation)
        // Sequence numbers refer to request starts: an old completion cannot undo newer evidence.
        if attempt.sequence >= lastContactSequence {
            lastContactAt = at; lastContactSequence = attempt.sequence
        }
        switch attempt.operation {
        case .snapshot: lastSnapshotAt = at; snapshotGeneratedAt = snapshot
        case .historyUpload: lastHistoryBatchAt = at
        case .delete:
            generation += 1
            active.removeAll(); issues.removeAll()
            lastSnapshotAt = nil; snapshotGeneratedAt = nil; lastHistoryBatchAt = nil
        case .historyRead, .check: break
        }
    }
    mutating func fail(_ attempt: Attempt, code: String, message: String,
                       transport: Bool, networkCode: Int? = nil, responseReceived: Bool = false, at: Date = Date()) {
        guard isCurrent(attempt) else { return }
        active.removeValue(forKey: attempt.operation)
        if code == "cancelled" { return } // Cancellation does not mean the server is unreachable.
        issues[attempt.operation] = Issue(sequence: attempt.sequence, code: code,
            message: message, transport: transport, networkCode: networkCode)
        if responseReceived && attempt.sequence >= lastContactSequence {
            lastContactAt = at; lastContactSequence = attempt.sequence
        }
    }
    func detail(for operation: Operation) -> String? {
        guard let issue = issues[operation] else { return nil }
        if issue.transport && issue.sequence < lastContactSequence {
            return "\(operation.title)上次未获确认；之后服务已有响应。可重试该项，已保存数据不会被撤回。"
        }
        return "\(operation.title)：\(issue.message)"
    }
}
