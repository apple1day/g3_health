import SwiftUI

struct Palette {
    static let background = Color(red: 0.035, green: 0.055, blue: 0.075)
    static let card = Color(red: 0.075, green: 0.10, blue: 0.13)
    static let mint = Color(red: 0.56, green: 0.95, blue: 0.74)
    static let lavender = Color(red: 0.68, green: 0.64, blue: 1)
    static let cyan = Color(red: 0.39, green: 0.81, blue: 0.95)
    static let coral = Color(red: 1, green: 0.56, blue: 0.54)
}

struct DashboardView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showingSettings = false
    @State private var showingHistory = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    if model.isDemo {
                        HStack(alignment: .top) {
                            Image(systemName: "sparkles")
                            VStack(alignment: .leading, spacing: 6) {
                                Text("演示模式").font(.headline)
                                Text("以下数值是示例，不代表你的健康记录，也不会上传。")
                                    .font(.subheadline).foregroundStyle(.secondary)
                                Button("退出演示，查看真实数据") { model.leaveDemo() }.font(.subheadline.bold())
                            }
                        }
                        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Palette.lavender.opacity(0.15), in: RoundedRectangle(cornerRadius: 18))
                    }
                    if let message = model.errorMessage { messageView(message, isError: true) }
                    else if let notice = model.notice { messageView(notice, isError: false) }

                    if model.serverConfigured && !model.isDemo {
                        RelayStatusView()
                            .padding(14).background(Palette.card, in: RoundedRectangle(cornerRadius: 16))
                    }

                    if let snapshot = model.displayedSnapshot {
                        freshness(snapshot)
                        SleepCard(sleep: snapshot.sleep)
                        ActivityCard(activity: snapshot.activity, day: snapshot.day)
                        HStack(alignment: .top, spacing: 12) {
                            SmallMetric(title: "今日步数", symbol: "figure.walk", value: number(snapshot.activity.steps), unit: "步", color: Palette.mint)
                            SmallMetric(title: "步行与跑步", symbol: "point.bottomleft.forward.to.point.topright.scurvepath",
                                        value: decimal(snapshot.activity.distanceMeters.map { $0 / 1000 }), unit: "公里", color: Palette.cyan)
                        }
                        HeartRateCard(heartRate: snapshot.heartRate)
                        WorkoutCard(workout: snapshot.workout)
                        if !snapshot.warnings.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(Array(snapshot.warnings.enumerated()), id: \.offset) { _, warning in
                                    Label(warning, systemImage: "info.circle").font(.footnote).foregroundStyle(.secondary)
                                }
                            }.padding(.horizontal, 3)
                        }
                        readActions
                    } else {
                        welcome
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("数据来自 Apple 健康").font(.footnote.weight(.semibold))
                        Text("手表先同步到 iPhone，本 App 再读取已有记录。最近一次心率不是实时监测；无数据可能是尚未记录、尚未同步或未允许读取。")
                            .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }.padding(.vertical, 4)
                }
                .padding(20)
                .frame(maxWidth: 700)
                .frame(maxWidth: .infinity)
            }
            .background(Palette.background)
            .refreshable {
                if model.hasRequestedReadAccess { await model.refresh() }
                else { await model.authorize() }
            }
            .navigationTitle("健康速览")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showingHistory = true } label: { Label("历史", systemImage: "clock.arrow.circlepath") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                        .accessibilityLabel("设置与眼镜同步")
                }
            }
            .sheet(isPresented: $showingSettings) { SettingsView() }
            .sheet(isPresented: $showingHistory) { HistoryView() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Circle().fill(model.isDemo ? Palette.lavender : Palette.mint).frame(width: 6, height: 6)
                Text(model.isDemo ? "DEMO · 界面预览" : "APPLE HEALTH · 每日摘要")
                    .font(.caption.weight(.semibold)).tracking(1.3).foregroundStyle(.secondary)
            }
            Text("睡得怎样，动了多少。")
                .font(.system(.title, design: .rounded, weight: .bold))
            Text(Date(), format: .dateTime.month(.wide).day().weekday(.wide))
                .font(.subheadline).foregroundStyle(.secondary)
        }.padding(.vertical, 8)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 22) {
            Image(systemName: "heart.text.square.fill")
                .font(.system(size: 54)).foregroundStyle(Palette.mint)
            VStack(alignment: .leading, spacing: 10) {
                Text("从你的 Apple Watch 开始").font(.title2.bold())
                Text("读取睡眠汇总、今天的活动和最近一次运动。先在手机核对，配置服务后即可在眼镜上查看摘要。")
                    .font(.body).foregroundStyle(.secondary)
            }
            Button { Task { await model.authorize() } } label: {
                HStack {
                    if model.isAuthorizing || model.isRefreshing { ProgressView().tint(Palette.background) }
                    Text(model.isAuthorizing ? "正在打开授权…" : model.isRefreshing ? "正在读取…" : "连接 Apple 健康")
                        .font(.headline)
                }.frame(maxWidth: .infinity).padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent).foregroundStyle(Palette.background)
            .disabled(model.isAuthorizing || model.isRefreshing)
            Button { model.showDemo() } label: { Text("先看看演示界面").frame(maxWidth: .infinity) }
                .disabled(model.isRefreshing || model.isAuthorizing)
            Text("只申请读取权限。数据可先保留在本机，配置同步并主动上传后才会交给你的服务。")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding(24).background(Palette.card, in: RoundedRectangle(cornerRadius: 26))
    }

    private func freshness(_ snapshot: HealthSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label(model.isDemo ? "示例摘要" : model.isCached ? "上次缓存" : "本机健康摘要",
                      systemImage: model.isCached ? "clock.arrow.circlepath" : "checkmark.shield")
                    .font(.caption.weight(.semibold))
                Spacer()
                if model.isRefreshing { ProgressView().scaleEffect(0.8) }
            }
            Text("读取于 \(snapshot.generatedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption).foregroundStyle(.secondary)
            if !model.isDemo && snapshot.day != HealthSnapshot.dayString(Date(), calendar: .current) {
                Text("这份摘要属于 \(snapshot.day)，下拉刷新以读取今天的数据。")
                    .font(.caption).foregroundStyle(.orange)
            }
            if model.isCached { Text("当前展示上次成功读取的记录。刷新后再同步，避免把旧值当成最新数据。")
                .font(.caption).foregroundStyle(.orange) }
        }.padding(14).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 16))
    }

    private var readActions: some View {
        VStack(spacing: 12) {
            Button {
                Task {
                    if model.hasRequestedReadAccess { await model.refresh() }
                    else { await model.authorize() }
                }
            } label: {
                Label(model.isRefreshing ? "正在读取…" : "读取最新健康数据", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
            }.buttonStyle(.borderedProminent).foregroundStyle(Palette.background)
                .disabled(model.isRefreshing || model.isAuthorizing)
            Button { Task { await model.uploadNow() } } label: {
                Label(model.isUploading ? "正在同步…" : "同步到眼镜服务", systemImage: "eyeglasses")
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
            }.buttonStyle(.bordered).disabled(!model.mayUpload)
            if !model.serverConfigured {
                Button("设置眼镜同步") { showingSettings = true }.font(.footnote)
            }
        }
    }

    private func messageView(_ message: String, isError: Bool) -> some View {
        Label(message, systemImage: isError ? "exclamationmark.circle" : "info.circle")
            .font(.footnote).fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(isError ? Color.orange : Palette.mint)
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background((isError ? Color.orange : Palette.mint).opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct SummaryCard<Content: View>: View {
    let title: String
    let symbol: String
    let color: Color
    let content: Content

    init(_ title: String, symbol: String, color: Color, @ViewBuilder content: () -> Content) {
        self.title = title; self.symbol = symbol; self.color = color; self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(title, systemImage: symbol).font(.subheadline.weight(.semibold)).foregroundStyle(color)
            content
        }
        .padding(22).frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 24))
    }
}

