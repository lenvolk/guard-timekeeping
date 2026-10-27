"""Public timekeeping website. Pages render on the server and call the API from
the server. Signature pads post a PNG data URL in a form field named "signature"."""

from __future__ import annotations

import logging
import os
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

if os.environ.get("APPLICATIONINSIGHTS_CONNECTION_STRING"):
    # Configure telemetry before FastAPI and requests are imported so both are instrumented.
    from azure.monitor.opentelemetry import configure_azure_monitor

    configure_azure_monitor(logger_name="timekeeping")

import requests
from fastapi import FastAPI, Form, Request
from fastapi.responses import HTMLResponse, RedirectResponse, Response
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("timekeeping.web")

BASE_DIR = Path(__file__).resolve().parent
API_BASE_URL = os.environ.get("API_BASE_URL", "http://localhost:8001").rstrip("/")
API_TIMEOUT_SECONDS = 15

NOTICES = {
    "shift-started": "Shift started.",
    "post-taken": "Post taken.",
    "relieved": "Post handed over to the relief guard.",
    "shift-ended": "Shift ended.",
    "reset": "Demo data reset. Every guard and post is back to where a new deployment starts.",
    "starting": "Starting the database server. It takes about 2 minutes. This page refreshes by itself.",
}
# Deleting many signature files can take longer than a normal page.
RESET_TIMEOUT_SECONDS = 120
# A stopped database makes the API wait for its connection timeout before it reports.
STATUS_TIMEOUT_SECONDS = 45
# States in which Azure is still changing the server, so the Status page keeps refreshing.
BUSY_SERVER_STATES = {"Starting", "Stopping", "Updating", "Restarting", "Provisioning"}

app = FastAPI(title="Timekeeping", docs_url=None, redoc_url=None, openapi_url=None)
app.mount("/static", StaticFiles(directory=BASE_DIR / "static"), name="static")
templates = Jinja2Templates(directory=BASE_DIR / "templates")
session = requests.Session()


def local_time(value: str | None, time_zone: str, fmt: str = "%b %d, %H:%M") -> str:
    """Show a UTC timestamp from the API in the site's time zone."""
    if not value:
        return ""
    moment = datetime.fromisoformat(value)
    return moment.astimezone(ZoneInfo(time_zone)).strftime(f"{fmt} %Z")


templates.env.filters["local_time"] = local_time


class ApiError(Exception):
    def __init__(self, status: int, detail: str):
        super().__init__(detail)
        self.status = status
        self.detail = detail


def call_api(method: str, path: str, payload: dict | None = None, params: dict | None = None,
             timeout: int = API_TIMEOUT_SECONDS):
    try:
        response = session.request(
            method, f"{API_BASE_URL}{path}", json=payload, params=params, timeout=timeout
        )
    except requests.RequestException as exc:
        log.warning("API call %s %s failed: %s", method, path, type(exc).__name__)
        raise ApiError(502, f"The web app could not reach the API ({type(exc).__name__}).") from exc
    if response.status_code >= 400:
        detail = f"The API returned HTTP {response.status_code}."
        try:
            body = response.json()
            if isinstance(body, dict) and isinstance(body.get("detail"), str):
                detail = body["detail"]
        except ValueError:
            pass
        raise ApiError(response.status_code, detail)
    return response.json()


def render(request: Request, template: str, context: dict, status_code: int = 200) -> HTMLResponse:
    return templates.TemplateResponse(request, template, context, status_code=status_code)


def error_page(request: Request, error: ApiError) -> HTMLResponse:
    status = 404 if error.status == 404 else 502
    return render(request, "error.html", {"title": "Something went wrong", "message": error.detail}, status)


def guard_page(request: Request, guard_id: int, error: str | None = None, status_code: int = 200,
               notice: str | None = None) -> HTMLResponse:
    try:
        detail = call_api("GET", f"/guards/{guard_id}")
        board = call_api("GET", f"/sites/{detail['site']['id']}/board")
    except ApiError as exc:
        return error_page(request, exc)
    context = {
        "title": detail["guard"]["name"],
        "detail": detail,
        "board": board,
        "tz": detail["site"]["time_zone"],
        "error": error,
        "notice": NOTICES.get(notice or ""),
    }
    return render(request, "guard.html", context, status_code)


