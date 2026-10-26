"""PostgreSQL connections with Microsoft Entra tokens, and first-run setup."""

from __future__ import annotations

import logging
import os
import threading
from pathlib import Path

import psycopg
from azure.identity import DefaultAzureCredential
from psycopg.rows import dict_row

import seed

log = logging.getLogger("timekeeping.db")

TOKEN_SCOPE = "https://ossrdbms-aad.database.windows.net/.default"
SCHEMA_FILE = Path(__file__).with_name("schema.sql")
# Any constant works, as long as every worker uses the same one.
SETUP_LOCK_KEY = 72041180

_credential: DefaultAzureCredential | None = None
_credential_lock = threading.Lock()
_setup_lock = threading.Lock()
_setup_done = False


def get_credential() -> DefaultAzureCredential:
    """One credential per process. On App Service it uses the managed identity."""
    global _credential
    with _credential_lock:
        if _credential is None:
            _credential = DefaultAzureCredential()
        return _credential


def connect() -> psycopg.Connection:
    """Open a new connection. Each connection gets a fresh token because tokens expire."""
    token = get_credential().get_token(TOKEN_SCOPE).token
    return psycopg.connect(
        host=os.environ["PGHOST"],
        port=int(os.environ.get("PGPORT", "5432")),
        dbname=os.environ.get("PGDATABASE", "timekeeping"),
        user=os.environ["PGUSER"],
        password=token,
        sslmode="require",
        connect_timeout=10,
        application_name="timekeeping-api",
        row_factory=dict_row,
    )


def ensure_setup() -> None:
    """Create the tables and load seed data once.

    Gunicorn starts several workers and each one runs this. The advisory lock lets
    one worker at a time in, and seeding happens only when the guards table is empty.
    """
    global _setup_done
    if _setup_done:
        return
    with _setup_lock:
        if _setup_done:
            return
        with connect() as conn:
            conn.execute("SELECT pg_advisory_lock(%s)", (SETUP_LOCK_KEY,))
            try:
                conn.execute(SCHEMA_FILE.read_text(encoding="utf-8"))
                guard_count = conn.execute("SELECT count(*) AS n FROM guards").fetchone()["n"]
                if guard_count == 0:
                    seed.load(conn)
                    log.info("Loaded synthetic seed data.")
                conn.commit()
            except Exception:
                conn.rollback()
                raise
            finally:
                conn.execute("SELECT pg_advisory_unlock(%s)", (SETUP_LOCK_KEY,))
                conn.commit()
        _setup_done = True
        log.info("Database setup complete.")
