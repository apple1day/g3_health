#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
OPEN_PROJECT=1
SIGNING_TEAM=""
SIGNING_BUNDLE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --no-open) OPEN_PROJECT=0; shift ;;
    --team) [ "$#" -ge 2 ] || { echo "--team 需要 Team ID" >&2; exit 2; }; SIGNING_TEAM="$2"; shift 2 ;;
    --bundle-id) [ "$#" -ge 2 ] || { echo "--bundle-id 需要 Bundle ID" >&2; exit 2; }; SIGNING_BUNDLE="$2"; shift 2 ;;
    --help|-h) echo "用法：bash setup-ios.sh [--no-open] [--team TEAMID] [--bundle-id com.example.health]"; exit 0 ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
done
if [ "$(uname -s)" != "Darwin" ]; then
  echo "iPhone 工程需要在安装了 Xcode 的 Mac 上生成和运行。" >&2
  exit 1
fi
if ! xcodebuild -version >/dev/null 2>&1; then
  echo "请先安装并打开 Xcode，然后选择完整的 Xcode 开发工具：" >&2
  echo "sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
  exit 1
fi
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "缺少 XcodeGen。请先运行 brew install xcodegen，再重新运行本脚本。" >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "缺少 Python 3，请先安装：brew install python" >&2
  exit 1
fi
if pgrep -x Xcode >/dev/null; then
  echo "请先按 Command + Q 退出 Xcode，避免工程生成与未保存的签名设置冲突。" >&2
  exit 1
fi
python3 "$ROOT_DIR/scripts/preserve-signing.py" --root "$ROOT_DIR" --team "$SIGNING_TEAM" --bundle-id "$SIGNING_BUNDLE"
xcodegen generate --spec "$ROOT_DIR/ios/project.yml" --project "$ROOT_DIR/ios"
echo "已生成 ios/G3Health.xcodeproj。"
echo "在 G3Health > Signing & Capabilities 选择你的 Team，连接 iPhone，选择真机后 Run。"
echo "默认 Bundle ID 为 com.anxiong.g3health；HealthKit 需要匹配的签名能力。"
if [ "$OPEN_PROJECT" -eq 1 ]; then
  open "$ROOT_DIR/ios/G3Health.xcodeproj"
fi