def run_action(request: Request, guard_id: int, method: str, path: str, payload: dict, notice: str):
    """Call the API, then redirect to the guard page or show the rule that stopped the action."""
    try:
        call_api(method, path, payload)
    except ApiError as exc:
        if exc.status in (400, 404, 409, 422):
            return guard_page(request, guard_id, error=exc.detail, status_code=exc.status)
        return error_page(request, exc)
    return RedirectResponse(f"/guard/{guard_id}?notice={notice}", status_code=303)


@app.get("/healthz")
def healthz():
    return {"status": "ok"}


@app.get("/", response_class=HTMLResponse)
def index(request: Request, notice: str | None = None):
    try:
        sites = call_api("GET", "/sites")
        boards = [call_api("GET", f"/sites/{site['id']}/board") for site in sites]
    except ApiError as exc:
        return error_page(request, exc)
    return render(request, "index.html", {"title": "Pick a site and guard", "boards": boards,
                                          "notice": NOTICES.get(notice or "")})


@app.get("/guard/{guard_id}", response_class=HTMLResponse)
def guard(request: Request, guard_id: int, notice: str | None = None):
    return guard_page(request, guard_id, notice=notice)


@app.post("/guard/{guard_id}/start-shift")
def start_shift(request: Request, guard_id: int, witness_guard_id: int | None = Form(None),
                equipment_on: str | None = Form(None), signature: str | None = Form(None)):
    if witness_guard_id is None:
        return guard_page(request, guard_id, error="Pick a witness.", status_code=400)
    payload = {"guard_id": guard_id, "witness_guard_id": witness_guard_id, "equipment_on": equipment_on == "on",
               "signature": signature}
    return run_action(request, guard_id, "POST", "/shifts", payload, "shift-started")


@app.post("/guard/{guard_id}/take-post")
def take_post(request: Request, guard_id: int, post_id: int | None = Form(None)):
    if post_id is None:
        return guard_page(request, guard_id, error="Pick a post.", status_code=400)
    return run_action(request, guard_id, "POST", "/assignments", {"guard_id": guard_id, "post_id": post_id},
                      "post-taken")


@app.post("/assignment/{assignment_id}/relieve")
def relieve(request: Request, assignment_id: int, guard_id: int = Form(...),
            relief_guard_id: int | None = Form(None), signature: str | None = Form(None)):
    if relief_guard_id is None:
        return guard_page(request, guard_id, error="Pick a relief guard.", status_code=400)
    return run_action(request, guard_id, "POST", f"/assignments/{assignment_id}/relieve",
                      {"relief_guard_id": relief_guard_id, "signature": signature}, "relieved")


@app.post("/guard/{guard_id}/end-shift")
def end_shift(request: Request, guard_id: int, equipment_off: str | None = Form(None),
              signature: str | None = Form(None)):
    try:
        detail = call_api("GET", f"/guards/{guard_id}")
    except ApiError as exc:
        return error_page(request, exc)
    shift = detail.get("open_shift")
    if not shift:
        return guard_page(request, guard_id, error="This guard is not on shift.", status_code=409)
    return run_action(request, guard_id, "POST", f"/shifts/{shift['id']}/end",
                      {"equipment_off": equipment_off == "on", "signature": signature}, "shift-ended")


@app.get("/signature/{event_id}")
def signature(event_id: int):
    """Proxy the PNG from the API, which reads it from Blob Storage."""
    try:
        response = session.get(f"{API_BASE_URL}/events/{event_id}/signature", timeout=API_TIMEOUT_SECONDS)
    except requests.RequestException as exc:
        log.warning("Signature %s could not be fetched: %s", event_id, type(exc).__name__)
        return Response(status_code=502)
    if response.status_code != 200:
        return Response(status_code=404 if response.status_code == 404 else 502)
    return Response(content=response.content, media_type="image/png",
                    headers={"Cache-Control": "private, max-age=3600"})


