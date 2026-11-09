from __future__ import annotations

import json
import os
import sqlite3
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterator

from .models import Snapshot


class StaleSnapshot(Exception):
    """An earlier or conflicting upload cannot replace the current snapshot."""


class SnapshotStore:
    def __init__(self, path: Path):
        self.path = path
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        # Pre-create with private permissions instead of relying on process umask.
        fd = os.open(path, os.O_CREAT | os.O_WRONLY, 0o600)
        os.close(fd)
        os.chmod(path, 0o600)
        with self.connection() as connection:
            connection.execute("PRAGMA journal_mode=DELETE")
            connection.execute("""CREATE TABLE IF NOT EXISTS snapshot (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                generated_at REAL NOT NULL,
                received_at TEXT NOT NULL,
                payload TEXT NOT NULL
            )""")

    @contextmanager
    def connection(self) -> Iterator[sqlite3.Connection]:
        connection = sqlite3.connect(self.path, timeout=5, isolation_level=None)
        connection.execute("PRAGMA busy_timeout=5000")
        connection.execute("PRAGMA secure_delete=ON")
        try:
            yield connection
        finally:
            connection.close()

    def get(self) -> dict | None:
        with self.connection() as connection:
            row = connection.execute("SELECT payload, received_at FROM snapshot WHERE id=1").fetchone()
        if row is None:
            return None
        return {"snapshot": json.loads(row[0]), "receivedAt": row[1]}

    def put(self, snapshot: Snapshot) -> str:
        payload = snapshot.model_dump_json()
        generated_at = snapshot.generatedAt.timestamp()
        received_at = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
        with self.connection() as connection:
            connection.execute("BEGIN IMMEDIATE")
            try:
                current = connection.execute("SELECT generated_at, payload, received_at FROM snapshot WHERE id=1").fetchone()
                if current:
                    if generated_at < current[0] or (generated_at == current[0] and payload != current[1]):
                        raise StaleSnapshot()
                    if generated_at == current[0]:
                        connection.execute("COMMIT")
                        return current[2]
                connection.execute(
                    "INSERT INTO snapshot VALUES (1, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET generated_at=excluded.generated_at, received_at=excluded.received_at, payload=excluded.payload",
                    (generated_at, received_at, payload),
                )
                connection.execute("COMMIT")
            except BaseException:
                connection.execute("ROLLBACK")
                raise
        return received_at

    def delete(self) -> None:
        with self.connection() as connection:
            connection.execute("BEGIN IMMEDIATE")
            try:
                connection.execute("DELETE FROM snapshot WHERE id=1")
                connection.execute("COMMIT")
            except BaseException:
                connection.execute("ROLLBACK")
                raise