struct SleepCard: View {
    let sleep: SleepSummary
    private var stages: [(String, Double?, Color)] {
        [("核心", sleep.coreMinutes, Palette.lavender), ("深度", sleep.deepMinutes, .indigo),
         ("REM", sleep.remMinutes, Palette.cyan), ("未分类", sleep.unspecifiedMinutes, .gray)]
    }
    var body: some View {
        SummaryCard("睡眠汇总", symbol: "moon.zzz.fill", color: Palette.lavender) {
            if let minutes = sleep.totalMinutes {
                Text(duration(minutes: minutes)).font(.system(.largeTitle, design: .rounded, weight: .semibold))
                if let start = sleep.startedAt, let end = sleep.endedAt {
                    Text("\(start.formatted(date: .abbreviated, time: .shortened)) — \(end.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                GeometryReader { geometry in
                    HStack(spacing: 2) {
                        ForEach(0..<stages.count, id: \.self) { index in
                            if let value = stages[index].1, value > 0 {
                                RoundedRectangle(cornerRadius: 3).fill(stages[index].2)
                                    .frame(width: max(0, (geometry.size.width - 6) * value / max(minutes, 1)))
                            }
                        }
                    }
                }.frame(height: 10).accessibilityHidden(true)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 12) {
                    ForEach(0..<stages.count, id: \.self) { index in
                        HStack(spacing: 6) {
                            Circle().fill(stages[index].2).frame(width: 6, height: 6)
                            Text(stages[index].0).foregroundStyle(.secondary)
                            Spacer(minLength: 2)
                            Text(stages[index].1.map { duration(minutes: $0) } ?? "—")
                        }.font(.caption)
                    }
                }
                Text("夜间清醒 \(sleep.awakeMinutes.map { duration(minutes: $0) } ?? "—") · \(sleep.sourceName ?? "Apple 健康")")
                    .font(.caption).foregroundStyle(.secondary)
            } else { EmptySection(status: sleep.status, text: "此统计区间暂无可读取的睡眠。请确认手表已记录并同步到 iPhone。") }
            Text("昨日中午至今日中午；上午读取时截止到读取时刻，包含区间内的小睡。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct ActivityCard: View {
    let activity: ActivitySummary
    let day: String
    var body: some View {
        SummaryCard("活动三环", symbol: "circle.hexagongrid.fill", color: Palette.mint) {
            VStack(spacing: 18) {
                RingProgress(title: activity.moveMode == .time ? "活动时间" : "活动能量",
                    value: activity.moveMode == .time ? activity.moveMinutes : activity.activeEnergyKcal,
                    goal: activity.moveMode == .time ? activity.moveGoalMinutes : activity.activeEnergyGoalKcal,
                    unit: activity.moveMode == .time ? "分钟" : "千卡", color: Palette.coral)
                RingProgress(title: "锻炼", value: activity.exerciseMinutes, goal: activity.exerciseGoalMinutes,
                             unit: "分钟", color: Palette.mint)
                RingProgress(title: "站立", value: activity.standHours, goal: activity.standGoalHours,
                             unit: "小时", color: Palette.cyan)
            }
            Text("\(day) · 目标来自 Apple 健康；站立为达标小时数。")
                .font(.caption).foregroundStyle(.secondary)
            if activity.status != .ok {
                Text(activity.status == .error ? "部分活动数据暂未读取完成。" : "暂无可读取的活动摘要，空白不代表零。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct RingProgress: View {
    let title: String
    let value: Double?
    let goal: Double?
    let unit: String
    let color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                Text("\(number(value)) / \(number(goal)) \(unit)").font(.subheadline.monospacedDigit()).foregroundStyle(color)
            }
            if let value, let goal, goal > 0 {
                ProgressView(value: min(max(value / goal, 0), 1)).tint(color)
                    .accessibilityLabel("\(title)，完成 \(number(value))，目标 \(number(goal)) \(unit)")
            } else { Capsule().fill(.white.opacity(0.08)).frame(height: 4).accessibilityHidden(true) }
        }
    }
}

struct SmallMetric: View {
    let title: String
    let symbol: String
    let value: String
    let unit: String
    let color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: symbol).font(.title3).foregroundStyle(color)
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.title, design: .rounded, weight: .semibold)).minimumScaleFactor(0.6).lineLimit(1)
            Text(unit).font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 24))
    }
}

