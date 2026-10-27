"""Public timekeeping website. Pages render on the server and call the API from the
server with a shared key. People sign in with their employee ID and date of birth.
Signature pads post a PNG data URL in a form field named "signature"."""

from __future__ import annotations

import csv
import io
import logging
import os
import secrets
import time
from datetime import date, datetime, timedelta
from pathlib import Path
from urllib.parse import quote, urlencode
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
from starlette.middleware.sessions import SessionMiddleware

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("timekeeping.web")

BASE_DIR = Path(__file__).resolve().parent
API_BASE_URL = os.environ.get("API_BASE_URL", "http://localhost:8001").rstrip("/")
API_SHARED_KEY = os.environ.get("API_SHARED_KEY", "")
SESSION_SECRET = os.environ.get("SESSION_SECRET", "")
if not SESSION_SECRET:
    log.warning("SESSION_SECRET is not set. Using a random one, so sessions end when the app restarts.")
    SESSION_SECRET = secrets.token_hex(32)

API_TIMEOUT_SECONDS = 15
# Deleting many signature files can take longer than a normal page.
RESET_TIMEOUT_SECONDS = 120
# A stopped database makes the API wait for its connection timeout before it reports.
STATUS_TIMEOUT_SECONDS = 45
# The daily record downloads every signature to check its hash.
AUDIT_TIMEOUT_SECONDS = 60
# A shared tablet signs a guard out quickly. Supervisors review at a desk.
IDLE_SECONDS = {"guard": 120, "supervisor": 900}
# States in which Azure is still changing the server, so the Status page keeps refreshing.
BUSY_SERVER_STATES = {"Starting", "Stopping", "Updating", "Restarting", "Provisioning"}
BREAK_LABELS = {"lunch": "Lunch break", "restroom": "Restroom break"}

NOTICES = {
    "shift-started": "Shift started.",
    "post-taken": "Post taken.",
    "relieved": "Post handed over to the relief guard.",
    "shift-ended": "Shift ended.",
    "break-started": "Break started. The cover guard has the post until you return.",
    "break-ended": "Welcome back. You have the post again.",
    "correction-requested": "Correction sent to a supervisor for approval.",
    "decided-approved": "Correction approved. The original entry is kept in the daily record.",
    "decided-rejected": "Correction rejected.",
    "reset": "Demo data reset. Every guard and post is back to where a new deployment starts.",
    "starting": "Starting the database server. It takes about 2 minutes. This page refreshes by itself.",
    "signed-out": "You are signed out.",
    "expired": "You were signed out after a period without activity. Sign in again.",
}

app = FastAPI(title="Timekeeping", docs_url=None, redoc_url=None, openapi_url=None)
app.mount("/static", StaticFiles(directory=BASE_DIR / "static"), name="static")
templates = Jinja2Templates(directory=BASE_DIR / "templates")
session = requests.Session()


class SignInRequired(Exception):
    pass


class Forbidden(Exception):
    def __init__(self, message: str):
        super().__init__(message)
        self.message = message


class ApiError(Exception):
    def __init__(self, status: int, detail: str):
        super().__init__(detail)
        self.status = status
        self.detail = detail


# --- Sessions -------------------------------------------------------------------------

@app.middleware("http")
async def idle_timeout(request: Request, call_next):
    """Signs a person out after a period without activity. Automatic page refreshes,
    marked with auto=1, do not count as activity."""
    user = request.session.get("user")
    if user:
        now = time.time()
        if now - user.get("last_seen", 0) > IDLE_SECONDS.get(user.get("kind"), 120):
            request.session.clear()
            path = request.url.path
            if not path.startswith("/static") and path not in ("/healthz", "/status", "/signin"):
                return RedirectResponse("/signin?notice=expired", status_code=303)
        elif request.query_params.get("auto") != "1":
            user["last_seen"] = now
            request.session["user"] = user
    return await call_next(request)


# Added last, so it runs first and the session is ready for idle_timeout.
app.add_middleware(
    SessionMiddleware,
    secret_key=SESSION_SECRET,
    session_cookie="tk_session",
    max_age=12 * 3600,
    same_site="lax",
    https_only=bool(os.environ.get("WEBSITE_HOSTNAME")),
)


@app.exception_handler(SignInRequired)
async def sign_in_required(request: Request, _exc: SignInRequired):
    return RedirectResponse(f"/signin?next={quote(request.url.path)}", status_code=303)


@app.exception_handler(Forbidden)
async def forbidden(request: Request, exc: Forbidden):
    return render(request, "error.html", {"title": "Not allowed", "message": exc.message}, 403)


