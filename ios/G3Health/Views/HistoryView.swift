import SwiftUI

@MainActor
struct HistoryView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var history = HistorySyncModel.shared
    @State private var selectedDay = Date()
    @State private var localSnapshot: HealthSnapshot?
    @State private var dayBusy = false
    @State private var dayError: String?
    @State private var kind: HistoryKind = .sleep
    @State private var showRescan = false
    @State private var section = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Picker("历史查看方式", selection: $section) {
                        Text("本机按日查看").tag(0)
                        Text("全部记录与同步").tag(1)
                    }.pickerStyle(.segmented)
                    if section == 0 { localDayView } else { archiveView }
                }.padding(20).frame(maxWidth: 720).frame(maxWidth: .infinity)
            }.background(Palette.background)
            .navigationTitle("历史健康记录").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .onChange(of: scenePhase) { _, phase in if phase != .active { history.pause() } }
            .onChange(of: kind) { _, _ in Task { await history.load(base: app.serverURL, kind: kind) } }
            .onChange(of: selectedDay) { _, _ in localSnapshot = nil; dayError = nil }
            .onChange(of: section) { _, value in
                if value == 1 && app.serverConfigured { Task { await history.load(base: app.serverURL, kind: kind) } }
            }
            .confirmationDialog("从头重新扫描所有可读取历史？", isPresented: $showRescan, titleVisibility: .visible) {
                Button("重新扫描全部历史") { start(rescan: true) }
            } message: { Text("用于新增读取权限、补录旧数据或进度异常。按记录 ID 更新，不清空服务器历史；可能需要处理大量记录。") }
        }
    }
    private var localDayView: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("不用连接服务器，也可以查看过去某一天的睡眠与活动。查询按手机当前时区计算，不会修改今日首页或自动上传。").font(.footnote).foregroundStyle(.secondary)
            DatePicker("选择日期", selection: $selectedDay, in: ...Date(), displayedComponents: .date)
                .disabled(dayBusy)
            Button {
                Task {
                    dayBusy = true; dayError = nil; localSnapshot = nil
                    defer { dayBusy = false }
                    let health = HealthKitService()
                    do {
                        try await health.requestReadAccess()
                        localSnapshot = await health.snapshot(now: HistoryDayWindow.reference(selectedDay))
                    } catch { dayError = "无法读取历史。请检查健康授权、保持手机解锁后重试。" }
                }
            } label: { Label(dayBusy ? "正在读取…" : "读取所选日期", systemImage: "calendar") }
                .buttonStyle(.borderedProminent).disabled(dayBusy || history.isRunning)
            if let error = dayError { Text(error).foregroundStyle(.orange) }
            if let s = localSnapshot {
                Text("历史日期：\(s.day) · \(s.timeZone)").font(.headline)
                SleepCard(sleep: s.sleep)
                ActivityCard(activity: s.activity, day: s.day)
                HStack {
                    SmallMetric(title: "当日步数", symbol: "figure.walk", value: number(s.activity.steps), unit: "步", color: Palette.mint)
                    SmallMetric(title: "当日距离", symbol: "location", value: decimal(s.activity.distanceMeters.map { $0 / 1000 }), unit: "公里", color: Palette.cyan)
                }
                Text("睡眠为前一日中午到所选日中午的汇总。心率和运动卡片是截至所选日期最近一次记录（最多回看 30 天），不代表只发生在所选日；全部逐条记录见另一页。").font(.footnote).foregroundStyle(.secondary)
                HeartRateCard(heartRate: s.heartRate)
                WorkoutCard(workout: s.workout)
                ForEach(s.warnings, id: \.self) { Text($0).font(.footnote).foregroundStyle(.orange) }
            }
        }
    }
    private var archiveView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("全量历史归档").font(.title2.bold())
            Text("从手机健康库读取所有可访问的睡眠、运动、活动三环、步数、距离、能量、锻炼和心率记录，没有近 30 天限制。不同来源样本会保留，不能直接相加当作每日总量。").font(.footnote).foregroundStyle(.secondary)
            Text("此操作会将逐条健康记录发送到你配置的服务器，不只发送摘要。免登录服务仅用于可信局域网。").font(.footnote).foregroundStyle(.orange)
            if !app.serverConfigured { Text("请先在设置中保存服务地址；本机按日查看仍可使用。").foregroundStyle(.orange) }
            if app.isDemo { Text("请先退出演示模式再同步真实历史。").foregroundStyle(.orange) }
            HStack {
                if history.isRunning {
                    ProgressView()
                    Button("暂停同步") { history.pause() }.buttonStyle(.bordered)
                } else {
                    Button("开始 / 继续同步全部历史") { start() }.buttonStyle(.borderedProminent)
                        .disabled(!app.serverConfigured || app.isDemo || app.isUploading || dayBusy)
                }
            }
            Text(history.progress).font(.footnote).textSelection(.enabled)
            Text("首次请保持 App 在前台、手机与 Mac 连通。后台或中断时保留已确认进度；不会承诺锁屏持续同步。查询为空不代表已授权。").font(.caption).foregroundStyle(.secondary)
            if let error = history.errorMessage { Text(error).foregroundStyle(.orange).font(.footnote) }
            Button("重新扫描（补录旧记录 / 权限变更后使用）") { showRescan = true }
                .font(.footnote).disabled(history.isRunning || !app.serverConfigured || app.isDemo || app.isUploading)
            Divider()
            HStack {
                Text("服务器历史").font(.headline)
                Spacer()
                Button("刷新") { Task { await history.load(base: app.serverURL, kind: kind) } }
                    .disabled(history.loading || !app.serverConfigured)
            }
            if let status = history.status {
                Text("已归档 \(status.count) 条 · 最早 \(status.earliest?.formatted(date: .abbreviated, time: .omitted) ?? "—")")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Picker("记录类型", selection: $kind) { ForEach(HistoryKind.allCases) { Text($0.title).tag($0) } }
            Text("\(kind.title)：\(history.total) 条，已显示 \(history.rows.count) 条").font(.caption).foregroundStyle(.secondary)
            if let error = history.loadError { Text(error).foregroundStyle(.orange).font(.footnote) }
            if history.loading { ProgressView() }
            if history.rows.isEmpty && !history.loading { Text("暂无已同步记录；先同步历史，再检查健康中的读取权限。").font(.footnote).foregroundStyle(.secondary) }
            LazyVStack(spacing: 12) {
                ForEach(history.rows) { row in
                    let s = row.sample
                    VStack(alignment: .leading, spacing: 7) {
                        HStack { Text(s.label).font(.headline); Spacer(); if let v = s.value { Text("\(v.formatted(.number.precision(.fractionLength(0...2)))) \(s.unit)").monospacedDigit() } }
                        Text("\(s.startedAt.formatted(date: .abbreviated, time: .standard)) — \(s.endedAt.formatted(date: .abbreviated, time: .standard))").font(.caption)
                        Text("\(s.sourceName) · \(s.device) · \(s.timeZone)").font(.caption).foregroundStyle(.secondary)
                        if s.kind == "activitySummary" {
                            Text("活动 \(number(s.metrics["activeEnergyKcal"])) kcal · 锻炼 \(number(s.metrics["exerciseMinutes"])) 分 · 站立 \(number(s.metrics["standHours"])) 小时段").font(.footnote)
                        }
                    }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Palette.card, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            if !history.nextCursor.isEmpty {
                Button("加载更早记录") { Task { await history.load(base: app.serverURL, kind: kind, more: true) } }
                    .disabled(history.loading)
            }
        }
    }
    private func start(rescan: Bool = false) {
        let base = app.serverURL
        Task {
            await history.synchronize(base: base, rescan: rescan)
            await history.load(base: base, kind: kind)
        }
    }
}
