#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
if [ "$#" -ne 1 ]; then
  echo "用法：bash pack-evenhub.sh https://你的健康接口域名" >&2
  echo "请只填写 origin，不含路径、查询参数、令牌。" >&2
  exit 2
fi
cd "$ROOT_DIR/evenhub"
npm ci
npm run configure -- --api-url "$1"
npm run pack
