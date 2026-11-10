#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ROLE="${1:-upload}"
case "$ROLE" in upload|read|admin) ;; *) echo '用法：bash copy-token.sh upload|read|admin' >&2; exit 1;; esac
command -v pbcopy >/dev/null 2>&1 || { echo '自动复制适用于 macOS。其他系统请在本机编辑器查看 backend/config.local.yaml。' >&2; exit 1; }
cd "$ROOT_DIR/backend"
go run -tags nomsgpack ./cmd/health-server token --role "$ROLE" | pbcopy
echo "${ROLE} 令牌已复制到本机剪贴板；只粘贴到对应 App/后台，不要发送到聊天或截图。"