def current_user(request: Request) -> dict | None:
    return request.session.get("user")


def require_user(request: Request) -> dict:
    user = current_user(request)
    if not user:
        raise SignInRequired()
    return user


def require_guard(request: Request, guard_id: int) -> dict:
    user = require_user(request)
    if user["kind"] != "guard" or user["id"] != guard_id:
        raise Forbidden("You can only act for yourself. Sign out, then sign in as that guard.")
    return user


def require_supervisor(request: Request, site_id: int | None = None) -> dict:
    user = require_user(request)
    if user["kind"] != "supervisor":
        raise Forbidden("This page is for supervisors.")
    if site_id is not None and user["site_id"] not in (None, site_id):
        raise Forbidden("This site belongs to another supervisor.")
    return user


def home_for(user: dict) -> str:
    if user["kind"] == "guard":
        return f"/guard/{user['id']}"
    if user["site_id"]:
        return f"/supervisor/{user['site_id']}"
    return "/"


# --- API and rendering ------------------------------------------------------------------

def local_time(value: str | None, time_zone: str, fmt: str = "%b %d, %H:%M") -> str:
    """Show a UTC timestamp from the API in the site's time zone."""
    if not value:
        return ""
    moment = datetime.fromisoformat(value)
    return moment.astimezone(ZoneInfo(time_zone)).strftime(f"{fmt} %Z")


def local_hhmm(value: str | None, time_zone: str) -> str:
    if not value:
        return ""
    return datetime.fromisoformat(value).astimezone(ZoneInfo(time_zone)).strftime("%H:%M")


templates.env.filters["local_time"] = local_time
templates.env.filters["local_hhmm"] = local_hhmm


def call_api(request: Request, method: str, path: str, payload: dict | None = None, params: dict | None = None,
             timeout: int = API_TIMEOUT_SECONDS):
    headers = {"X-Timekeeping-Key": API_SHARED_KEY}
    user = current_user(request)
    if user:
        headers.update({
            "X-Actor-Kind": user["kind"],
            "X-Actor-Id": str(user["id"]),
            "X-Actor-Badge": user["badge"],
            "X-Actor-Site": str(user["site_id"] or ""),
        })
    try:
        response = session.request(method, f"{API_BASE_URL}{path}", json=payload, params=params,
                                   headers=headers, timeout=timeout)
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
    context = {"user": current_user(request), **context}
    if context.get("refresh_seconds"):
        query = dict(request.query_params)
        query["auto"] = "1"
        context["refresh_url"] = f"{request.url.path}?{urlencode(query)}"
    return templates.TemplateResponse(request, template, context, status_code=status_code)


def error_page(request: Request, error: ApiError) -> HTMLResponse:
    if error.status == 403:
        raise Forbidden(error.detail)
    status = 404 if error.status == 404 else 502
    return render(request, "error.html", {"title": "Something went wrong", "message": error.detail}, status)


# --- Sign-in --------------------------------------------------------------------------------

@app.get("/healthz")
def healthz():
    return {"status": "ok"}


@app.get("/signin", response_class=HTMLResponse)
def signin_page(request: Request, next: str = "", notice: str | None = None):
    user = current_user(request)
    if user:
        return RedirectResponse(home_for(user), status_code=303)
    return render(request, "signin.html", {"title": "Sign in", "next": next, "notice": NOTICES.get(notice or "")})


@app.post("/signin")
def signin(request: Request, badge: str = Form(""), dob: str = Form(""), next: str = Form("")):
    try:
        person = call_api(request, "POST", "/auth/login", {"badge": badge, "dob": dob})
    except ApiError as exc:
        status = exc.status if exc.status in (400, 401, 423, 503) else 502
        return render(request, "signin.html", {"title": "Sign in", "next": next, "badge": badge,
                                               "error": exc.detail}, status)
    request.session.clear()
    request.session["user"] = {**person, "last_seen": time.time()}
    target = next if next.startswith("/") and not next.startswith("//") and next != "/signin" else home_for(person)
    return RedirectResponse(target, status_code=303)


@app.post("/signout")
def signout(request: Request):
    request.session.clear()
    return RedirectResponse("/signin?notice=signed-out", status_code=303)


# --- Supervisor home ------------------------------------------------------------------------

@app.get("/", response_class=HTMLResponse)
def index(request: Request, notice: str | None = None):
    user = current_user(request)
    if not user:
        return RedirectResponse("/signin", status_code=303)
    if user["kind"] == "guard":
        return RedirectResponse(home_for(user), status_code=303)
    try:
        sites = call_api(request, "GET", "/sites")
        boards = [call_api(request, "GET", f"/sites/{site['id']}/board") for site in sites]
    except ApiError as exc:
        return error_page(request, exc)
    return render(request, "index.html", {"title": "Sites and guards", "boards": boards,
                                          "notice": NOTICES.get(notice or "")})


