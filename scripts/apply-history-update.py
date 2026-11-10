from pathlib import Path

def edit(path, old, new):
    p = Path(path)
    s = p.read_text()
    assert s.count(old) == 1, (path, old[:90], s.count(old))
    p.write_text(s.replace(old, new))

for path in ['.github/workflows/ci.yml', '.github/workflows/gin-mysql-admin.yml']:
    edit(path, 'branches: [main,', 'branches: [main, feat/healthkit-history,')
edit('backend/internal/api/server.go', '\tr.Use(s.cors)\n', '\tr.Use(s.cors)\n\ts.historyRoutes(r)\n')
edit('backend/internal/store/mysql.go', '\treturn nil\n}\nfunc (s *MySQL) Ping', '\treturn s.migrateHistory(ctx)\n}\nfunc (s *MySQL) Ping')
edit('backend/internal/store/mysql.go', '\treturn tx.Commit()\n}\nfunc (s *MySQL) Overview', '\tif e = s.deleteHistory(ctx, tx); e != nil { return e }\n\treturn tx.Commit()\n}\nfunc (s *MySQL) Overview')
edit('backend/internal/store/mysql_test.go', 't.Cleanup(func() { s.DB.Exec("DROP TABLE " + s.state);', 't.Cleanup(func() { s.DB.Exec("DROP TABLE " + s.recordsTable()); s.DB.Exec("DROP TABLE " + s.historyState()); s.DB.Exec("DROP TABLE " + s.state);')
edit('ios/project.yml', 'MARKETING_VERSION: "0.3.0"', 'MARKETING_VERSION: "0.4.0"')
edit('ios/project.yml', 'CURRENT_PROJECT_VERSION: "3"', 'CURRENT_PROJECT_VERSION: "4"')
edit('ios/G3Health/Views/DashboardView.swift', '    @State private var showingSettings = false\n', '    @State private var showingSettings = false\n    @State private var showingHistory = false\n')
edit('ios/G3Health/Views/DashboardView.swift', '            .toolbar {\n', '''            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showingHistory = true } label: { Label("历史", systemImage: "clock.arrow.circlepath") }
                }
''')
edit('ios/G3Health/Views/DashboardView.swift', '            .sheet(isPresented: $showingSettings) { SettingsView() }', '            .sheet(isPresented: $showingSettings) { SettingsView() }\n            .sheet(isPresented: $showingHistory) { HistoryView() }')
edit('ios/G3Health/AppModel.swift', '    func saveConnection(base: String) {\n', '    func saveConnection(base: String) {\n        guard !HistorySyncModel.shared.isRunning else { errorMessage = "请先暂停历史同步，再修改服务地址。"; return }\n')
edit('ios/G3Health/AppModel.swift', '    func disconnect() {\n', '    func disconnect() {\n        guard !HistorySyncModel.shared.isRunning else { errorMessage = "请先暂停历史同步。"; return }\n        HistorySyncModel.shared.invalidateView()\n')
edit('ios/G3Health/AppModel.swift', '    func deleteRemote() async {\n        guard !isUploading, serverConfigured else { return }', '    func deleteRemote() async {\n        guard !isUploading, serverConfigured, !HistorySyncModel.shared.isRunning else { errorMessage = "请先暂停历史同步后再删除。"; return }')
edit('ios/G3Health/AppModel.swift', '            notice = "服务端全部摘要历史已删除，自动上传已关闭。Apple 健康原始数据保持不变。"', '            HistorySyncModel.shared.invalidateView()\n            notice = "服务端全部摘要与原始历史已删除，自动上传已关闭。Apple 健康原始数据保持不变。"')
edit('ios/G3Health/G3HealthApp.swift', '                    if phase == .active { Task { await model.foregroundRefresh() } }', '                    if phase == .active { Task { await model.foregroundRefresh() } }\n                    else { HistorySyncModel.shared.pause() }')
edit('ios/G3Health/Views/SettingsView.swift', '删除服务端保存的全部健康摘要历史？', '删除服务端保存的全部健康记录？')
edit('ios/G3Health/Views/SettingsView.swift', 'MySQL 中全部上传历史和最新摘要都会删除', 'MySQL 中全部原始历史记录、上传摘要和最新摘要都会删除')
edit('web-admin/src/App.vue', "import Trend from './Trend.vue';", "import Trend from './Trend.vue';\nimport Records from './Records.vue';")
edit('web-admin/src/App.vue', '    <button :class="{ active: tab === \'guide\' }"', '    <button :class="{ active: tab === \'records\' }" @click="chooseTab(\'records\')"><span>▤</span> 全量健康记录</button>\n    <button :class="{ active: tab === \'guide\' }"')
edit('web-admin/src/App.vue', "history: '上传历史', guide:", "history: '上传历史', records: '全量健康记录', guide:")
edit('web-admin/src/App.vue', 'v-if="tab !== \'guide\'"', 'v-if="tab !== \'guide\' && tab !== \'records\'"')
edit('web-admin/src/App.vue', '   <template v-else>\n    <section class="panel guide">', '   <Records v-else-if="tab === \'records\'" />\n   <template v-else>\n    <section class="panel guide">')
edit('web-admin/src/App.vue', '只保存 iPhone 上传的摘要，不会主动从苹果服务器抓取数据；无法补齐未上传日期或所有逐条心率/运动原始记录。', '支持今日摘要与独立的全量原始记录归档。历史需在手机「历史」页面主动同步；仅能获取手机中已有且获准读取的数据，不会直接访问苹果服务器。')
edit('web-admin/src/App.vue', '删除 MySQL 中全部摘要历史', '删除 MySQL 中全部摘要与原始记录历史')
edit('README.md', '## 0.3.0：个人局域网免 Token 版', '## 0.4.0：全量历史与按日查看\n\n首页「历史」可查看过去日期，或分批同步所有可读取的睡眠/活动/心率/运动记录。后台新增「全量健康记录」，旧今日摘要不被历史替换。更新步骤、范围与断点续传见 [历史功能说明](docs/HISTORY.md)。\n\n## 个人局域网免 Token 模式')
edit('README.md', '**0.3.0 (3)**', '**0.4.0 (4)**')
fragment = Path('web-admin/tests/history-fragment.txt').read_text()
edit('web-admin/tests/browser.mjs', ' assert.deepEqual(exceptions, []);', fragment + '\n assert.deepEqual(exceptions, []);')
edit('web-admin/tests/browser.mjs', " assert.equal((await (await call('/api/admin/overview')).json()).snapshotCount, 0);", " assert.equal((await (await call('/api/admin/overview')).json()).snapshotCount, 0);\n assert.equal((await (await call('/v1/history/status')).json()).count, 0);\n assert.equal((await call('/v1/history/batch', 'PUT', batch)).status, 409, 'deleted data resurrected by in-flight upload');")
