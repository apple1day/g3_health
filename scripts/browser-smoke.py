#!/usr/bin/env python3
"""Run the compiled web client against a disposable real relay using synthetic data.

Requires server/requirements-dev.txt, playwright, a Chromium installation, and
evenhub/dist from npm run build. No user credentials or health data are used.
"""
from __future__ import annotations

import functools
import http.server
import json
import os
import secrets
import socket
import subprocess
import sys
import tempfile
import threading
import time
from datetime import datetime, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

import httpx
from playwright.sync_api import expect, sync_playwright

ROOT = Path(__file__).resolve().parents[1]


class QuietFiles(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *_):
        pass


def main() -> None:
    if not (ROOT / "evenhub/dist/index.html").exists():
        raise SystemExit("Run npm run build in evenhub/ first.")
    artifacts = ROOT / "artifacts/browser"
    artifacts.mkdir(parents=True, exist_ok=True)
    static = http.server.ThreadingHTTPServer(
        ("127.0.0.1", 0), functools.partial(QuietFiles, directory=str(ROOT / "evenhub/dist")),
    )
    threading.Thread(target=static.serve_forever, daemon=True).start()
    web_url = f"http://127.0.0.1:{static.server_port}"
    with socket.socket() as address:
        address.bind(("127.0.0.1", 0))
        relay_port = address.getsockname()[1]
    api_url = f"http://127.0.0.1:{relay_port}"
    upload_token, read_token = secrets.token_urlsafe(32), secrets.token_urlsafe(32)
    with tempfile.TemporaryDirectory(prefix="health-glance-browser-") as temp:
        env = dict(os.environ, UPLOAD_TOKEN=upload_token, READ_TOKEN=read_token,
                   DATA_PATH=str(Path(temp) / "snapshot.sqlite3"), ALLOWED_ORIGINS=web_url)
        process = subprocess.Popen(
            [sys.executable, "-m", "uvicorn", "app.main:app", "--app-dir", str(ROOT / "server"),
             "--host", "127.0.0.1", "--port", str(relay_port), "--no-access-log"],
            env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        try:
            with httpx.Client(timeout=5, trust_env=False) as client:
                for _ in range(100):
                    try:
                        if client.get(api_url + "/healthz").status_code == 200:
                            break
                    except httpx.TransportError:
                        pass
                    if process.poll() is not None:
                        raise RuntimeError("Disposable relay failed to start.")
                    time.sleep(0.1)
                else:
                    raise RuntimeError("Disposable relay startup timed out.")

                fixture = json.loads((ROOT / "shared/snapshot.example.json").read_text())
                now = datetime.now(timezone.utc)
                fixture["generatedAt"] = now.isoformat().replace("+00:00", "Z")
                fixture["day"] = now.astimezone(ZoneInfo(fixture["timeZone"])).date().isoformat()
                headers = {"Authorization": "Bearer " + upload_token}
                assert client.put(api_url + "/v1/snapshot", headers=headers, json=fixture).status_code == 422
                fixture["dataMode"] = "healthkit"
                fixture["warnings"] = ["集成测试合成数据，不是用户的健康记录。"]
                fixture["sleep"]["sourceName"] = "Integration test Apple Watch"
                assert client.put(api_url + "/v1/snapshot", headers=headers, json=fixture).status_code == 200

                with sync_playwright() as playwright:
                    launch_options = {"headless": True}
                    if os.environ.get("BROWSER_EXECUTABLE"):
                        launch_options["executable_path"] = os.environ["BROWSER_EXECUTABLE"]
                    browser = playwright.chromium.launch(**launch_options)
                    page = browser.new_page(viewport={"width": 1440, "height": 1060}, device_scale_factor=1)
                    errors: list[str] = []
                    page.on("pageerror", lambda error: errors.append(str(error)))
                    page.goto(web_url, wait_until="networkidle")
                    expect(page.locator("#bridge-message")).to_contain_text("浏览器预览", timeout=10000)
                    expect(page.locator("#mode-pill")).to_have_text("等待数据")
                    page.locator("#demo-toggle").click()
                    expect(page.locator("#mode-pill")).to_have_text("演示数据")
                    expect(page.locator("#glass-hero")).to_contain_text("小时")
                    page.screenshot(path=str(artifacts / "plugin-desktop-demo.png"), full_page=True)
                    for tab in ("activity", "workout", "heartRate", "sleep"):
                        page.locator("#tab-" + tab).click()
                        expect(page.locator("#tab-" + tab)).to_have_attribute("aria-selected", "true")
                    assert not page.evaluate("document.documentElement.scrollWidth > innerWidth")
                    page.set_viewport_size({"width": 390, "height": 844})
                    assert not page.evaluate("document.documentElement.scrollWidth > innerWidth")
                    page.screenshot(path=str(artifacts / "plugin-mobile-demo.png"), full_page=True)
                    page.locator("#demo-toggle").click()
                    expect(page.locator("#mode-pill")).to_have_text("等待数据")
                    page.locator("#api-url").fill(api_url)
                    page.locator("#read-token").fill(read_token)
                    page.locator("#refresh").click()
                    expect(page.locator("#mode-pill")).to_have_text("真实数据", timeout=10000)
                    expect(page.locator("#metric-steps")).to_have_text("6,820")
                    expect(page.locator("#warning-list")).to_contain_text("集成测试合成数据")
                    assert not page.evaluate("Boolean(localStorage.getItem('g3-health.connection.v1'))")

                    page.route(api_url + "/v1/snapshot", lambda route: route.abort())
                    page.locator("#refresh").click()
                    expect(page.locator("#mode-pill")).to_have_text("缓存摘要", timeout=10000)
                    expect(page.locator("#metric-steps")).to_have_text("6,820")
                    expect(page.locator("#request-status")).to_contain_text("上次成功")
                    page.unroute(api_url + "/v1/snapshot")
                    page.locator("#read-token").fill(upload_token)
                    page.locator("#refresh").click()
                    expect(page.locator("#request-status")).to_contain_text("读取密钥无效", timeout=10000)
                    expect(page.locator("#mode-pill")).to_have_text("等待数据")
                    page.locator("#clear-config").click()
                    expect(page.locator("#api-url")).to_have_value("")
                    expect(page.locator("#read-token")).to_have_value("")
                    assert not errors, "Browser runtime errors occurred: " + "; ".join(errors)
                    browser.close()
            print("PASS: browser desktop/mobile layout, demo isolation, real relay read, scoped auth, offline cache and config clearing.")
        finally:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            static.shutdown()
            static.server_close()


if __name__ == "__main__":
    main()
