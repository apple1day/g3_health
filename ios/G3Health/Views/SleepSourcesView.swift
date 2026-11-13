import SwiftUI
import UniformTypeIdentifiers

/// Reads only the sleep records already shared with Apple Health.
/// A source name is a useful hint, never proof of an installed app or a cloud connection.
@MainActor
struct SleepSourcesView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var reader = SleepSourceHistoryModel()
    @State private var showGuide = true
    @State private var filterDates = false
    @State private var fromDate = Date()
    @State private var toDate = Date()
    @State private var exportDocument: SleepHistoryExportDocument?
    @State private var exportType = UTType.json
    @State private var exportName = "sleep-history"
    @State private var exporting = false
    @State private var exportMessage: String?

    private var canExport: Bool {
        reader.isComplete && !reader.isScanning && !reader.selectedRecords.isEmpty
    }

    private var filteredDays: [SleepHistoryDay] {
        let days = reader.selectedDays
        guard filterDates else { return days }
        let from = HealthSnapshot.dayString(fromDate, calendar: .current)
        let to = HealthSnapshot.dayString(toDate, calendar: .current)
        guard from <= to else { return [] }
        return days.filter { $0.day >= from && $0.day <= to }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    introduction
                    readControls
                    sharingGuide
                    if !reader.sources.isEmpty {
                        sourcesSection
                        if let source = reader.selectedSource {
                            selectedSourceSection(source)
                        }
                    } else if reader.isComplete {
                        Label("没有读到睡眠记录。可能尚未共享到苹果健康、该范围没有数据，或未允许本 App 读取；此结果不能说明 OPPO 云端没有历史。", systemImage: "info.circle")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .padding(20).frame(maxWidth: 720).frame(maxWidth: .infinity)
            }
            .background(Palette.background)
            .navigationTitle("按来源查看睡眠")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { reader.stop(); dismiss() }
                }
            }
            .onDisappear { reader.stop() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { reader.stop() }
            }
            .onChange(of: reader.isComplete) { _, complete in
                if complete && reader.sources.contains(where: \.isOPPOCandidate) { showGuide = false }
            }
            .onChange(of: reader.selectedSourceID) { _, _ in exportMessage = nil }
            .fileExporter(isPresented: $exporting, document: exportDocument,
                          contentType: exportType, defaultFilename: exportName) { result in
                switch result {
                case .success:
                    exportMessage = "已保存所选来源的全部可读取睡眠记录。日期筛选不会缩小导出范围。"
                case .failure(let error):
                    if (error as NSError).code != NSUserCancelledError {
                        exportMessage = "文件未保存，请重新选择保存位置后再试。"
                    }
                }
            }
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("OPPO / 其他来源睡眠", systemImage: "moon.zzz.fill")
                .font(.title2.bold()).foregroundStyle(Palette.lavender)
            Text("在本机查看并导出已共享到苹果健康的历史睡眠，不需要连接服务器。")
                .font(.subheadline)
            Text("同一台手机安装了 OPPO 健康，不代表它已共享历史。本页无法直接读取 OPPO 的私有数据库或云端。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var readControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            if app.isDemo {
                Text("当前是演示模式。先退出演示，再读取本机真实记录。")
                    .font(.footnote).foregroundStyle(Palette.lavender)
                Button("退出演示模式") { app.leaveDemo() }.buttonStyle(.bordered)
            }
            if reader.isScanning {
                HStack(alignment: .center, spacing: 12) {
                    ProgressView()
                    Button("停止读取") { reader.stop() }.buttonStyle(.bordered)
                }
            } else {
                Button {
                    exportMessage = nil
                    Task { await reader.scan() }
                } label: {
                    Label(reader.records.isEmpty ? "读取本机睡眠历史" : "重新读取睡眠历史", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent).foregroundStyle(Palette.background)
                .disabled(app.isDemo || app.isAuthorizing)
            }
            Text(reader.progress).font(.footnote).textSelection(.enabled)
            Text("应用不按日期截断。实际范围取决于系统读取授权及来源已共享的数据。读取时请保持 App 在前台、手机解锁。")
                .font(.caption).foregroundStyle(.secondary)
            if let error = reader.errorMessage {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.footnote).foregroundStyle(.orange)
            }
            if !reader.records.isEmpty && !reader.isComplete && !reader.isScanning {
                Text("当前仅展示已读取的部分记录。重新读取完成后才能导出，避免将部分历史误认为全部。")
                    .font(.footnote).foregroundStyle(.orange)
            }
        }
        .padding(16).background(Palette.card, in: RoundedRectangle(cornerRadius: 18))
    }

    private var sharingGuide: some View {
        DisclosureGroup(isExpanded: $showGuide) {
            VStack(alignment: .leading, spacing: 12) {
                Text("1. 在 OPPO 健康中登录原账号，确认要找的旧日期确实有睡眠记录，再检查苹果健康共享设置。")
                Text("2. 打开苹果“健康” → 头像 → App 与服务 → OPPO 健康，查看实际支持的写入类型，并允许写入睡眠（如果有此项）。")
                Text("3. 在同一列表进入“健康速览”，允许读取睡眠；如果系统提供日期范围选择，请允许所需历史范围。")
                Text("4. 在苹果健康的睡眠详情中核对旧日期及数据来源，然后返回这里重新读取。只出现新记录不代表旧历史已补齐。")
                Text("如果 OPPO 未提供睡眠写入、或旧记录没有进入苹果健康，可先向 OPPO 申请历史数据副本。健康速览无法让未共享的记录自动出现。")
                    .foregroundStyle(.secondary)
                Link("欢太官方数据副本申请入口", destination: URL(string: "https://brand.heytap.com/cn/privacy-feedback.html")!)
            }
            .font(.footnote).padding(.top, 10)
        } label: {
            Label("如何让 OPPO 睡眠进入本页", systemImage: "questionmark.circle")
                .font(.subheadline.weight(.semibold))
        }
        .padding(16).background(Palette.card, in: RoundedRectangle(cornerRadius: 18))
    }

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("已读取的睡眠来源").font(.title3.bold())
            Text("\(reader.sources.count) 个来源 · \(reader.records.count) 条原始记录\(reader.isComplete ? "" : "（读取中或尚未完整）")")
                .font(.footnote).foregroundStyle(.secondary)
            if reader.isComplete && !reader.sources.contains(where: \.isOPPOCandidate) {
                Text("尚未按名称识别到 OPPO 相关来源。可检查下列实际来源，或按上方步骤核对共享与读取权限。")
                    .font(.footnote).foregroundStyle(.orange)
            }
            ForEach(reader.sources) { source in
                Button { reader.selectedSourceID = source.id } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: reader.selectedSourceID == source.id ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(reader.selectedSourceID == source.id ? Palette.mint : Color.secondary)
                            Text(source.name).font(.headline).foregroundStyle(.primary)
                            Spacer(minLength: 0)
                        }
                        if source.isOPPOCandidate {
                            Text("OPPO 相关候选 · 按来源名称识别")
                                .font(.caption).foregroundStyle(Palette.mint)
                        }
                        Text("\(source.count) 条 · 最早 \(source.earliest.formatted(date: .abbreviated, time: .omitted)) · 最晚 \(source.latest.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                    .background(reader.selectedSourceID == source.id ? Palette.mint.opacity(0.09) : Palette.card,
                                in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16)
                        .stroke(reader.selectedSourceID == source.id ? Palette.mint.opacity(0.55) : Color.clear, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(reader.isScanning)
                .accessibilityAddTraits(reader.selectedSourceID == source.id ? .isSelected : [])
            }
        }
    }

    private func selectedSourceSection(_ source: SleepHistorySource) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Divider()
            Text(source.name).font(.title3.bold())
            Text("来源标识：\(source.sourceID)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            exportControls
            if !reader.isScanning {
                Toggle("按日期筛选显示", isOn: $filterDates)
                if filterDates {
                    DatePicker("开始日期", selection: $fromDate, displayedComponents: .date)
                    DatePicker("结束日期", selection: $toDate, displayedComponents: .date)
                    if Calendar.current.startOfDay(for: fromDate) > Calendar.current.startOfDay(for: toDate) {
                        Text("开始日期不能晚于结束日期。").font(.footnote).foregroundStyle(.orange)
                    }
                }
                let days = filteredDays
                Text("\(days.count) 个睡眠统计日 · 仅汇总所选来源，同期其他来源不会混入")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("按手机当前时区前一日中午到本日中午归属睡眠日。已睡区间合并重叠，卧床时间不计入；原始记录保持不变。")
                    .font(.caption).foregroundStyle(.secondary)
                if days.isEmpty {
                    Text("所选日期范围内没有可显示的记录。").font(.footnote).foregroundStyle(.secondary)
                }
                LazyVStack(spacing: 12) {
                    ForEach(days) { day in
                        NavigationLink {
                            SleepSourceDayView(day: day)
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(day.day).font(.headline).foregroundStyle(.primary)
                                    if let minutes = day.summary.totalMinutes {
                                        Text(duration(minutes: minutes)).font(.title3.bold()).foregroundStyle(Palette.lavender)
                                    } else {
                                        Text("没有可汇总的已睡时长").font(.subheadline).foregroundStyle(.secondary)
                                    }
                                    Text("\(day.recordCount) 条原始记录 · 查看时间与分期")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.secondary)
                            }
                            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Palette.card, in: RoundedRectangle(cornerRadius: 16))
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var exportControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack { exportButton(json: true); exportButton(json: false) }
                VStack(alignment: .leading) { exportButton(json: true); exportButton(json: false) }
            }
            Text("导出所选来源本次完整读取的全部历史，包含原始时间、来源与分期，不受下方日期筛选影响。没有共享的云端记录不会包含在文件中。")
                .font(.caption).foregroundStyle(.secondary)
            if let message = exportMessage {
                Text(message).font(.footnote).foregroundStyle(Palette.mint)
            }
        }
    }

    private func exportButton(json: Bool) -> some View {
        Button {
            do {
                let data: Data
                if json { data = try reader.exportJSON() }
                else { data = reader.exportCSV() }
                exportDocument = SleepHistoryExportDocument(data: data)
                exportType = json ? .json : .commaSeparatedText
                exportName = "sleep-history-\(HealthSnapshot.dayString(Date(), calendar: .current))"
                exportMessage = nil
                exporting = true
            } catch {
                exportMessage = "无法生成文件，请完成读取并选择一个有记录的来源后再试。"
            }
        } label: {
            Label(json ? "导出 JSON" : "导出 CSV", systemImage: "square.and.arrow.up")
        }.buttonStyle(.bordered).disabled(!canExport)
    }
}

