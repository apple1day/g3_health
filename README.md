# 健康速览 · g3_health

原生 iPhone **HealthKit App** + **Gin / MySQL** 数据服务 + **Vue 3 管理后台** + **Even G2 插件**。

iPhone 读取 Apple Watch 已同步的睡眠、活动三环、步数、最近运动和带测量时间的心率；可以独立本机使用。开启同步后，MySQL 保留摘要历史，Vue 提供日期筛选、趋势、上传记录和 JSON 详情；Even 插件读取同一套最新摘要。

## 0.2 升级：先处理上传令牌，再启动新后台

iPhone 的 `UPLOAD_TOKEN` 不是字段名称或数据库密码，请填写服务生成的完整令牌。
旧服务的令牌在 **Mac 的 `server/.env`**：`open -e server/.env`。只复制 `UPLOAD_TOKEN=` 后面的值。

升级前在旧服务终端按 Control+C。需要 Go 1.25+、Node 22.12+（推荐 24）、运行中的 MySQL 8.0+：

```bash
git pull --ff-only origin main
bash setup-backend.sh
bash start-server.sh
```

首次 setup 会提示输入 MySQL 密码（输入不显示）；默认连接 `127.0.0.1:3306`、库 `g3_health`、用户 `root`。密码仅写入忽略提交的 `backend/config.local.yaml`，自动复用旧 `.env` 上传/读取令牌并生成独立管理令牌。再次 setup 不覆盖已有配置。

Mac 浏览器打开 **http://127.0.0.1:8787/admin/**。

```bash
bash copy-token.sh admin
```

把已复制的管理令牌粘贴到 Vue 登录框。iPhone/眼镜分别用：

```bash
bash copy-token.sh upload
bash copy-token.sh read
```

iPhone 的服务地址仍填 **Mac 局域网 IP**，如 `http://192.168.19.152:8787`；保存后回首页手动上传真实数据。新后端不用 Python/uv，原 `.venv` 不影响 Go 服务。

完整配置、数据口径、接口与回退：[Gin + MySQL + Vue 使用说明](docs/GIN_MYSQL_ADMIN.md)。

## 目录

| 目录 | 内容 |
|---|---|
| `ios/` | SwiftUI + HealthKit；只读授权、本机摘要、可选上传 |
| `backend/` | Gin API、MySQL 历史、角色令牌、私有 YAML 配置 |
| `web-admin/` | Vue 3 管理界面，生产构建由 Gin 同源提供 |
| `evenhub/` | Even Hub SDK 插件、浏览器预览、明确标识的演示模式 |
| `server/` | 保留的 Python/SQLite 旧版，用于显式回退 |
| `shared/` | iPhone / 后端 / 眼镜通用 JSON v1 约定 |

## iPhone 安装与更新

需要完整 Xcode、XcodeGen、iOS 17+ iPhone。首次克隆：

```bash
git clone https://github.com/apple1day/g3_health.git
cd g3_health
brew install xcodegen
bash setup-ios.sh
```

已克隆：

```bash
git pull --ff-only origin main
bash setup-ios.sh
```

脚本打开 `ios/G3Health.xcodeproj`。选择 G3Health scheme，在 Signing & Capabilities 选择自己的 Team，保留自动签名，运行到与你 Apple Watch 配对的实体 iPhone。打开 App 允许对应健康读取权限，再刷新。本机读取无需后台。

若免费开发签名达到设备已安装 App 上限，先删除一个不再使用的开发 App，再重试；不要删除其他项目证书。默认 Bundle ID 冲突时可运行：

```bash
bash setup-ios.sh --team ABCDE12345 --bundle-id com.yourname.healthglance
```

签名配置保留在被忽略的 `ios/Config/Signing.local.xcconfig`，脚本不删除证书/描述文件。模拟器不自动具有真实健康记录。演示数据始终有标识且不能上传。

## Even 插件

```bash
bash start-evenhub.sh
```

浏览器预览默认 `http://localhost:5173`。服务地址填写 Gin 的 origin，令牌使用 READ_TOKEN。固定 SDK `0.0.16`，对应 Even App 要求 2.2.10+；插件目标是 G2，仓库名称不是眼镜型号。

局域网扫码示例：先把 `backend/config.local.yaml` 中的 `server.allowed-origins` 按需要设为实际插件 origin，或显式 `['*']` 用于开发，然后重启 Go。

```bash
cd evenhub
npm ci
npm run configure -- --api-url http://192.168.19.152:8787 --allow-local-http
npm run dev -- --host 0.0.0.0
```

另一个终端生成二维码：

```bash
cd evenhub
npx evenhub qr --url http://192.168.19.152:5173
```

Even App 开启开发者模式后扫码，填写服务地址与 READ_TOKEN。网络白名单和 CORS 必须同时满足。手机地址不要使用 Mac 的 localhost。

HTTPS 部署后可打包：

```bash
bash pack-evenhub.sh https://health.example.com
```

输出 `artifacts/health-glance.ehpk`，在 Even 门户按流程上传 Private/Beta。锁屏长期运行需 Beta 实机验收，浏览器/扫码成功不能替代。

## 数据与隐私

只保存 **App 上传的摘要**，不是完整逐条 HealthKit 数据库。心率带测量时间，不标记为实时；睡眠合并重叠区间、排除 inBed/清醒，优先选 Apple Watch 来源；系统活动摘要提供三环及目标。

历史从收到上传开始。每日趋势取当天最后一份，**不会累加同一天重复上传的步数**。无数据保留 null，不猜测为零或权限被拒绝。旧 SQLite 不删除、不自动导入，升级后可从手机重新上传最新摘要。

**iPhone 删除服务器数据将清除 MySQL 全部摘要历史。**独立备份和旧版 SQLite 不会自动删除。单用户实例；无多用户隔离、无数据库透明加密保证。HTTP/root 仅用于可信本机开发，正式使用需要 HTTPS、受限账号和加密备份。所有密码、令牌、健康数据库禁止提交。

## 测试

```bash
cd backend
go test -tags nomsgpack -race ./...
```

```bash
cd web-admin
npm ci
npm test
npm run build
```

```bash
cd evenhub
npm ci
npm run typecheck
npm test
npm run build
```

原 iOS / 插件 / Python 检查保留；新增工作流运行 Gin 单测、真实 MySQL 8.4 集成测试、Vue 构建和浏览器端到端测试。CI 使用人工测试数据，不能替代你的 iPhone/Apple Watch/G2 真机验收。

## 官方文档

- [Even Hub](https://hub.evenrealities.com/docs/get-started/overview)
- [Apple HealthKit](https://developer.apple.com/documentation/healthkit)
- [Gin](https://gin-gonic.com/en/docs/quickstart/)
- [Vue](https://vuejs.org/guide/quick-start)
- [MySQL Go driver](https://github.com/go-sql-driver/mysql)