struct HeartRateCard: View {
    let heartRate: HeartRateSummary
    var body: some View {
        SummaryCard("最近一次心率", symbol: "heart.fill", color: Palette.coral) {
            if let bpm = heartRate.bpm {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(number(bpm)).font(.system(.largeTitle, design: .rounded, weight: .semibold))
                    Text("次 / 分").foregroundStyle(.secondary)
                }
                if let time = heartRate.measuredAt {
                    Text("测量于 \(time.formatted(date: .abbreviated, time: .shortened))")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Text("最近 30 天内最后一条可读取记录，非实时心率。")
                    .font(.caption).foregroundStyle(.secondary)
            } else { EmptySection(status: heartRate.status, text: "最近 30 天暂无可读取的心率记录。") }
        }
    }
}

struct WorkoutCard: View {
    let workout: WorkoutSummary
    var body: some View {
        SummaryCard("最近一次运动", symbol: "figure.run", color: Palette.cyan) {
            if workout.status == .ok {
                Text(workout.kind ?? "体能训练").font(.title2.bold())
                if let time = workout.startedAt {
                    Text(time.formatted(date: .abbreviated, time: .shortened)).font(.subheadline).foregroundStyle(.secondary)
                }
                HStack(alignment: .top) {
                    workoutMetric(workout.durationSeconds.map { duration(minutes: $0 / 60) } ?? "—", label: "用时")
                    Spacer()
                    workoutMetric(decimal(workout.distanceMeters.map { $0 / 1000 }), label: "公里")
                    Spacer()
                    workoutMetric(number(workout.activeEnergyKcal), label: "千卡")
                }
            } else { EmptySection(status: workout.status, text: "最近 30 天暂无可读取的已完成运动。") }
        }
    }
    private func workoutMetric(_ value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value).font(.headline.monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct EmptySection: View {
    let status: SectionStatus
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("—").font(.largeTitle).foregroundStyle(.secondary)
            Text(status == .error ? "暂时读取失败，请解锁 iPhone 后重试。" : text)
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }
}

func number(_ value: Double?) -> String {
    guard let value, value.isFinite else { return "—" }
    return value.formatted(.number.precision(.fractionLength(0)))
}
func decimal(_ value: Double?) -> String {
    guard let value, value.isFinite else { return "—" }
    return value.formatted(.number.precision(.fractionLength(1)))
}
func duration(minutes: Double) -> String {
    guard minutes.isFinite, minutes >= 0 else { return "—" }
    let total = Int(minutes.rounded())
    if total >= 60 { return "\(total / 60)小时\(total % 60)分" }
    return "\(total)分钟"
}