# --- Guard pages ----------------------------------------------------------------------------

def guard_page(request: Request, guard_id: int, error: str | None = None, status_code: int = 200,
               notice: str | None = None) -> HTMLResponse:
    user = require_user(request)
    try:
        detail = call_api(request, "GET", f"/guards/{guard_id}")
        board = call_api(request, "GET", f"/sites/{detail['site']['id']}/board")
    except ApiError as exc:
        return error_page(request, exc)
    context = {
        "title": detail["guard"]["name"],
        "detail": detail,
        "board": board,
        "tz": detail["site"]["time_zone"],
        "read_only": user["kind"] != "guard",
        "available": [g for g in board["guards"] if g["state"] == "available" and g["id"] != guard_id],
        "break_labels": BREAK_LABELS,
        "error": error,
        "notice": NOTICES.get(notice or ""),
    }
    return render(request, "guard.html", context, status_code)


def run_action(request: Request, guard_id: int, method: str, path: str, payload: dict, notice: str):
    """Call the API, then redirect to the guard page or show the rule that stopped the action."""
    try:
        call_api(request, method, path, payload)
    except ApiError as exc:
        if exc.status in (400, 401, 403, 404, 409, 422, 423):
            return guard_page(request, guard_id, error=exc.detail, status_code=exc.status)
        return error_page(request, exc)
    return RedirectResponse(f"/guard/{guard_id}?notice={notice}", status_code=303)


@app.get("/guard/{guard_id}", response_class=HTMLResponse)
def guard(request: Request, guard_id: int, notice: str | None = None):
    return guard_page(request, guard_id, notice=notice)


@app.post("/guard/{guard_id}/start-shift")
def start_shift(request: Request, guard_id: int, witness_guard_id: int | None = Form(None),
                equipment_on: str | None = Form(None), signature: str | None = Form(None)):
    require_guard(request, guard_id)
    if witness_guard_id is None:
        return guard_page(request, guard_id, error="Pick a witness.", status_code=400)
    payload = {"guard_id": guard_id, "witness_guard_id": witness_guard_id, "equipment_on": equipment_on == "on",
               "signature": signature}
    return run_action(request, guard_id, "POST", "/shifts", payload, "shift-started")


@app.post("/guard/{guard_id}/take-post")
def take_post(request: Request, guard_id: int, post_id: int | None = Form(None)):
    require_guard(request, guard_id)
    if post_id is None:
        return guard_page(request, guard_id, error="Pick a post.", status_code=400)
    return run_action(request, guard_id, "POST", "/assignments", {"guard_id": guard_id, "post_id": post_id},
                      "post-taken")


@app.post("/assignment/{assignment_id}/relieve")
def relieve(request: Request, assignment_id: int, guard_id: int = Form(...),
            relief_guard_id: int | None = Form(None), relief_dob: str = Form(""), signature: str | None = Form(None)):
    require_guard(request, guard_id)
    if relief_guard_id is None:
        return guard_page(request, guard_id, error="Pick a relief guard.", status_code=400)
    return run_action(request, guard_id, "POST", f"/assignments/{assignment_id}/relieve",
                      {"relief_guard_id": relief_guard_id, "relief_dob": relief_dob, "signature": signature},
                      "relieved")


@app.post("/guard/{guard_id}/break")
def start_break(request: Request, guard_id: int, break_type: str = Form(""), cover_guard_id: int | None = Form(None),
                cover_dob: str = Form(""), signature: str | None = Form(None)):
    require_guard(request, guard_id)
    if cover_guard_id is None:
        return guard_page(request, guard_id, error="Pick a cover guard.", status_code=400)
    payload = {"guard_id": guard_id, "break_type": break_type, "cover_guard_id": cover_guard_id,
               "cover_dob": cover_dob, "signature": signature}
    return run_action(request, guard_id, "POST", "/breaks", payload, "break-started")


@app.post("/guard/{guard_id}/return")
def return_from_break(request: Request, guard_id: int, break_id: int = Form(...),
                      signature: str | None = Form(None)):
    require_guard(request, guard_id)
    return run_action(request, guard_id, "POST", f"/breaks/{break_id}/return", {"signature": signature},
                      "break-ended")


