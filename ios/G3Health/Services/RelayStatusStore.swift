import Foundation
import Combine

@MainActor
final class RelayStatusStore: ObservableObject {
    static let shared = RelayStatusStore()
    @Published private(set) var state = RelaySyncState()

    func configure(_ base: String) { state.configure(base) }
    func begin(_ operation: RelaySyncState.Operation, base: String) -> RelaySyncState.Attempt? {
        state.begin(operation, base: base)
    }
    func succeed(_ attempt: RelaySyncState.Attempt?, snapshot: Date? = nil) {
        guard let attempt else { return }
        state.succeed(attempt, snapshot: snapshot)
    }
    func fail(_ attempt: RelaySyncState.Attempt?, error: Error) {
        guard let attempt else { return }
        let failure = error as? RelayFailure ?? (error is CancellationError ? RelayFailure.transport(error) : RelayFailure(code: "invalidResponse", message: "服务响应未能验证，请更新 App 与后端后重试。", reachedServer: true))
        state.fail(attempt, code: failure.code, message: failure.message,
                   transport: failure.isTransportFailure, networkCode: failure.networkCode, responseReceived: failure.reachedServer)
    }
}