@app.get("/supervisor/{site_id}", response_class=HTMLResponse)
def supervisor(request: Request, site_id: int):
    try:
        board = call_api("GET", f"/sites/{site_id}/board")
    except ApiError as exc:
        return error_page(request, exc)
    context = {"title": f"Supervisor board: {board['site']['name']}", "board": board,
               "tz": board["site"]["time_zone"], "refresh_seconds": 10}
    return render(request, "supervisor.html", context)


@app.get("/reset", response_class=HTMLResponse)
def reset_page(request: Request):
    return render(request, "reset.html", {"title": "Reset demo data"})


@app.post("/reset")
def reset(request: Request):
    try:
        result = call_api("POST", "/admin/reset", timeout=RESET_TIMEOUT_SECONDS)
    except ApiError as exc:
        return render(request, "reset.html", {"title": "Reset demo data", "error": exc.detail}, 502)
    if result.get("storage_warning"):
        return render(request, "reset.html", {"title": "Reset demo data", "warning": result["storage_warning"]})
    return RedirectResponse("/?notice=reset", status_code=303)


@app.get("/status", response_class=HTMLResponse)
def status(request: Request, notice: str | None = None):
    result = {"api": "error", "database": "error", "storage": "error", "counts": {}, "messages": [],
              "api_host": API_BASE_URL, "database_server": "", "notice": NOTICES.get(notice or "")}
    try:
        response = session.get(f"{API_BASE_URL}/status", timeout=STATUS_TIMEOUT_SECONDS)
        if response.status_code in (200, 503):
            result["api"] = "ok"
            body = response.json()
            errors = body.get("errors") or {}
            result["database"] = "ok" if body.get("database") == "ok" else "error"
            result["storage"] = "ok" if body.get("storage") == "ok" else "error"
            result["counts"] = body.get("counts") or {}
            result["database_server"] = body.get("database_server") or ""
            if result["database"] != "ok":
                server_state = result["database_server"]
                if server_state == "Stopped":
                    result["messages"].append("The database server is stopped. Select Start database to start it.")
                elif server_state in BUSY_SERVER_STATES:
                    result["messages"].append(f"The database server is {server_state.lower()}. This page refreshes by itself.")
                else:
                    result["messages"].append(f"The API cannot reach the database ({errors.get('database', 'unknown error')}).")
                if errors.get("database_server"):
                    result["messages"].append(errors["database_server"])
            if result["storage"] != "ok":
                result["messages"].append(
                    f"The API cannot read signature storage ({errors.get('storage', 'unknown error')}). "
                    "New role assignments can take a few minutes to apply."
                )
        else:
            result["messages"].append(f"The API returned HTTP {response.status_code}.")
    except (requests.RequestException, ValueError) as exc:
        result["messages"].append(f"The web app could not reach the API ({type(exc).__name__}).")
    healthy = result["api"] == "ok" and result["database"] == "ok" and result["storage"] == "ok"
    if healthy and notice == "starting":
        result["notice"] = "The database server is running again."
    context = {"title": "Status", **result}
    # Keep refreshing while the server starts, so the page turns green by itself.
    if not healthy and (result["database_server"] in BUSY_SERVER_STATES or notice == "starting"):
        context["refresh_seconds"] = 20
    return render(request, "status.html", context, 200 if healthy else 503)


@app.post("/status/start-database")
def start_database(request: Request):
    try:
        call_api("POST", "/admin/start-database", timeout=STATUS_TIMEOUT_SECONDS)
    except ApiError as exc:
        return render(request, "status.html", {"title": "Status", "api": "ok", "database": "error",
                                               "storage": "", "counts": {}, "api_host": API_BASE_URL,
                                               "database_server": "", "notice": None,
                                               "messages": [exc.detail]}, 502)
    return RedirectResponse("/status?notice=starting", status_code=303)
