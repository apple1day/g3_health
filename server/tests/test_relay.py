from __future__ import annotations

import asyncio
import copy
import json
import os
import random
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import patch
from zoneinfo import ZoneInfo

import httpx
from fastapi.testclient import TestClient

from app.main import MAX_BODY_BYTES, create_app
from app.models import Snapshot
from app.settings import Settings
from app.storage import SnapshotStore, StaleSnapshot

UPLOAD = "test-upload-" + "a" * 40
READ = "test-reader-" + "b" * 40
ROOT = Path(__file__).resolve().parents[2]


def payload() -> dict:
    data = json.loads((ROOT / "shared" / "snapshot.example.json").read_text())
    data["dataMode"] = "healthkit"
    generated = datetime.now(timezone.utc) - timedelta(hours=2)
    data["generatedAt"] = generated.isoformat().replace("+00:00", "Z")
    data["day"] = generated.astimezone(ZoneInfo(data["timeZone"])).date().isoformat()
    data["warnings"] = []
    data["sleep"]["sourceName"] = "Synthetic test source"
    return data


def auth(token: str) -> dict[str, str]:
    return {"Authorization": "Bearer " + token}


class RelayTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.settings = Settings(UPLOAD, READ, Path(self.temp.name) / "data" / "snapshot.sqlite3")
        self.app = create_app(self.settings)
        self.client = TestClient(self.app)
        self.client.__enter__()

    def tearDown(self):
        self.client.__exit__(None, None, None)
        self.temp.cleanup()

    def upload(self, data=None, token=UPLOAD):
        return self.client.put("/v1/snapshot", json=data if data is not None else payload(), headers=auth(token))

    def test_health_check_exposes_no_snapshot_or_configuration(self):
        self.assertEqual(self.client.get("/healthz").json(), {"status": "ok", "apiVersion": 1})
        self.assertEqual(self.client.get("/openapi.json").status_code, 404)

    def test_authentication_happens_before_body_parsing(self):
        response = self.client.put("/v1/snapshot", content=b"invalid" * MAX_BODY_BYTES)
        self.assertEqual(response.status_code, 401)
        self.assertEqual(self.client.get("/v1/snapshot").status_code, 401)

    def test_scoped_tokens_cannot_cross_roles(self):
        self.assertEqual(self.upload(token=READ).status_code, 401)
        self.assertEqual(self.client.get("/v1/snapshot", headers=auth(UPLOAD)).status_code, 401)
        self.assertEqual(self.client.delete("/v1/snapshot", headers=auth(READ)).status_code, 401)

    def test_duplicate_authorization_headers_are_rejected(self):
        response = self.client.get("/v1/snapshot", headers=[("Authorization", "Bearer " + READ), ("Authorization", "Bearer " + UPLOAD)])
        self.assertEqual(response.status_code, 401)

    def test_uninitialized_store_returns_404(self):
        self.assertEqual(self.client.get("/v1/snapshot", headers=auth(READ)).status_code, 404)

    def test_upload_read_and_durable_restart(self):
        data = payload()
        result = self.upload(data)
        self.assertEqual(result.status_code, 200, result.text)
        self.assertEqual(set(result.json()), {"receivedAt"})
        with TestClient(create_app(self.settings)) as restarted:
            response = restarted.get("/v1/snapshot", headers=auth(READ))
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["snapshot"]["activity"]["steps"], 6820)
        self.assertEqual(response.json()["snapshot"]["heartRate"]["measuredAt"], data["heartRate"]["measuredAt"])
        self.assertEqual(response.json()["receivedAt"], result.json()["receivedAt"])
        self.assertEqual(response.headers["cache-control"], "no-store")
        self.assertEqual(self.settings.data_path.stat().st_mode & 0o777, 0o600)

    def test_optional_null_details_can_be_omitted(self):
        data = payload()
        data["sleep"] = {"status": "empty"}
        data["activity"] = {"status": "empty", "moveMode": "unknown"}
        data["heartRate"] = {"status": "empty"}
        data["workout"] = {"status": "empty"}
        self.assertEqual(self.upload(data).status_code, 200)
        result = self.client.get("/v1/snapshot", headers=auth(READ)).json()["snapshot"]
        self.assertIsNone(result["activity"]["steps"])
        self.assertEqual(result["sleep"]["status"], "empty")

    def test_native_error_and_explicit_null_sections_are_accepted(self):
        data = payload()
        data["sleep"] = {"status": "error", "totalMinutes": None, "sourceName": None}
        data["heartRate"] = {"status": "empty", "bpm": None, "measuredAt": None}
        data["warnings"] = ["睡眠读取暂未完成，请解锁后重试。"]
        self.assertEqual(self.upload(data).status_code, 200)
        stored = self.client.get("/v1/snapshot", headers=auth(READ)).json()["snapshot"]
        self.assertEqual(stored["sleep"]["status"], "error")
        self.assertIsNone(stored["heartRate"]["bpm"])

    def test_missing_or_null_data_mode_is_not_inferred_as_real(self):
        for include in [False, True]:
            data = payload()
            if include:
                data["dataMode"] = None
            else:
                data.pop("dataMode")
            self.assertEqual(self.upload(data).status_code, 422)

    def test_demo_is_not_persisted(self):
        data = payload()
        data["dataMode"] = "demo"
        response = self.upload(data)
        self.assertEqual(response.status_code, 422)
        self.assertIn("Demo data", response.json()["detail"])
        self.assertEqual(self.client.get("/v1/snapshot", headers=auth(READ)).status_code, 404)

    def test_stale_and_conflicting_uploads_cannot_replace_current(self):
        data = payload()
        self.assertEqual(self.upload(data).status_code, 200)
        old = copy.deepcopy(data)
        old["generatedAt"] = (datetime.fromisoformat(data["generatedAt"].replace("Z", "+00:00")) - timedelta(minutes=5)).isoformat()
        old["day"] = datetime.fromisoformat(old["generatedAt"]).astimezone(ZoneInfo(old["timeZone"])).date().isoformat()
        old["activity"]["steps"] = 1
        self.assertEqual(self.upload(old).status_code, 409)
        conflicting = copy.deepcopy(data)
        conflicting["activity"]["steps"] = 2
        self.assertEqual(self.upload(conflicting).status_code, 409)
        result = self.client.get("/v1/snapshot", headers=auth(READ)).json()
        self.assertEqual(result["snapshot"]["activity"]["steps"], 6820)

    def test_identical_retry_keeps_original_receipt(self):
        data = payload()
        first = self.upload(data)
        second = self.upload(data)
        self.assertEqual(second.status_code, 200)
        self.assertEqual(first.json(), second.json())

    def test_delete_is_idempotent(self):
        self.assertEqual(self.upload().status_code, 200)
        for _ in range(2):
            response = self.client.delete("/v1/snapshot", headers=auth(UPLOAD))
            self.assertEqual(response.status_code, 204)
            self.assertEqual(response.content, b"")
        self.assertEqual(self.client.get("/v1/snapshot", headers=auth(READ)).status_code, 404)

    def test_invalid_payloads_return_sanitized_errors(self):
        for value in [True, -1, "42", float("nan"), float("inf")]:
            with self.subTest(value=value):
                data = payload()
                data["activity"]["steps"] = value
                raw = json.dumps(data)
                response = self.client.put("/v1/snapshot", content=raw, headers={**auth(UPLOAD), "Content-Type": "application/json"})
                self.assertEqual(response.status_code, 422)
                self.assertNotIn("input", response.text)
        data = payload()
        data["unexpected"] = "private payload should not be echoed"
        response = self.upload(data)
        self.assertEqual(response.status_code, 422)
        self.assertNotIn(data["unexpected"], response.text)

    def test_invalid_dates_and_naive_timestamps_are_rejected(self):
        for key, value in [("day", "2026-02-30"), ("day", "20261109"), ("timeZone", "not/a-timezone"), ("generatedAt", "2026-11-09T02:00:00"), ("generatedAt", 1730000000)]:
            with self.subTest(key=key, value=value):
                data = payload()
                data[key] = value
                self.assertEqual(self.upload(data).status_code, 422)
        data = payload()
        data["heartRate"].pop("measuredAt")
        self.assertEqual(self.upload(data).status_code, 422)

    def test_future_clock_is_rejected(self):
        data = payload()
        generated = datetime.now(timezone.utc) + timedelta(hours=1)
        data["generatedAt"] = generated.isoformat()
        data["day"] = generated.astimezone(ZoneInfo(data["timeZone"])).date().isoformat()
        self.assertEqual(self.upload(data).status_code, 422)

    def test_malformed_duplicate_and_compressed_json_rejected(self):
        for raw in [b"not json", b'{"schemaVersion":1,"schemaVersion":2}', b"[[]]", b"\xff\xff"]:
            response = self.client.put("/v1/snapshot", content=raw, headers={**auth(UPLOAD), "Content-Type": "application/json"})
            self.assertEqual(response.status_code, 422)
        response = self.client.put("/v1/snapshot", content=b"fake", headers={**auth(UPLOAD), "Content-Type": "application/json", "Content-Encoding": "gzip"})
        self.assertEqual(response.status_code, 415)

    def test_body_limit_enforced_even_when_length_is_forged(self):
        response = self.client.put("/v1/snapshot", content=b" " * (MAX_BODY_BYTES + 1), headers={**auth(UPLOAD), "Content-Type": "application/json", "Content-Length": "2"})
        self.assertEqual(response.status_code, 413)

    def test_body_limit_enforced_for_chunked_stream(self):
        async def request():
            async def chunks():
                for _ in range(5):
                    yield b" " * (MAX_BODY_BYTES // 4)
            transport = httpx.ASGITransport(app=self.app)
            async with httpx.AsyncClient(transport=transport, base_url="http://test") as client:
                return await client.put("/v1/snapshot", content=chunks(), headers={**auth(UPLOAD), "Content-Type": "application/json"})
        self.assertEqual(asyncio.run(request()).status_code, 413)

    def test_tokens_cannot_accidentally_enter_the_payload(self):
        data = payload()
        data["warnings"] = ["accidentally copied " + UPLOAD]
        raw = json.dumps(data).replace(UPLOAD, "".join("\\u%04x" % ord(c) for c in UPLOAD))
        response = self.client.put("/v1/snapshot", content=raw, headers={**auth(UPLOAD), "Content-Type": "application/json"})
        self.assertEqual(response.status_code, 422)
        self.assertNotIn(UPLOAD, response.text)
        self.assertNotIn(READ, response.text)

    def test_cors_preflight_and_auth_are_independent(self):
        headers = {"Origin": "http://localhost:5173", "Access-Control-Request-Method": "GET", "Access-Control-Request-Headers": "Authorization"}
        preflight = self.client.options("/v1/snapshot", headers=headers)
        self.assertEqual(preflight.status_code, 200)
        self.assertEqual(preflight.headers["access-control-allow-origin"], headers["Origin"])
        self.assertNotIn("access-control-allow-credentials", preflight.headers)
        response = self.client.get("/v1/snapshot", headers={"Origin": headers["Origin"]})
        self.assertEqual(response.status_code, 401)
        self.assertEqual(response.headers["access-control-allow-origin"], headers["Origin"])
        headers["Origin"] = "https://untrusted.example"
        self.assertEqual(self.client.options("/v1/snapshot", headers=headers).status_code, 400)

    def test_concurrent_uploads_keep_newest_generation(self):
        base = payload()
        stamp = datetime.fromisoformat(base["generatedAt"].replace("Z", "+00:00"))
        values = []
        for index in range(16):
            item = copy.deepcopy(base)
            generated = stamp + timedelta(seconds=index)
            item["generatedAt"] = generated.isoformat()
            item["day"] = generated.astimezone(ZoneInfo(item["timeZone"])).date().isoformat()
            item["activity"]["steps"] = index
            values.append(Snapshot.model_validate_json(json.dumps(item)))
        random.Random(41).shuffle(values)
        store = SnapshotStore(self.settings.data_path)
        def write(snapshot):
            try:
                return store.put(snapshot)
            except StaleSnapshot:
                return None
        with ThreadPoolExecutor(max_workers=8) as pool:
            list(pool.map(write, values))
        self.assertEqual(store.get()["snapshot"]["activity"]["steps"], 15)


class SettingsTests(unittest.TestCase):
    def test_insecure_tokens_fail_without_echoing_them(self):
        for upload, read in [("short", READ), (UPLOAD, UPLOAD), ("x" * 31, READ), ("a secret value " * 4, READ)]:
            with self.subTest(upload_length=len(upload)):
                with self.assertRaises(ValueError) as raised:
                    Settings(upload, read, Path("/tmp/test.sqlite3"))
                self.assertNotIn(READ, str(raised.exception))
                self.assertNotIn(UPLOAD, str(raised.exception))

    def test_origins_reject_credentials_and_paths(self):
        for origins in [("https://example.com/path",), ("https://user:pass@example.com",), ("*", "http://localhost:5173")]:
            with self.assertRaises(ValueError):
                Settings(UPLOAD, READ, Path("/tmp/test.sqlite3"), origins)
        Settings(UPLOAD, READ, Path("/tmp/test.sqlite3"), ("*",))
        Settings(UPLOAD, READ, Path("/tmp/test.sqlite3"), ("null",))

    def test_environment_overrides_dotenv_without_working_directory_dependency(self):
        with tempfile.TemporaryDirectory() as temp:
            with patch.dict(os.environ, {"UPLOAD_TOKEN": UPLOAD, "READ_TOKEN": READ, "DATA_PATH": temp + "/test.sqlite3", "ALLOWED_ORIGINS": "*"}):
                cfg = Settings.from_env()
        self.assertEqual(cfg.data_path, Path(temp) / "test.sqlite3")
        self.assertEqual(cfg.allowed_origins, ("*",))
        self.assertNotIn(UPLOAD, repr(cfg))


if __name__ == "__main__":
    unittest.main()
