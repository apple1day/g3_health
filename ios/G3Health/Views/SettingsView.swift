import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var baseURL = ""
    @State private var showDeleteConfirmation = false
    @State private var showCacheConfirmation = false
    @State private var showDisconnectConfirmation = false

    var body: some View {
        NavigationStack {
            Form {
                if let message = model.errorMessage {
                    Section { Label(message, systemImage: "exclamationmark.circle").foregroundStyle(.orange) }
                } else if let message = model.notice {
                    Section { Label(message, systemImage: "info.circle").foregroundStyle(Palette.mint) }
                }
                Section {
                    TextField("https://health.example.com", text: $baseURL)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityLabel("同步服务根地址")
                    Button("保存同步配置") { model.saveConnection(base: baseURL) }
                    Button {
                        Task { await model.uploadNow() }
                    } label: {
                        HStack {
                            Text(model.isUploading ? "正在同步…" : "同步到眼镜服务")
                            Spacer()
                            if model.isUploading { ProgressView() }
                        }
                    }.disabled(!model.mayUpload)
                    if let date = model.lastUploadAt {
                        LabeledContent("上次上传", value: date.formatted(date: .abbreviated, time: .shortened))
                    }
                } header: { Text("眼镜同步") } footer: {
                    Text("只填写服务根地址，无需 Token 或登录。当前仅适合可信局域网：能访问服务的人也能查看、上传或删除健康数据，请勿映射公网。Debug 版支持局域网 HTTP，正式版仍要求 HTTPS。")
                }

                Section {
                    Toggle("读取完成后自动上传", isOn: $model.autoUpload).disabled(!model.serverConfigured)
                    Toggle("请求后台健康更新", isOn: Binding(
                        get: { model.backgroundEnabled },
                        set: { enabled in Task { await model.setBackgroundEnabled(enabled) } }
                    ))
                } header: { Text("更新方式") } footer: {
                    Text("自动上传仅发送真实健康摘要，演示数据始终禁止上传。后台更新请求为每小时最多一次，实际时间由 iOS 和健康数据同步决定；锁屏时可能延后。回到 App 会主动刷新。")
                }

                Section {
                    Button("查看或补充健康读取授权") { Task { await model.authorize() } }
                        .disabled(model.isAuthorizing || model.isRefreshing)
                    Button("打开系统设置") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    Button(model.isDemo ? "退出演示模式" : "查看演示数据") {
                        if model.isDemo { model.leaveDemo() } else { model.showDemo() }
                        dismiss()
                    }.disabled(model.isRefreshing || model.isAuthorizing)
                } header: { Text("Apple 健康") } footer: {
                    Text("系统不向 App 透露每种读取权限是否被拒绝。没有数据时，请到“健康”App → 头像 → App 与服务 → 健康速览，核对所需读取权限，并确认 Apple Watch 已完成同步。本 App 不写入或删除 Apple 健康记录。")
                }

                Section {
                    LabeledContent("版本", value: "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.3.0") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "3"))")
                    LabeledContent("HealthKit 可用", value: model.healthAvailable ? "是" : "否，请用真机测试")
                    Button("生成脱敏诊断文件") { model.exportDiagnostics() }
                    if let file = model.diagnosticsURL {
                        ShareLink(item: file) { Label("分享诊断文件", systemImage: "square.and.arrow.up") }
                    }
                } header: { Text("测试与诊断") } footer: {
                    Text("诊断只包含 App/系统版本、查询状态和同步结果分类，不包含健康数值、睡眠时间段、服务地址或令牌。可把生成的 JSON 发回来排查问题。")
                }

                Section {
                    Button("删除服务端全部历史", role: .destructive) { showDeleteConfirmation = true }
                        .disabled(!model.serverConfigured || model.isUploading)
                    Button("移除本机同步配置", role: .destructive) { showDisconnectConfirmation = true }
                        .disabled(!model.serverConfigured || model.isUploading)
                    Button("清除本机摘要缓存", role: .destructive) { showCacheConfirmation = true }
                        .disabled(model.isRefreshing)
                } header: { Text("数据管理") } footer: {
                    Text("删除服务端全部历史会关闭自动上传。移除本机配置不会自动删除服务端数据。所有操作都不影响 Apple 健康中的原始记录。")
                }
            }
            .scrollContentBackground(.hidden).background(Palette.background)
            .navigationTitle("设置与同步").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .onAppear { baseURL = model.serverURL }
            .confirmationDialog("删除服务端保存的全部健康记录？", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
                Button("删除全部历史并关闭自动上传", role: .destructive) { Task { await model.deleteRemote() } }
            } message: { Text("MySQL 中全部原始历史记录、上传摘要和最新摘要都会删除，无法撤销。眼镜将无摘要可读；Apple 健康数据及本机缓存保持不变。") }
            .confirmationDialog("移除本机同步配置？", isPresented: $showDisconnectConfirmation, titleVisibility: .visible) {
                Button("移除配置", role: .destructive) { model.disconnect(); baseURL = "" }
            } message: { Text("服务端已有摘要不会被删除。需要删除时，请先取消并执行“删除服务端全部历史”。") }
            .confirmationDialog("清除本机摘要缓存？", isPresented: $showCacheConfirmation, titleVisibility: .visible) {
                Button("清除缓存", role: .destructive) { model.clearLocalCache() }
            }
        }
    }
}
