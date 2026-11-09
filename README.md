# 健康速览 · g3_health

从 iPhone 的 **HealthKit** 读取 Apple Watch 已同步的睡眠、活动和运动摘要，并在 **Even G2** 上查看。

第一版由三个可以分开验证的部分组成：

| 目录 | 内容 | 可以先单独测试吗 |
| --- | --- | --- |
| `ios/` | 原生 SwiftUI iPhone App：健康授权、本机摘要、可选同步 | 可以，不依赖服务器或眼镜 |
| `server/` | 单用户 FastAPI + SQLite 摘要服务，上传和读取使用不同令牌 | 可以 |
| `evenhub/` | Even Hub 插件：配置、浏览器预览、演示模式、真实眼镜显示 | 可以先用明确标识的演示数据 |

**首版支持：跨夜睡眠及阶段、今日步数/距离/活动三环、最近一次已完成运动、带测量时间的最近心率。**

这是基于已有 HealthKit 记录的摘要应用。Apple Watch 保持原有的 iPhone 配对即可，暂不需要安装额外 watchOS App。运动进行中的连续心率/配速镜像不属于本版功能。眼镜目标是 Even Hub 官方文档中的 G2。

## 1. 先测试 iPhone App

需要 Mac、完整 Xcode、iOS 17+ 的 iPhone，以及 XcodeGen。

首次下载：

```bash
git clone https://github.com/apple1day/g3_health.git
cd g3_health
brew install xcodegen
bash setup-ios.sh
```

已经下载过：先退出 Xcode，然后在仓库根目录执行：

```bash
git pull --ff-only origin main
bash setup-ios.sh
```

脚本生成并打开 `ios/G3Health.xcodeproj`。在 Xcode 中：

1. 选择 **G3Health** scheme。
2. 在 App target 的 **Signing & Capabilities** 选择自己的 Team，保留 Automatically manage signing。
3. 连接与你的 Apple Watch 配对的 iPhone，将运行目标设为该 iPhone，点击 Run。
4. 打开 App，执行健康授权，允许所需数据类型的读取，然后读取/刷新摘要。
5. 首先核对手机内的睡眠、今日活动和最近运动。此时无需填写服务地址，也不会上传数据。

如果 Bundle ID 已被占用，可指定自己的唯一标识。后续工程重建会保留本机 Team / Bundle ID：

```bash
bash setup-ios.sh --team ABCDE12345 --bundle-id com.yourname.healthglance
```

本机签名信息保存在忽略提交的 `ios/Config/Signing.local.xcconfig`。脚本不删除证书或描述文件，不修改其他项目。首次使用个人开发账号时，按 Xcode 的提示完成签名和设备设置；签名到期后需要重新安装。

### 暂时没有真实健康数据

可以主动打开 App 的演示模式查看界面。演示数据始终有标识，并禁止上传到摘要服务。模拟器不会自动拥有你手表的健康记录，真实读取需要在相应 iPhone 上验证。

如果显示“暂无可读取数据”，可能是尚未记录、尚未同步或未允许读取。HealthKit 不提供可靠的读取权限拒绝状态，App 不会把空结果当作 0 小时睡眠，也不会直接断言权限被拒绝。

## 2. 启动本地摘要服务

先完成 iPhone 本机验证，再启动数据服务。需要 Python 3.11+。

```bash
bash start-server.sh
```

脚本会建立 `server/.venv`、安装固定版本依赖，并在首次启动时生成 `server/.env`。以后会保留已有配置，不重新生成令牌。

```bash
curl http://127.0.0.1:8787/healthz
```

`server/.env` 中的两个值用途不同：

| 配置 | 填到哪里 | 权限 |
| --- | --- | --- |
| `UPLOAD_TOKEN` | iPhone App 的同步设置 | 上传/删除摘要 |
| `READ_TOKEN` | Even 插件的连接设置 | 读取摘要 |

在 Mac 上可以用 `open -e server/.env` 查看并复制到相应设备。不要把令牌放入 URL、截图、问题反馈或 Git。

iPhone 与 Mac 接入同一局域网。iPhone App 中填写 Mac 的局域网地址，例如 `http://192.168.1.20:8787`，以及 `UPLOAD_TOKEN`，按页面提示保存设置并主动同步真实数据。**iPhone 上的 `localhost` 指向 iPhone 自己，不是 Mac。**

Debug 版允许局域网 HTTP，Release 版要求 HTTPS。局域网 HTTP 仅用于开发验证；长期使用应按 [部署说明](docs/DEPLOYMENT.md) 配置 HTTPS。

## 3. 测试浏览器预览与 Even 插件

需要 Node.js 22.13+，推荐 Node.js 24 LTS。

```bash
bash start-evenhub.sh
```

在电脑浏览器打开终端输出的地址（默认 `http://localhost:5173`）。先选择演示模式，可以查看手机配置页和眼镜画布预览；再退出演示，填写摘要服务地址与 `READ_TOKEN`，读取真实摘要。

