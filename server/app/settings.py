from __future__ import annotations

import os
import re
from dataclasses import dataclass, field
from pathlib import Path
from urllib.parse import urlsplit

from dotenv import dotenv_values

SERVER_ROOT = Path(__file__).resolve().parents[1]
TOKEN_PATTERN = re.compile(r"[A-Za-z0-9_-]{32,256}\Z")


@dataclass(frozen=True)
class Settings:
    upload_token: str = field(repr=False)
    read_token: str = field(repr=False)
    data_path: Path
    allowed_origins: tuple[str, ...] = ("http://localhost:5173", "http://127.0.0.1:5173")

    def __post_init__(self) -> None:
        if not TOKEN_PATTERN.fullmatch(self.upload_token) or not TOKEN_PATTERN.fullmatch(self.read_token):
            raise ValueError("UPLOAD_TOKEN and READ_TOKEN must each contain 32–256 URL-safe characters. Run tools/init_config.py.")
        if self.upload_token == self.read_token:
            raise ValueError("UPLOAD_TOKEN and READ_TOKEN must be different.")
        if "*" in self.allowed_origins and self.allowed_origins != ("*",):
            raise ValueError("ALLOWED_ORIGINS wildcard must be its only entry.")
        for origin in self.allowed_origins:
            if origin in {"*", "null"}:
                continue
            parsed = urlsplit(origin)
            if (parsed.scheme not in {"http", "https"} or not parsed.hostname
                    or parsed.username or parsed.password or parsed.query or parsed.fragment
                    or parsed.path not in {"", "/"}):
                raise ValueError("ALLOWED_ORIGINS must contain comma-separated HTTP(S) origins, null, or a single *.")
            if parsed.path == "/":
                raise ValueError("ALLOWED_ORIGINS origins must omit a trailing slash.")
        object.__setattr__(self, "data_path", Path(self.data_path).expanduser().resolve())

    @classmethod
    def from_env(cls) -> "Settings":
        # Use an absolute path so running uvicorn from the repository root works.
        values = {**dotenv_values(SERVER_ROOT / ".env"), **os.environ}
        data_path = Path(str(values.get("DATA_PATH") or "data/snapshot.sqlite3")).expanduser()
        if not data_path.is_absolute():
            data_path = SERVER_ROOT / data_path
        raw_origins = str(values.get("ALLOWED_ORIGINS", "http://localhost:5173,http://127.0.0.1:5173"))
        return cls(
            upload_token=str(values.get("UPLOAD_TOKEN") or ""),
            read_token=str(values.get("READ_TOKEN") or ""),
            data_path=data_path,
            allowed_origins=tuple(item.strip() for item in raw_origins.split(",") if item.strip()),
        )
