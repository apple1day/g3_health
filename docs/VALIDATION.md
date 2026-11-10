# 当前 0.3 验证说明

0.3 的执行结果以对应提交的 GitHub Actions 为准。当前检查覆盖免 Token 的 API、旧配置、Vue 自动加载及 Even 实际 Gin/MySQL 联调、iOS 模拟器构建与单元测试。未声称已完成实体 iPhone、Apple Watch、G2 或锁屏验收。

以下为历史版本记录，不代表 0.3 仍使用 Token：

# 验证记录 · 0.1.0 (1)

代码建立日期：2026-11-09。以下是代码交付准备阶段实际执行的检查；远程编译与后续变化以 [GitHub Actions](https://github.com/apple1day/g3_health/actions/workflows/ci.yml) 的对应提交记录为准。

| 检查 | 建立时结果 |
| --- | --- |
| 单用户摘要服务 | 全新虚拟环境安装后，25 项 unittest 通过 |
| Even Hub 插件 | 30 项单元测试通过；TypeScript 检查及生产构建通过 |
| 插件依赖 | 固定 SDK 0.0.16、CLI 0.2.0；本次 npm audit 无已报告漏洞 |
| Even 打包 | `.ehpk` 本地打包通过；实际 API 白名单应由使用者配置 |
| iOS 项目静态检查 | Info.plist、entitlements、privacy manifest、asset JSON 与 XcodeGen YAML 解析通过 |
| 原生单元测试 | 提供 17 项 XCTest；在 macOS CI 中执行，Linux 创建环境无法运行 Xcode |
| 浏览器与真实服务联调 | 提供可复现的 Playwright 联调脚本，在 CI 中运行并保存桌面/手机截图 |
| 手表/iPhone 健康授权/G2 蓝牙/Beta 锁屏 | 尚需使用者的真实设备验证，未标记为通过 |

## 自动化浏览器测试

`scripts/browser-smoke.py` 启动临时的真实摘要服务，使用临时随机令牌与明确标识的合成样例，检查演示隔离、真实协议读取、读写角色、离线缓存、清理配置及桌面/手机布局。它不读取或上传使用者健康数据。

GitHub Actions 的 `browser-test-screenshots` artifact 包含演示界面截图；`ios-test-results` 包含原生 XCTest 结果。两类 artifact 按工作流设置保留 7 天。

本地如需重跑浏览器检查：先构建 `evenhub/dist`，安装 `server/requirements-dev.txt` 与 `playwright==1.62.0`，执行 `python -m playwright install chromium`，再执行 `python scripts/browser-smoke.py`。需要允许浏览器子进程和本机网络的运行环境。
