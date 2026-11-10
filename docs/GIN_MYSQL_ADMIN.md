# Gin + MySQL + Vue 管理后台（0.2）

## 手机提示 UPLOAD_TOKEN

旧服务的令牌在 **Mac 项目目录 `server/.env`**，不是 Apple、MySQL 或 Even 的账号密码。
`open -e server/.env` 后，把 `UPLOAD_TOKEN=` 后面的完整值粘贴到 iPhone。不要填字段名称，不要填 `READ_TOKEN`，不要把令牌发到聊天、截图或 GitHub。

新版本首次初始化会读取旧 `.env`，原样保留上传/读取令牌；独立生成后台管理令牌。之后以 `backend/config.local.yaml` 为准，修改旧 `.env` 不会改变新服务。

## 安装与启动

需要 Go 1.25+、Node 22.12+（推荐 Node 24）、MySQL 8.0+；CI 使用 MySQL 8.4。新后端不需要 Python、uv 或激活 `.venv`。

先在旧 Python 服务终端按 `Control+C`，释放 8787 端口。不要通过重建虚拟环境解决新服务问题。

```bash
git pull --ff-only origin main
bash setup-backend.sh
bash start-server.sh
```

首次 `setup-backend.sh` 会询问 MySQL 密码，输入不会显示。按你的本机配置填写密码即可。脚本会创建 `backend/config.local.yaml`，复用旧上传/读取令牌，新建管理令牌，并尝试 `CREATE DATABASE IF NOT EXISTS` 和非破坏性的建表，再构建 Vue。再次运行不会覆盖配置。

生成的数据库配置遵循：

```yaml
mysql:
  prefix: ""
  port: "3306"
  config: charset=utf8mb4&parseTime=True&loc=Local
  db-name: g3_health
  username: root
  password: "在首次配置的密码提示中输入；不要把真实值提交到 Git"
  path: 127.0.0.1
```

这里的 127.0.0.1 是 **运行 Go 服务的 Mac**；iPhone 仍使用 Mac 的局域网 IP，例如 `http://192.168.19.152:8787`，不能使用 127.0.0.1。Docker 内访问宿主机须使用实际可达的地址，本版脚本默认原生 Mac 运行，不自动启动 MySQL 或 Docker。

已有配置需要修改时，在 Mac 执行：

```bash
open -e backend/config.local.yaml
```

服务健康检查：`http://127.0.0.1:8787/healthz`。
管理后台：`http://127.0.0.1:8787/admin/`。

## 三种令牌

| 用途 | 本机配置 | macOS 复制命令 |
|---|---|---|
| iPhone 上传/删除 | `security.upload-token` | `bash copy-token.sh upload` |
| Even 插件读取最新摘要 | `security.read-token` | `bash copy-token.sh read` |
| Vue 管理后台只读查看 | `security.admin-token` | `bash copy-token.sh admin` |

复制命令使用系统剪贴板，不输出令牌到终端。后台登录使用管理令牌，不是 MySQL 用户名/密码。令牌只在页面内存中保存；刷新页面、关闭页面或退出后需重新登录。后台 API 不返回任何令牌。

iPhone 保存配置之后，回首页读取/手动上传真实摘要，再刷新管理页面。保存连接设置本身不会上传健康数据。若仍无记录，核对非演示模式、健康授权、手机与 Mac 的网络连通、iOS 局域网权限、Mac 防火墙和服务地址。

## 兼容和数据口径

`GET/PUT/DELETE /v1/snapshot` 和现有 JSON v1 保持兼容，无需因后端升级重装 iPhone 或改 Even 插件。

