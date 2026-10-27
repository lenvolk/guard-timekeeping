"""Reads and starts the PostgreSQL server through Azure Resource Manager.

Some subscriptions run automation that stops idle servers overnight. The Status page
uses this module to show that the server is stopped and to start it again. The API's
managed identity has Contributor on this one server, which S2 grants.
"""

from __future__ import annotations

import json
import logging
import os
import urllib.error
import urllib.request

import db

log = logging.getLogger("timekeeping.server")

ARM_SCOPE = "https://management.azure.com/.default"
ARM_URL = "https://management.azure.com"
API_VERSION = "2024-08-01"
TIMEOUT_SECONDS = 30


class ServerControlUnavailable(RuntimeError):
    """The server state could not be read or changed."""


def _server_id() -> str:
    server_id = os.environ.get("POSTGRES_SERVER_ID", "")
    if not server_id:
        raise ServerControlUnavailable("The POSTGRES_SERVER_ID app setting is missing. Run deploy.ps1 from S2.")
    return server_id


def _request(method: str, path: str) -> tuple[int, dict]:
    token = db.get_credential().get_token(ARM_SCOPE).token
    request = urllib.request.Request(
        f"{ARM_URL}{path}?api-version={API_VERSION}",
        method=method,
        data=b"" if method == "POST" else None,
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT_SECONDS) as response:
            body = response.read()
            return response.status, json.loads(body) if body else {}
    except urllib.error.HTTPError as exc:
        log.warning("%s %s returned HTTP %s.", method, path, exc.code)
        if exc.code == 403:
            raise ServerControlUnavailable(
                "The API is not allowed to manage the database server. Run deploy.ps1 from S2."
            ) from exc
        raise ServerControlUnavailable(f"Azure returned HTTP {exc.code}.") from exc
    except (urllib.error.URLError, TimeoutError) as exc:
        raise ServerControlUnavailable(f"Azure Resource Manager did not answer ({type(exc).__name__}).") from exc


def get_state() -> str:
    """Ready, Stopped, Starting, Stopping, Updating and so on, as Azure reports it."""
    _, server = _request("GET", _server_id())
    return server.get("properties", {}).get("state", "Unknown")


def start() -> str:
    """Asks Azure to start the server if it is stopped. Returns the state to show next."""
    state = get_state()
    if state != "Stopped":
        return state
    _request("POST", f"{_server_id()}/start")
    log.info("Requested start of the PostgreSQL server.")
    return "Starting"
