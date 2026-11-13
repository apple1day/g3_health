import SwiftUI

/// Shared on the dashboard and Settings; history networking updates the same observable store.
struct RelayStatusView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var tracker = RelayStatusStore.shared
    private var state: RelaySyncState { tracker.state }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(state.headline, systemImage: state.contactUnconfirmed ? "clock.badge.exclamationmark" : "arrow.up.arrow.down.circle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(state.contactUnconfirmed ? Color.orange : Palette.mint)
                Spacer()
                if state.isBusy { ProgressView().scaleEffect(0.8) }
            }
            if let date = state.lastContactAt {
                Text("最近响应：\(date.formatted(date: .abbreviated, time: .standard))").font(.caption).foregroundStyle(.secondary)
            }
            if let date = state.lastSnapshotAt {
                Text("摘要上传已确认：\(date.formatted(date: .abbreviated, time: .standard))").font(.caption)
                if let current = model.realSnapshot, let sent = state.snapshotGeneratedAt, current.generatedAt > sent {
                    Text("本机已有更新摘要，尚未确认上传。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("每日摘要：本次打开后尚无上传确认。").font(.caption).foregroundStyle(.secondary)
            }
            if let date = state.lastHistoryBatchAt {
                Text("历史批次已确认：\(date.formatted(date: .abbreviated, time: .standard))").font(.caption)
                Text("表示最近一批已保存；全量完成情况请看“历史”页。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(RelaySyncState.Operation.allCases, id: \.rawValue) { operation in
                if let text = state.detail(for: operation) {
                    Text(text).font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button(model.isCheckingConnection ? "正在检查…" : "检查服务连接") {
                Task { await model.checkConnection() }
            }.font(.caption).disabled(model.isCheckingConnection || !model.serverConfigured)
            Text("本机读取、摘要上传和历史同步分别确认；连接检查不会上传数据。")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("relay-sync-status")
    }
}
