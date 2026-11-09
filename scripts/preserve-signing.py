#!/usr/bin/env python3
"""Retain this app's local signing selection across XcodeGen regeneration."""
import argparse
import json
import re
import subprocess
from pathlib import Path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--team", default="")
    parser.add_argument("--bundle-id", default="")
    args = parser.parse_args()
    if args.team and not re.fullmatch(r"[A-Za-z0-9]{10}", args.team):
        parser.error("Team ID 应为 10 位字母或数字")
    if args.bundle_id and not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", args.bundle_id):
        parser.error("Bundle ID 格式不正确")
    local = args.root / "ios/Config/Signing.local.xcconfig"
    current = local.read_text() if local.exists() else ""
    values = dict(re.findall(r"^(DEVELOPMENT_TEAM|HEALTH_BUNDLE_IDENTIFIER)\s*=\s*([^\r\n]+)", current, re.M))
    project = args.root / "ios/G3Health.xcodeproj"
    if project.exists() and not (args.team and args.bundle_id):
        try:
            result = subprocess.run(
                ["xcodebuild", "-showBuildSettings", "-json", "-project", str(project), "-scheme", "G3Health", "-configuration", "Debug"],
                capture_output=True, text=True, timeout=45, check=True,
            )
            target = next((v for v in json.loads(result.stdout) if v.get("target") == "G3Health"), None)
            if target:
                settings = target["buildSettings"]
                team = settings.get("DEVELOPMENT_TEAM", "").strip()
                bundle = settings.get("PRODUCT_BUNDLE_IDENTIFIER", "").strip()
                if re.fullmatch(r"[A-Za-z0-9]{10}", team):
                    values["DEVELOPMENT_TEAM"] = team
                if re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", bundle):
                    values["HEALTH_BUNDLE_IDENTIFIER"] = bundle
        except (OSError, ValueError, subprocess.SubprocessError):
            if not local.exists():
                raise SystemExit("无法读取旧工程签名配置，已停止以免覆盖。请使用 --team 与 --bundle-id 显式指定后重试。")
            print("旧工程设置暂不可读，保留已有 Signing.local.xcconfig。")
    if args.team:
        values["DEVELOPMENT_TEAM"] = args.team
    if args.bundle_id:
        values["HEALTH_BUNDLE_IDENTIFIER"] = args.bundle_id
    local.parent.mkdir(parents=True, exist_ok=True)
    if values:
        lines = ["// 本机签名配置；不会提交到 Git。", "// setup-ios.sh 会在重新生成工程前保留当前 Team / Bundle ID。"]
        lines += [f"{key} = {value.strip()}" for key, value in sorted(values.items())]
        local.write_text("\n".join(lines) + "\n")
        local.chmod(0o600)
        print("已保留本机 Team / Bundle ID 配置。")


if __name__ == "__main__":
    main()
