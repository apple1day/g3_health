# Gin + MySQL + Vue 管理后台（0.3）

## 免 Token 模式

手机仅填写服务地址；Vue `/admin/` 自动加载；Even 插件仅填写服务地址。后端 `/v1/snapshot` 与 `/api/admin/*` 不再要求 Bearer Token。数据库密码仍必需，HealthKit 读取仍需用户授权。当前不是多用户系统，也没有账号密码登录。

**能访问本服务的人都能读取、上传、删除健康历史。只在可信局域网使用，禁止公网映射、公开反向代理/隧道。HTTPS 只加密传输，不会建立身份认证。** CORS 仅限制浏览器来源，不阻止直接 API 客户端。

## 升级步骤

先停止旧服务，退出 Xcode；在根目录：

```bash
git pull --ff-only origin main
bash setup-backend.sh
bash start-server.sh
```

另开终端在仓库根目录运行 `bash setup-ios.sh`，Xcode 使用原来的 Team / Bundle ID，Command+R 覆盖安装 **0.3.0 (3)**。旧 App 的 Token 输入框不会因只更新后端而消失。

新服务保持 `/v1/snapshot` JSON v1 结构和 8787 端口。旧客户端已填写的 Authorization 头会被忽略；新客户端不发送该头。保留 MySQL 数据、原连接参数和已保存手机地址，不需要删库或删除手机 App。

旧 `backend/config.local.yaml` 的 `security` 段可保留，已弃用且不会触发 Token 校验；服务不会改写原文件。新建配置不再生成任何 Token，旧 `server/.env` 只用于首次迁移 CORS 配置。`copy-token.sh` 只提示无需 Token，不再复制凭据。

## 首次配置

需要 Go 1.25+、Node 22.12+（推荐 24）、已运行的 MySQL 8.0+。CI 使用 MySQL 8.4。运行 `bash setup-backend.sh`，在不回显提示中输入本机 MySQL 密码。配置生成到权限 0600、Git 忽略的 `backend/config.local.yaml`：

```yaml
mysql:
  prefix: ""
  port: "3306"
  config: charset=utf8mb4&parseTime=True&loc=Local
  db-name: g3_health
  username: root
  password: "在本机输入，不提交到仓库"
  path: 127.0.0.1
```

127.0.0.1 指运行 Go 的 Mac。手机填写 Mac 的局域网 IP（例如 `http://192.168.19.152:8787`），不是手机 localhost。脚本不自动启动 MySQL，也不配置 Docker。

```bash
open -e backend/config.local.yaml
curl -fsS http://127.0.0.1:8787/healthz
open "http://127.0.0.1:8787/admin/"
```

初始化使用 `CREATE DATABASE IF NOT EXISTS` / `CREATE TABLE IF NOT EXISTS`，不删除已有数据。无建库权限时由管理员先建立 `g3_health`，然后 `cd backend && go run -tags nomsgpack ./cmd/health-server migrate`。

## 数据与管理接口

| 表 | 用途 |
|---|---|
| `health_snapshots` | 完整摘要 JSON、生成/接收时间、手机日期/时区、常用数值与内容哈希 |
| `health_state` | 最新记录指针；InnoDB 行锁串行化写入和删除 |

每次新摘要保留历史，相同内容与生成时间的重试不重复写入；过期上传或相同时间不同内容返回 409。每日趋势取当天最后一份摘要，不将上传次数当作运动次数或将步数相加。null 不等于零；最近运动不是全部运动记录，心率保留采样时间。

- `GET /api/admin/me`：返回 `authMode: none`，不是登录验证。
- `GET /api/admin/overview`：最新摘要及记录统计。
- `GET /api/admin/snapshots?from=YYYY-MM-DD&to=YYYY-MM-DD&page=1&pageSize=20`：分页历史。
- `GET /api/admin/snapshots/:id`：详情。
- `GET /api/admin/days?from=YYYY-MM-DD&to=YYYY-MM-DD`：按天最后一份，最多 366 天。

全部无需 Token。Vue 当前只提供查看操作，但 API 使用者可直接调用 `DELETE /v1/snapshot` 删除全部数据。手机中有明确二次确认，**API 不提供身份保护**。

旧 SQLite 文件不删除、不导入。升级后上传一次建立新库最新摘要即可。删除 MySQL 数据不会清除旧 SQLite、备份或其它设备缓存。

## 开发和自动测试

默认由 Gin 同源提供 `/admin/`。Vue 热更新：`bash start-admin.sh`，访问 `http://127.0.0.1:5174/admin/`。Vite 代理 `/api` 到 8787。后台拒绝来自其它浏览器 origin 的 API 请求。

Even 白名单和 `server.allowed-origins` 仍然生效；推荐精确允许实际插件 origin。显式 `*` 会允许任何浏览器来源访问摘要，不建议长期使用。

```bash
cd backend
go test -tags nomsgpack -race ./...
```

MySQL 集成测试仅在 `MYSQL_INTEGRATION=1` 时执行，使用隔离库 `g3_health_ci` 与唯一表前缀。浏览器测试还要求显式 `HEALTH_E2E=isolated-ci-database` 并验证配置库名，不能指向个人库。

旧 Python 参考实现仍保留 Token 契约；它不支持当前免 Token 客户端，不要误用 `start-server-python.sh` 代替新 Gin 服务。