@app.post("/guard/{guard_id}/end-shift")
def end_shift(request: Request, guard_id: int, equipment_off: str | None = Form(None),
              signature: str | None = Form(None)):
    require_guard(request, guard_id)
    try:
        detail = call_api(request, "GET", f"/guards/{guard_id}")
    except ApiError as exc:
        return error_page(request, exc)
    shift = detail.get("open_shift")
    if not shift:
        return guard_page(request, guard_id, error="This guard is not on shift.", status_code=409)
    return run_action(request, guard_id, "POST", f"/shifts/{shift['id']}/end",
                      {"equipment_off": equipment_off == "on", "signature": signature}, "shift-ended")


def correction_page(request: Request, guard_id: int, event_id: int, error: str | None = None,
                    status_code: int = 200, proposed_time: str = "", reason: str = "") -> HTMLResponse:
    require_guard(request, guard_id)
    try:
        detail = call_api(request, "GET", f"/guards/{guard_id}")
    except ApiError as exc:
        return error_page(request, exc)
    event = next((e for e in detail["events"] if e["id"] == event_id), None)
    if event is None:
        return render(request, "error.html", {"title": "Entry not found",
                                              "message": "Only your 10 most recent entries can be corrected here."}, 404)
    tz = detail["site"]["time_zone"]
    context = {"title": "Request a correction", "detail": detail, "event": event, "tz": tz, "error": error,
               "proposed_time": proposed_time or local_hhmm(event["occurred_at"], tz), "reason": reason}
    return render(request, "correct.html", context, status_code)


@app.get("/guard/{guard_id}/correct/{event_id}", response_class=HTMLResponse)
def correction_form(request: Request, guard_id: int, event_id: int):
    return correction_page(request, guard_id, event_id)


@app.post("/guard/{guard_id}/correct/{event_id}")
def request_correction(request: Request, guard_id: int, event_id: int, proposed_time: str = Form(""),
                       reason: str = Form("")):
    require_guard(request, guard_id)
    try:
        call_api(request, "POST", f"/events/{event_id}/adjustments", {"proposed_time": proposed_time, "reason": reason})
    except ApiError as exc:
        if exc.status in (400, 403, 404, 409, 422):
            return correction_page(request, guard_id, event_id, error=exc.detail, status_code=exc.status,
                                   proposed_time=proposed_time, reason=reason)
        return error_page(request, exc)
    return RedirectResponse(f"/guard/{guard_id}?notice=correction-requested", status_code=303)


@app.get("/signature/{event_id}")
def signature(request: Request, event_id: int):
    """Proxy the PNG from the API, which reads it from Blob Storage."""
    user = current_user(request)
    if not user:
        return Response(status_code=401)
    headers = {"X-Timekeeping-Key": API_SHARED_KEY, "X-Actor-Kind": user["kind"], "X-Actor-Id": str(user["id"]),
               "X-Actor-Badge": user["badge"], "X-Actor-Site": str(user["site_id"] or "")}
    try:
        response = session.get(f"{API_BASE_URL}/events/{event_id}/signature", headers=headers,
                               timeout=API_TIMEOUT_SECONDS)
    except requests.RequestException as exc:
        log.warning("Signature %s could not be fetched: %s", event_id, type(exc).__name__)
        return Response(status_code=502)
    if response.status_code != 200:
        return Response(status_code=404 if response.status_code == 404 else 502)
    return Response(content=response.content, media_type="image/png",
                    headers={"Cache-Control": "private, max-age=3600"})


# --- Supervise ------------------------------------------------------------------------------

def supervisor_page(request: Request, site_id: int, error: str | None = None, status_code: int = 200,
                    notice: str | None = None) -> HTMLResponse:
    require_supervisor(request, site_id)
    try:
        board = call_api(request, "GET", f"/sites/{site_id}/board")
        attention = call_api(request, "GET", f"/sites/{site_id}/attention")
    except ApiError as exc:
        return error_page(request, exc)
    context = {"title": f"Supervisor board: {board['site']['name']}", "board": board, "attention": attention,
               "tz": board["site"]["time_zone"], "refresh_seconds": None if error else 10,
               "break_labels": BREAK_LABELS, "error": error, "notice": NOTICES.get(notice or "")}
    return render(request, "supervisor.html", context, status_code)


@app.get("/supervisor/{site_id}", response_class=HTMLResponse)
def supervisor(request: Request, site_id: int, notice: str | None = None):
    return supervisor_page(request, site_id, notice=notice)