- 每次更新的摘要保存为一条历史记录；相同生成时间、相同内容的重试不重复插入，保留原接收时间。
- 比最新摘要更旧的上传返回 409，避免覆盖最新数据；同时间不同内容也返回 409。
- 日趋势/每日表格选该手机日期的最后一份摘要，不把不同上传的步数、能量、睡眠直接累加。
- 跨时区时按手机提供的本地日期分组，每条记录保留手机时区。界面时间按浏览器本地时区显示。
- 「最新摘要」不受历史日期筛选影响，旧日数据有明确标识；日期筛选作用于趋势、每日表和上传历史。
- null/缺失不是零；心率保留实际测量时间；运动是最近一条已完成记录，不代表所有运动历史。
- 当前只接收 App 已有的摘要，不会主动访问 Apple 健康云服务，不包含完整逐样本心率/所有运动。历史从启用保存时开始，不能补齐未上传的日期。
- 原 SQLite 文件不删除、不自动导入。升级后在 iPhone 上传一次即可建立新库最新摘要；需要保留旧 SQLite 时先备份，勿提交到仓库。
- **iPhone 的删除服务器数据功能会删除 MySQL 中全部摘要历史和最新数据。**不会自动清除独立备份、旧 SQLite 文件或其他设备缓存。

## 数据表

表前缀按配置生效；默认不加前缀。

| 表 | 用途 |
|---|---|
| `health_snapshots` | 不可变摘要历史；JSON payload、手机日期/时区、生成和接收时间、常用数值及摘要哈希 |
| `health_state` | 单用户最新记录指针、schema 版本；使用 InnoDB 行锁串行化上传和删除 |

数据库时间排序使用 UTC Unix 纳秒 BIGINT，完整 ISO 时间保存在 JSON 中；不依赖 MySQL 会话时区，避免 `loc=Local` 导致时间误转换。手动 SQL 查询不要把历史行的 `steps` 相加。

数据库表使用 `CREATE TABLE IF NOT EXISTS`，不会 DROP 用户已有数据。第一次 setup 默认申请建库权限；无建库权限时，请让管理员创建 `g3_health`，再运行：

```bash
cd backend
go run ./cmd/health-server migrate
```

## 管理 API（独立 ADMIN_TOKEN）

- `GET /api/admin/me`：验证只读管理令牌。
- `GET /api/admin/overview`：最新摘要、记录数、日期数、首末日期。
- `GET /api/admin/snapshots?from=2026-11-01&to=2026-11-10&page=1&pageSize=20`：分页历史；每页最多 100 条。
- `GET /api/admin/snapshots/:id`：单条详情。
- `GET /api/admin/days?from=2026-11-01&to=2026-11-10`：按天最后一条，最多 366 天。

请求均使用 `Authorization: Bearer ...`，不通过 URL 传令牌。iPhone 上传令牌不能读取后台；眼镜读取令牌不能写入；后台令牌也不能上传/删除。

## 开发与回退

生产构建由 Gin 同源提供 `/admin/`。开发 Vue 热更新可运行 `bash start-admin.sh`，访问 `http://127.0.0.1:5174/admin/`；Vite 代理 `/api` 到 8787，管理 API 不开启跨域 CORS。

Even 原有网络白名单仍需配置。新服务的 `server.allowed-origins` 首次继承旧 `.env`；本机扫码调试可显式使用 `['*']`，正式部署配置真实 origin。CORS 不替代身份验证。

旧 Python 代码仍保留在 `server/`。紧急回退先停止 Go，然后运行 `bash start-server-python.sh`。它优先使用 uv，保留已有环境；使用旧 SQLite，不与 MySQL 同步。不能把两个服务同时绑定在 8787。

## 验证与隐私边界

```bash
cd backend
go test -tags nomsgpack -race ./...
```

MySQL 集成测试仅在显式 `MYSQL_INTEGRATION=1` 时运行，固定使用隔离库 `g3_health_ci` 和唯一测试表前缀，结束清理测试表。正常测试不会连接用户的 `g3_health`。CI 还运行真实 MySQL 8.4、Vue 构建及浏览器/API 端到端测试，数据全部为人工测试样例。

默认 HTTP 只用于可信局域网测试。root/弱密码适合临时本机验证，不适合公网。正式使用需 HTTPS、受限 MySQL 账号、私有网络、受保护的磁盘和加密备份。本项目没有宣称提供数据库透明加密、医疗合规或多用户隔离。

`config.local.yaml` 为 0600 且被 Git 忽略，但它仍含明文凭据；请保护本机。应用不打印请求体、令牌、密码或 SQL 连接字符串。不要把真实健康数据库、导出数据、配置和截图上传到公开仓库。
