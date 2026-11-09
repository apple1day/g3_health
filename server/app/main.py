from __future__ import annotations

import asyncio
import json
import secrets
import sqlite3
from contextlib import asynccontextmanager
from datetime import datetime, timedelta, timezone

from fastapi import FastAPI, HTTPException, Request
from pydantic import ValidationError
from starlette.concurrency import run_in_threadpool
from starlette.middleware.cors import CORSMiddleware
from starlette.responses import Response

from .models import Snapshot
from .settings import Settings
from .storage import SnapshotStore, StaleSnapshot

MAX_BODY_BYTES = 128 * 1024


def reject_duplicate_keys(pairs: list[tuple[str, object]]) -> dict:
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("Duplicate JSON key")
        result[key] = value
    return result


def reject_non_json_constant(_: str) -> None:
    raise ValueError("Non-finite JSON number")


async def read_body(request: Request) -> bytes:
    if request.headers.get("content-encoding", "identity").lower() != "identity":
        raise HTTPException(415, "Compressed request bodies are not accepted.")
    if request.headers.get("content-type", "").split(";", 1)[0].strip().lower() != "application/json":
        raise HTTPException(415, "Content-Type must be application/json.")
    declared_length = request.headers.get("content-length")
    if declared_length is not None:
        try:
            length = int(declared_length)
            if length < 0:
                raise ValueError()
        except ValueError:
            raise HTTPException(400, "Invalid request size.") from None
        if length > MAX_BODY_BYTES:
            raise HTTPException(413, "Snapshot exceeds the 128 KiB limit.")
    body = bytearray()
    try:
        async with asyncio.timeout(15):
            async for chunk in request.stream():
                if len(body) + len(chunk) > MAX_BODY_BYTES:
                    raise HTTPException(413, "Snapshot exceeds the 128 KiB limit.")
                body.extend(chunk)
    except TimeoutError:
        raise HTTPException(408, "Snapshot upload timed out.") from None
    return bytes(body)


def authenticate(request: Request, expected_token: str) -> None:
    headers = request.headers.getlist("authorization")
    if len(headers) != 1:
        raise HTTPException(401, "A valid scoped bearer token is required.", headers={"WWW-Authenticate": "Bearer"})
    parts = headers[0].split(" ")
    supplied = parts[1] if len(parts) == 2 and parts[0].lower() == "bearer" else ""
    valid = secrets.compare_digest(supplied.encode("utf-8"), expected_token.encode("utf-8"))
    if not valid:
        raise HTTPException(401, "A valid scoped bearer token is required.", headers={"WWW-Authenticate": "Bearer"})


def create_app(settings: Settings | None = None) -> FastAPI:
    @asynccontextmanager
    async def lifespan(app: FastAPI):
        app.state.settings = settings or Settings.from_env()
        app.state.store = await run_in_threadpool(SnapshotStore, app.state.settings.data_path)
        yield

    app = FastAPI(title="Health Snapshot Relay", version="0.1.0", lifespan=lifespan,
                  docs_url=None, redoc_url=None, openapi_url=None)

    class ConfiguredCORS:
        """Configure Starlette's CORS middleware after lifespan loaded settings."""

        def __init__(self, app):
            self.app = app
            self.configured = None

        async def __call__(self, scope, receive, send):
            if scope["type"] != "http":
                await self.app(scope, receive, send)
                return
            if self.configured is None:
                self.configured = CORSMiddleware(
                    self.app,
                    allow_origins=list(scope["app"].state.settings.allowed_origins),
                    allow_credentials=False,
                    allow_methods=["GET", "PUT", "DELETE"],
                    allow_headers=["Authorization", "Content-Type"],
                    max_age=600,
                )
            await self.configured(scope, receive, send)

    class PrivateResponses:
        def __init__(self, app):
            self.app = app

        async def __call__(self, scope, receive, send):
            async def send_private(message):
                if message["type"] == "http.response.start":
                    headers = list(message.get("headers", []))
                    headers.extend([
                        (b"cache-control", b"no-store"),
                        (b"pragma", b"no-cache"),
                        (b"x-content-type-options", b"nosniff"),
                    ])
                    message = {**message, "headers": headers}
                await send(message)
            await self.app(scope, receive, send_private)

    app.add_middleware(ConfiguredCORS)
    app.add_middleware(PrivateResponses)

    @app.get("/healthz")
    async def healthz():
        return {"status": "ok", "apiVersion": 1}

    @app.get("/v1/snapshot")
    async def get_snapshot(request: Request):
        authenticate(request, request.app.state.settings.read_token)
        try:
            value = await run_in_threadpool(request.app.state.store.get)
        except (sqlite3.Error, OSError, json.JSONDecodeError):
            raise HTTPException(503, "Snapshot storage is temporarily unavailable.") from None
        if value is None:
            raise HTTPException(404, "No health snapshot has been uploaded yet.")
        return value

    @app.put("/v1/snapshot")
    async def put_snapshot(request: Request):
        cfg = request.app.state.settings
        authenticate(request, cfg.upload_token)
        raw = await read_body(request)
        try:
            # Reject duplicate keys and non-JSON NaN/Infinity before strict schema validation.
            parsed = json.loads(raw, object_pairs_hook=reject_duplicate_keys, parse_constant=reject_non_json_constant)
            # Inspect decoded strings too, so Unicode escapes cannot hide a credential.
            normalized = json.dumps(parsed, ensure_ascii=False)
            if cfg.upload_token in normalized or cfg.read_token in normalized:
                raise ValueError("Credential in snapshot")
            snapshot = Snapshot.model_validate_json(raw)
        except (ValidationError, ValueError, UnicodeDecodeError, RecursionError):
            raise HTTPException(422, "Invalid snapshot. Check schema v1, timestamps, units, and field types.") from None
        if snapshot.dataMode != "healthkit":
            raise HTTPException(422, "Demo data stays on the device and cannot be uploaded.")
        if snapshot.generatedAt > datetime.now(timezone.utc) + timedelta(minutes=5):
            raise HTTPException(422, "Snapshot timestamp is in the future. Check the phone clock.")
        try:
            received_at = await run_in_threadpool(request.app.state.store.put, snapshot)
        except StaleSnapshot:
            raise HTTPException(409, "An equal or newer snapshot is already stored. Refresh on the phone before retrying.") from None
        except (sqlite3.Error, OSError):
            raise HTTPException(503, "Snapshot storage is temporarily unavailable.") from None
        return {"receivedAt": received_at}

    @app.delete("/v1/snapshot", status_code=204)
    async def delete_snapshot(request: Request):
        authenticate(request, request.app.state.settings.upload_token)
        try:
            await run_in_threadpool(request.app.state.store.delete)
        except (sqlite3.Error, OSError):
            raise HTTPException(503, "Snapshot storage is temporarily unavailable.") from None
        return Response(status_code=204)

    return app


app = create_app()
