#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
command -v go >/dev/null 2>&1 || { echo '需要 Go 1.25+：brew install go' >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo '需要 Node.js：推荐 Node 24 LTS' >&2; exit 1; }
command -v npm >/dev/null 2>&1 || { echo '需要 npm' >&2; exit 1; }
cd "$ROOT_DIR/backend"
if [ ! -f config.local.yaml ]; then
  if [ "${MYSQL_PASSWORD+x}" != x ]; then
    if [ ! -t 0 ]; then echo '首次配置请在交互终端运行，或通过环境变量设置 MYSQL_PASSWORD。' >&2; exit 1; fi
    printf '请输入本机 MySQL 密码（输入不显示）：' >&2
    IFS= read -r -s MYSQL_PASSWORD
    printf '\n' >&2
    export MYSQL_PASSWORD
  fi
  go run -tags nomsgpack ./cmd/health-server init-config
  unset MYSQL_PASSWORD
fi
go run -tags nomsgpack ./cmd/health-server migrate --create-database
cd "$ROOT_DIR/web-admin"
if [ -f package-lock.json ]; then npm ci; else npm install; fi
npm run build
echo '配置完成。启动：bash start-server.sh'
echo '管理后台：http://127.0.0.1:8787/admin/'
echo '免 Token：iPhone / Even 只填服务地址；后台直接打开，无需登录。'
echo '警告：仅用于可信局域网。能连接服务的人也能读取、上传、删除全部历史；禁止公网映射。'
echo '数据库密码仍在 backend/config.local.yaml 中；请勿提交或截图分享。'
