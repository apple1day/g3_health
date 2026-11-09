#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
if ! command -v python3 >/dev/null 2>&1; then
  echo "需要 Python 3.11+。Mac 可运行 brew install python。" >&2
  exit 1
fi
python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3,11) else "需要 Python 3.11+")'
if [ ! -x "$ROOT_DIR/server/.venv/bin/python" ]; then
  python3 -m venv "$ROOT_DIR/server/.venv"
fi
"$ROOT_DIR/server/.venv/bin/python" -m pip install --disable-pip-version-check -r "$ROOT_DIR/server/requirements.txt"
"$ROOT_DIR/server/.venv/bin/python" "$ROOT_DIR/server/tools/init_config.py"
echo "配置文件：server/.env（只在本机保存；UPLOAD_TOKEN 给 iPhone，READ_TOKEN 给插件）。"
echo "本机检查：http://127.0.0.1:8787/healthz"
echo "iPhone 请填写 Mac 的局域网 IP，例如 http://192.168.1.20:8787，不能填 localhost。"
echo "局域网 HTTP 只用于开发验证；公网部署请使用 HTTPS。按 Ctrl+C 停止。"
cd "$ROOT_DIR"
exec "$ROOT_DIR/server/.venv/bin/uvicorn" app.main:app --app-dir "$ROOT_DIR/server" --host 0.0.0.0 --port "${PORT:-8787}" --no-access-log "$@"