private struct SleepHistoryExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .commaSeparatedText] }
    var data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private struct SleepSourceDayView: View {
    let day: SleepHistoryDay

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SleepCard(sleep: day.summary,
                          periodNote: "\(day.day) · \(day.timeZone)；前一日中午至本日中午，合并同一来源重叠区间。",
                          emptyMessage: "该统计日有原始记录，但没有可汇总的已睡分期。可在下方查看卧床、清醒或未知类别，应用不会据此补算已睡时长。")
                Text("原始睡眠记录").font(.title3.bold())
                Text("保留来源提供的分期。跨统计日的记录可能在相邻日期各显示一次，但导出按原始记录 ID 保留一条。下方时间优先按样本时区显示；样本时区不可用时采用读取时手机时区。")
                    .font(.caption).foregroundStyle(.secondary)
                LazyVStack(spacing: 12) {
                    ForEach(day.records) { record in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(record.label).font(.headline)
                            Text("\(format(record.startedAt, zone: record.timeZone)) — \(format(record.endedAt, zone: record.timeZone))")
                                .font(.subheadline)
                            if let value = record.value {
                                Text("原始区间 \(value.formatted(.number.precision(.fractionLength(0...2)))) \(record.unit)")
                                    .font(.footnote).foregroundStyle(Palette.lavender)
                            }
                            Text("\(record.sourceName) · \(record.timeZone)").font(.caption).foregroundStyle(.secondary)
                            if !record.device.isEmpty { Text(record.device).font(.caption).foregroundStyle(.secondary) }
                        }
                        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Palette.card, in: RoundedRectangle(cornerRadius: 16))
                    }
                }
            }.padding(20).frame(maxWidth: 720).frame(maxWidth: .infinity)
        }
        .background(Palette.background)
        .navigationTitle(day.day).navigationBarTitleDisplayMode(.inline)
    }

    private func format(_ date: Date, zone: String) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.timeZone = TimeZone(identifier: zone) ?? .current
        return formatter.string(from: date)
    }
}