@app.post("/adjustments/{adjustment_id}/decision")
def decide(request: Request, adjustment_id: int, site_id: int = Form(...), decision: str = Form(""),
           note: str = Form("")):
    require_supervisor(request, site_id)
    try:
        call_api(request, "POST", f"/adjustments/{adjustment_id}/decision",
                 {"approve": decision == "approve", "note": note})
    except ApiError as exc:
        if exc.status in (400, 403, 404, 409, 422):
            return supervisor_page(request, site_id, error=exc.detail, status_code=exc.status)
        return error_page(request, exc)
    outcome = "decided-approved" if decision == "approve" else "decided-rejected"
    return RedirectResponse(f"/supervisor/{site_id}?notice={outcome}", status_code=303)


# --- Audit -----------------------------------------------------------------------------------

def daily_record(request: Request, site_id: int, day: str | None) -> dict:
    return call_api(request, "GET", f"/sites/{site_id}/daily", params={"day": day} if day else None,
                    timeout=AUDIT_TIMEOUT_SECONDS)


@app.get("/audit/{site_id}", response_class=HTMLResponse)
def audit(request: Request, site_id: int, day: str | None = None):
    require_supervisor(request, site_id)
    try:
        record = daily_record(request, site_id, day)
    except ApiError as exc:
        if exc.status == 400:
            return render(request, "error.html", {"title": "Daily record", "message": exc.detail}, 400)
        return error_page(request, exc)
    shown = date.fromisoformat(record["day"])
    context = {"title": f"Daily record: {record['site']['name']}", "record": record, "tz": record["site"]["time_zone"],
               "previous_day": (shown - timedelta(days=1)).isoformat(),
               "next_day": (shown + timedelta(days=1)).isoformat()}
    return render(request, "audit.html", context)


@app.get("/audit/{site_id}/export.csv")
def audit_export(request: Request, site_id: int, day: str | None = None):
    require_supervisor(request, site_id)
    try:
        record = daily_record(request, site_id, day)
    except ApiError as exc:
        return error_page(request, exc)
    tz = record["site"]["time_zone"]
    out = io.StringIO()
    writer = csv.writer(out)
    writer.writerow([
        "site", "day", "event_id", "recorded_at", "effective_at", "adjusted", "event_type", "detail", "guard", "post",
        "signed_by", "signature_meaning", "signature_check", "recorded_by", "correction_status", "correction_reason",
        "correction_decided_by", "correction_note",
    ])
    for event in record["events"]:
        latest = event["adjustments"][-1] if event["adjustments"] else {}
        writer.writerow([
            record["site"]["name"], record["day"], event["id"], local_time(event["occurred_at"], tz, "%Y-%m-%d %H:%M:%S"),
            local_time(event["adjusted_at"] or event["occurred_at"], tz, "%Y-%m-%d %H:%M:%S"),
            "yes" if event["adjusted_at"] else "no", event["event_type"], event["detail"], event["guard_name"] or "",
            event["post_name"] or "", event["signed_by_name"] or "", event["signature_meaning"] or "",
            event["signature_check"], event["recorded_by"] or "", latest.get("status", ""), latest.get("reason", ""),
            latest.get("decided_by") or "", latest.get("decision_note") or "",
        ])
    filename = f"timekeeping-site{site_id}-{record['day']}.csv"
    return Response(content=out.getvalue(), media_type="text/csv",
                    headers={"Content-Disposition": f'attachment; filename="{filename}"'})


# --- Admin and status -----------------------------------------------------------------------

@app.get("/reset", response_class=HTMLResponse)
def reset_page(request: Request):
    require_supervisor(request)
    return render(request, "reset.html", {"title": "Reset demo data"})


@app.post("/reset")
def reset(request: Request):
    require_supervisor(request)
    try:
        result = call_api(request, "POST", "/admin/reset", timeout=RESET_TIMEOUT_SECONDS)
    except ApiError as exc:
        return render(request, "reset.html", {"title": "Reset demo data", "error": exc.detail}, 502)
    # The reset deleted every account, including this one, so sign out.
    request.session.clear()
    if result.get("storage_warning"):
        return render(request, "reset.html", {"title": "Reset demo data", "warning": result["storage_warning"]})
    return RedirectResponse("/signin?notice=reset", status_code=303)


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
    """No sign-in needed: with the database stopped, nobody can sign in."""
    try:
        call_api(request, "POST", "/admin/start-database", timeout=STATUS_TIMEOUT_SECONDS)
    except ApiError as exc:
        return render(request, "status.html", {"title": "Status", "api": "ok", "database": "error",
                                               "storage": "", "counts": {}, "api_host": API_BASE_URL,
                                               "database_server": "", "notice": None,
                                               "messages": [exc.detail]}, 502)
    return RedirectResponse("/status?notice=starting", status_code=303)
