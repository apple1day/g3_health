#!/usr/bin/env bash
# Explicit legacy fallback; does not read/write the new MySQL database.
set -euo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
if command -v uv >/dev/null 2>&1; then
  if [ ! -x server/.venv/bin/python ]; then uv venv --python 3.12 server/.venv; fi
  uv pip install --python server/.venv/bin/python -r server/requirements.txt
else
  command -v python3 >/dev/null || { echo '需要 uv 或 Python 3.11+' >&2; exit 1; }
  python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3,11) else "需要 Python 3.11+")'
  if [ ! -x server/.venv/bin/python ]; then python3 -m venv server/.venv; fi
  server/.venv/bin/python -m pip install -r server/requirements.txt
fi
server/.venv/bin/python server/tools/init_config.py
exec server/.venv/bin/python -m uvicorn app.main:app --app-dir server --host 0.0.0.0 --port "${PORT:-8787}" --no-access-log "$@"
