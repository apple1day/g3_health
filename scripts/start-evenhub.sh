#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
if ! command -v npm >/dev/null 2>&1; then
  echo "请先安装 Node.js 22.13+（推荐 24 LTS）。" >&2
  exit 1
fi
cd "$ROOT_DIR/evenhub"
npm ci
exec npm run dev -- --host 0.0.0.0 "$@"
