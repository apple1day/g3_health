#!/usr/bin/env python3
"""Create private relay settings once. Never print secret values."""
from __future__ import annotations

import os
import secrets
from pathlib import Path


def main() -> int:
    path = Path(__file__).resolve().parents[1] / ".env"
    contents = (
        "# Private single-user configuration. Do not commit or share this file.\n"
        "# Copy UPLOAD_TOKEN only to the iPhone app; READ_TOKEN only to the plugin.\n"
        f"UPLOAD_TOKEN={secrets.token_urlsafe(32)}\n"
        f"READ_TOKEN={secrets.token_urlsafe(32)}\n"
        "DATA_PATH=data/snapshot.sqlite3\n"
        "# LAN development only: change ALLOWED_ORIGINS to * when required.\n"
        "# Production: use the exact plugin origin, or null if the real WebView reports that origin.\n"
        "ALLOWED_ORIGINS=http://localhost:5173,http://127.0.0.1:5173\n"
    )
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        print("Existing server/.env retained; configuration was not overwritten.")
        return 0
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(contents)
    except BaseException:
        path.unlink(missing_ok=True)
        raise
    print("Created server/.env with private permissions. Tokens are not printed.")
    print("Open that file locally to configure your iPhone and plugin. Keep it out of Git.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
