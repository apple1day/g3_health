# 健康摘要中转服务

单用户实例：每个部署只保存一份最新摘要，不提供多用户登录或公共数据查询。iPhone 使用上传令牌；Even 插件使用不同的只读令牌。真实健康数据保存在本机 SQLite 中，演示数据不能上传。

## 本机运行

建议从仓库根目录运行 `./start-server.sh`。手工启动方式：

```bash
python3 -m venv server/.venv
server/.venv/bin/python -m pip install -r server/requirements.txt
python3 server/tools/init_config.py
server/.venv/bin/python -m uvicorn app.main:app --app-dir server --host 0.0.0.0 --port 8787 --no-access-log
```

Python 3.11 及以上。首次初始化生成 `server/.env`，不会覆盖已有配置，也不会打印令牌。请只在自己的电脑上打开此文件，将 `UPLOAD_TOKEN` 填入 iPhone App，将 `READ_TOKEN` 填入 Even 插件。两者不能相同。

健康检查：`http://127.0.0.1:8787/healthz`。该端点只返回服务状态和协议版本。

同一 Wi-Fi 下，手机使用电脑的局域网 IP，而非手机自己的 `localhost`。若 Even 插件预检被 CORS 阻止，可在局域网测试期间显式设置 `ALLOWED_ORIGINS=*` 并重启服务；正式部署应填写实际插件 Origin。CORS 不代替令牌认证。

## 环境变量

| 变量 | 含义 |
| --- | --- |
| `UPLOAD_TOKEN` | 32–256 个 URL-safe 字符，只能上传／删除摘要 |
| `READ_TOKEN` | 与上传令牌不同，只能读取摘要 |
| `DATA_PATH` | 默认 `server/data/snapshot.sqlite3`；相对路径以 server 目录为基准 |
| `ALLOWED_ORIGINS` | 逗号分隔的精确 Origin；默认 Vite 本机地址；显式 `*` 适用于开发 |

系统环境变量优先于 `.env`。`server/.env`、数据库和虚拟环境均被忽略。

## API

- `GET /healthz`：无须令牌。
- `PUT /v1/snapshot`：`Authorization: Bearer UPLOAD_TOKEN`，JSON 为 `../shared/CONTRACT.md` 中的摘要，返回 `{ "receivedAt": "..." }`。
- `GET /v1/snapshot`：`Authorization: Bearer READ_TOKEN`，返回 `{ "snapshot": {...}, "receivedAt": "..." }`；尚未上传为 404。
- `DELETE /v1/snapshot`：上传令牌，幂等 204。

服务拒绝演示摘要、超过 128 KiB 的实际请求体、非 JSON 数值、未知字段、无时区时间戳及过期上传。相同内容、相同生成时间的重试是幂等的；同一时间但内容不同返回 409。`generatedAt` 比服务器时间超前超过 5 分钟时，请校准手机／服务器时钟。错误响应不会回显请求数据或令牌。

数据文件仅保存最新摘要。删除会移除当前记录，SQLite 开启 secure_delete；这不承诺清除备份、文件系统快照或底层介质上的历史副本。

## 部署

本地 HTTP 仅供局域网调试。正式使用请将服务放在带有效证书的 HTTPS 反向代理后面，不要将开发端口直接暴露到公网。代理同样应限制请求体和上传超时，避免记录 Authorization、请求体和含凭据的 URL。不要将令牌放进 URL。

```bash
docker build -t g3-health-relay server
docker run --rm --env-file server/.env \
  -e DATA_PATH=/data/snapshot.sqlite3 \
  -v g3-health-data:/data \
  -p 127.0.0.1:8787:8787 g3-health-relay
```

容器使用非 root 用户，并使用 `/data` 持久卷。TLS、域名和凭据由部署者配置。升级前可在停止服务后备份自己的数据库；备份也包含健康摘要，应保存在私有位置。

## 测试

```bash
python3 -m pip install -r server/requirements-dev.txt
cd server
python3 -m unittest discover -s tests -v
```

所有测试使用临时数据库和明确的合成样本，不读取真实健康记录。
