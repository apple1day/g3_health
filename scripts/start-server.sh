#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
command -v go >/dev/null 2>&1 || { echo '需要 Go 1.25+。Mac 可运行 brew install go。' >&2; exit 1; }
if [ ! -f "$ROOT_DIR/backend/config.local.yaml" ]; then
  echo '请先在仓库根目录运行 bash setup-backend.sh（配置 MySQL、迁移表、构建 Vue）。' >&2
  exit 1
fi
cd "$ROOT_DIR/backend"
exec go run ./cmd/health-server serve "$@"