项目固定使用 `@evenrealities/even_hub_sdk 0.0.16`；该版本要求 Even Realities App **2.2.10 或更新**。浏览器预览成功不代表眼镜已连接，页面分别显示数据来源与桥接状态。

### 在同一局域网扫码调试

假设 Mac 的地址是 `192.168.1.20`：

1. 在 `server/.env` 中将 `ALLOWED_ORIGINS` 显式设置为 `*`，然后重启本地摘要服务。这是开发配置；身份校验仍由 Bearer 令牌执行。
2. 配置插件允许访问的开发接口，然后启动开发服务器：

   ```bash
   cd evenhub
   npm ci
   npm run configure -- --api-url http://192.168.1.20:8787 --allow-local-http
   npm run dev -- --host 0.0.0.0
   ```

3. 在另一个终端中生成开发二维码：

   ```bash
   cd g3_health/evenhub
   npx evenhub qr --url http://192.168.1.20:5173
   ```

4. 在 Even Realities App 开启开发者模式并按官方流程扫描二维码，进入插件配置页，填写服务地址与 `READ_TOKEN`。
5. 连接眼镜后查看睡眠、活动、最近运动和心率页面。以插件页面提示的手势操作为准；根页面双击调用系统退出确认。

网络白名单与 CORS 是两个独立条件，必须同时满足。配置地址时只填 origin，例如 `https://health.example.com`，不包含 `/v1/snapshot`、令牌或查询参数。

### 打包到 Private / Beta 测试

配置可访问的 HTTPS 摘要服务后，在仓库根目录执行：

```bash
bash pack-evenhub.sh https://health.example.com
```

输出为 `artifacts/health-glance.ehpk`。在 Even 开发者门户创建应用并上传，按官方流程安装 Private 或 Beta 构建。Beta 需要构建已提升为 Beta，并且测试者状态为 Active。

**手机锁屏测试必须使用 Beta 实机执行。**扫码调试、浏览器和模拟器不足以证明锁屏后长期可用。官方后台说明存在差异，本项目使用缓存、数据时间和显式刷新；不承诺秒级后台同步。

## 数据口径与更新时间

- **睡眠**：统计昨日中午至今日中午（上午读取时截至当下）的睡眠，包含此区间的小睡；选择单一来源，优先 Apple Watch；合并重叠睡眠区间，排除 `inBed`。清醒时间不计入睡眠总时长。没有分期记录时，保留未分类睡眠。
- **日常活动**：使用 HealthKit 统计和系统活动摘要，不把手机、手表各自的原始样本总量直接相加。三环目标来自系统，不硬编码。
- **最近运动**：读取过去 30 天最近一条已完成运动；距离或能量没有记录时显示空缺。
- **心率**：展示最新已有样本及其实际测量时间，不标记成实时传感器值。
- `generatedAt`：iPhone 生成摘要的时间。`receivedAt`：服务接收时间。`heartRate.measuredAt`：心率样本时间。它们含义不同。
- 刷新插件会重新获取服务摘要，不能强制 Apple Watch 立即测量或同步。后台更新是系统尽力调度，锁屏或设备状态可能影响读取。

准确的数据结构见 [共享接口约定](shared/CONTRACT.md) 和 [明确标识的演示样例](shared/snapshot.example.json)。

## 开发检查

```bash
python3 -m pip install -r server/requirements-dev.txt
cd server
python3 -m unittest discover -s tests -v
```

```bash
cd evenhub
npm ci
npm run typecheck
npm test
npm run build
```

Mac 上运行原生测试：

```bash
bash setup-ios.sh --no-open
SIMULATOR_ID="$(python3 scripts/select-simulator.py)"
xcodebuild test -project ios/G3Health.xcodeproj -scheme G3Health \
  -configuration Debug -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  CODE_SIGNING_ALLOWED=NO
```

GitHub Actions 会运行摘要服务测试、插件测试/构建，以及 macOS 上的 iOS 模拟器编译/单元测试。CI 能验证代码和数据处理，无法替代你手表的实际记录、健康授权、眼镜蓝牙与锁屏验收。测试状态与方法见 [验收清单](docs/TESTING.md)。

## 官方依据

- [Even Hub Overview](https://hub.evenrealities.com/docs/get-started/overview)
- [Even Hub Architecture](https://hub.evenrealities.com/docs/get-started/architecture)
- [Even Hub Networking](https://hub.evenrealities.com/docs/build/networking)
- [Even Hub App Submission / Locked-phone operation](https://hub.evenrealities.com/docs/ship/app-submission)
- [Apple：HealthKit 授权](https://developer.apple.com/documentation/healthkit/authorizing-access-to-health-data)
- [Apple：睡眠分类与重叠样本](https://developer.apple.com/documentation/healthkit/hkcategoryvaluesleepanalysis)
- [Apple：活动摘要](https://developer.apple.com/documentation/healthkit/hkactivitysummary)
- [Apple：后台更新频率](https://developer.apple.com/documentation/healthkit/hkhealthstore/enablebackgrounddelivery(for:frequency:withcompletion:))
