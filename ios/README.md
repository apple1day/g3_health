# 健康速览 iPhone App

SwiftUI / iOS 17+ / HealthKit，只读 Apple 健康。先完成本机读取，再按需连接个人摘要服务；不需要先安装 watchOS App。

## 工程

在仓库根目录执行 `./setup-ios.sh`。脚本使用 XcodeGen 的 `ios/project.yml` 生成 `G3Health.xcodeproj`，scheme 为 `G3Health`，测试目标为 `G3HealthTests`。

- 默认 Bundle ID：`com.anxiong.g3health`。
- 本地签名：`ios/Config/Signing.local.xcconfig`，不要提交到仓库。
- `DEVELOPMENT_TEAM` 与 `HEALTH_BUNDLE_IDENTIFIER` 在本地配置覆盖，XcodeGen 不在 target 上覆盖它们。
- Debug 使用 `Info-Debug.plist`，只在应用层允许 localhost、`.local` 与私有局域网地址通过 HTTP 连接个人服务。
- Release 使用 `Info.plist`，`RelayClient` 只接受 HTTPS；不跳过服务器证书校验，也不跟随重定向。

运行真实数据读取需要 iPhone 真机、相应 HealthKit 签名能力及读取授权。模拟器用于界面和确定性单元测试。是否能启用后台交付，还取决于实际签名和系统；失败时仍可前台读取。

## 数据口径

- **按来源睡眠历史**：首页「OPPO / 其他来源睡眠」独立读取睡眠，列出真实来源、样本数与覆盖日期，可按单一来源查看和导出 JSON / CSV。必须先由来源 App 共享到 Apple 健康；不直接读取其他 App 的私有数据或云端。扫描不设日期谓词，实际范围受已共享记录和系统读取授权限制；中止或失败不冒充完成。操作见 [OPPO 睡眠历史说明](../docs/OPPO_HISTORY.md)。
- **睡眠汇总**：前一天本地中午到当天本地中午；在上午读取时，终点截止到当前时刻。包含此区间的小睡，并非自动识别单一主睡眠。选择包含有效睡眠的 Apple Watch 来源优先，否则选择单一有记录来源。只计算去重后的实际睡眠区间，排除卧床。详细清醒阶段覆盖旧式大段 `asleepUnspecified`。只有未分类睡眠时，核心/深度/REM 为未知，不伪造为零。
- **活动**：当天从本地午夜开始的 HealthKit 累计统计；三环及目标直接查询 `HKActivitySummary`。显示的是健康汇总，不承诺仅 Apple Watch 单一设备。支持按能量或活动时间计量的活动环。无数据用破折号。
- **心率**：最近 30 天最后一条可读取记录，带真实样本时间，不是实时心率。
- **运动**：完成时间处于过去 30 个本地日内的最近一条记录；距离或能量不存在时显示破折号。
- **时间**：JSON 日期为 UTC ISO8601，包含毫秒；`day` 始终使用保留手机时区的公历日期。`generatedAt` 是本次查询的起始时刻，避免跨午夜时与统计窗口的日期不一致。它不代表传感器刚刚测量。
- **权限**：完成系统授权流程不等于用户允许全部类型。HealthKit 不公开具体读取是否拒绝；空结果可能是无记录、未同步或无读取许可。

读取出错时保留旧摘要并标明缓存，禁止把失败结果上传。显式演示使用独立数据，既不覆盖真实缓存，也不能上传到服务。

## 同步

设置中只填写服务根地址，当前 Gin 服务采用个人局域网免 Token 模式。保存地址不会上传数据；支持手动摘要上传和主动开启后的自动摘要上传。历史逐条归档由「历史 → 全部记录与同步」单独启动。按来源睡眠读取与文件导出无需服务端。

可选后台观察按小时请求更新，系统决定实际送达。首次解锁前、锁屏保护、网络不可达和系统预算都可能使同步延迟。iPhone 回到前台时补充刷新。删除服务端摘要自动关闭上传，避免立即重新创建。

## 数据存储与诊断

- 真实摘要在本机 Application Support 中缓存，采用设备文件保护且排除 iCloud/设备备份。
- 配套服务是用户自行配置；只有主动同步或开启自动摘要上传后，所选健康摘要才会发送到该地址。完整逐条历史仅在主动启动历史同步后发送；本机睡眠导出不会触发上传。
- Privacy manifest 声明 UserDefaults（CA92.1）和为同步功能可能传递的健康/健身摘要；无广告、无跟踪。
- “生成脱敏诊断文件”不包含健康数值、传感器时间、服务地址、设备/用户标识或令牌；只导出软件版本、查询状态、操作时间与错误分类。

## 单元测试

`G3HealthTests` 覆盖重叠睡眠、卧床排除、来源选择、清醒覆盖旧式睡眠、未知阶段、DST 跨日、30 日运动边界、公历 JSON 日期、毫秒编码、禁止演示上传、禁止失败读取上传、HTTP 边界，以及按来源扫描分页、停止状态、历史日期、导出转义和设备来源识别。

在 Xcode 选择 G3Health scheme 和 iPhone 模拟器，执行 Product → Test。命令行可使用仓库 CI 的 `xcodebuild test` 配置。

## 参考

- https://developer.apple.com/documentation/healthkit/authorizing-access-to-health-data
- https://developer.apple.com/documentation/healthkit/hkcategoryvaluesleepanalysis
- https://developer.apple.com/documentation/healthkit/hkactivitysummary
- https://developer.apple.com/documentation/healthkit/hkquantitytypeidentifier
- https://developer.apple.com/documentation/healthkit/reading-data-from-healthkit
- https://developer.apple.com/documentation/healthkit/hkhealthstore/enablebackgrounddelivery(for:frequency:withcompletion:)
