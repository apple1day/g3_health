# 健康速览 · g3_health

原生 iPhone **HealthKit** + **Gin / MySQL** + **Vue 3 管理后台** + **Even G2 插件**。

## 0.3.0：个人局域网免 Token 版

手机和眼镜仅填写服务地址；Vue 打开即查看，不再要求上传/读取/管理 Token，也没有登录页。**这是真正的无身份认证模式，不是隐藏或自动填入令牌。任何能连接服务的人都能读取、上传或删除健康摘要。仅在可信局域网使用，不要做公网端口映射或公开隧道；HTTPS 也不能替代身份验证。** 后续账号密码登录尚未实现。

数据库连接密码和 Apple 健康读取授权仍然需要，两者不是同步 Token。

## 已有版本升级

在旧服务终端按 Control+C，退出 Xcode，然后在仓库根目录执行：

```bash
git pull --ff-only origin main
bash setup-backend.sh
bash start-server.sh
```

需要 Go 1.25+、Node 22.12+（推荐 24）、运行中的 MySQL 8.0+。已有 `backend/config.local.yaml` 不会被覆盖，旧 `security` 段兼容但被忽略；不用删配置、重建数据库或输入旧 Token。初始化只建缺失表，不清空历史。

另开终端，在同一仓库根目录执行：

```bash
bash setup-ios.sh
```

选择原来的 Team 和 Bundle ID，在 Xcode 按 Command+R 覆盖运行。新 iPhone App 版本为 **0.3.0 (3)**。只更新服务端不会使旧手机安装包的输入框消失，因此必须重新安装新构建。保留原服务地址、健康权限和缓存；仅清除本 App 的旧上传令牌钥匙串条目。

## 第一次运行

```bash
git clone https://github.com/apple1day/g3_health.git
cd g3_health
brew install xcodegen
bash setup-ios.sh
```

使用 iOS 17+ 真机，在 Xcode 的 G3Health target 选择个人 Team。App 可以独立读取 Apple Watch 已同步的睡眠、活动三环、步数、距离、最近运动和带采样时间的心率，不配置服务也能本机查看。默认不上传；演示数据明确标记且禁止上传。

服务端首次运行 `bash setup-backend.sh` 时，会以不回显方式询问 MySQL 密码。默认使用 `127.0.0.1:3306`、数据库 `g3_health`、用户名 `root`、空表前缀，以及 `charset=utf8mb4&parseTime=True&loc=Local`。密码只保存到 Git 忽略的 `backend/config.local.yaml`。修改配置：

```bash
open -e backend/config.local.yaml
```

## 上传并查看

Mac 后台：`http://127.0.0.1:8787/admin/`，打开自动读取，无需登录。

手机「设置与同步」只填 **Mac 的局域网地址**，例如 `http://192.168.19.152:8787`。手机的 localhost 是手机自己。点击保存，然后读取真实健康数据并手动同步；保存设置本身不会上传。手机与 Mac 必须互通，并允许 iOS 局域网权限及 Mac 防火墙访问。Debug 可用局域网 HTTP，Release 仍需 HTTPS。

```bash
curl -fsS http://127.0.0.1:8787/healthz
open "http://127.0.0.1:8787/admin/"
```

后台提供最新摘要、按天趋势、日期筛选、上传历史分页和 JSON 详情。每天取最后一份摘要，不累加多次上传的步数/能量。空值不当成零，最近心率不冒充实时测量。

## Even 插件

```bash
bash start-evenhub.sh
```

浏览器可先开启演示，连接真实服务时只填同一服务地址。旧版本存储的读取 Token 会清除，已保存地址保留。SDK 仍固定 0.0.16，最低 Even App 2.2.10；本项目眼镜目标为 G2。

扫码前配置接口白名单（替换为实际 IP）：

```bash
cd evenhub
npm ci
npm run configure -- --api-url http://192.168.19.152:8787 --allow-local-http
npm run dev -- --host 0.0.0.0
```

另开终端在 `evenhub` 运行 `npx evenhub qr --url http://192.168.19.152:5173`。服务的 `server.allowed-origins` 需要允许实际插件 origin；白名单/CORS 没有被当作登录认证。免 Token 不会绕过 Even 自身权限。详见 [插件说明](evenhub/README.md)。

## 数据和验证边界

MySQL 记录从启用上传时开始，不会自动补齐历史、不包含完整逐样本健康数据库。旧 SQLite 不删除、不自动导入。**手机「删除服务端全部历史」会删除 MySQL 全部摘要历史及最新指针**，操作前有确认；不影响 Apple 健康原始数据。

自动化覆盖 iOS 模拟器编译/单元测试、Gin/API、真实 MySQL 8.4、Vue 测试/构建、浏览器中的 Vue 和 Even 无 Token 联调。实机 HealthKit/G2/锁屏仍须设备验证。相关文档：

- [Gin + MySQL + Vue 操作说明](docs/GIN_MYSQL_ADMIN.md)
- [接口约定](shared/CONTRACT.md)
- [验收清单](docs/TESTING.md)
- [部署边界](docs/DEPLOYMENT.md)

`server/` 里的 Python 实现是旧版参考，仍有独立 Token 契约，不是当前默认服务，不支持新客户端免 Token 连接。当前服务用 `bash start-server.sh` 启动，不需要 Python/uv 环境。
