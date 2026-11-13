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
        let failure = error as? RelayFailure ?? (error is CancellationError ? RelayFailure.transport(error) : RelayFailure(code: "requestPreparation", message: "本次请求未能完成准备或验证，请刷新数据后重试。"))
        state.fail(attempt, code: failure.code, message: failure.message,
                   transport: failure.isTransportFailure, networkCode: failure.networkCode, responseReceived: failure.reachedServer)
    }
}
