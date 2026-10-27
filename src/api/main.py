"""Timekeeping API. Signs in to PostgreSQL and Blob Storage with its managed
identity. Only the web app calls it: every route except /healthz and /status needs
the shared key, and the web app passes the signed-in person in X-Actor headers."""

from __future__ import annotations

import hashlib
import hmac
import logging
import os
from contextlib import asynccontextmanager, contextmanager
from datetime import date, datetime, timedelta, timezone
from typing import Iterator
from zoneinfo import ZoneInfo

if os.environ.get("APPLICATIONINSIGHTS_CONNECTION_STRING"):
    # Configure telemetry before FastAPI is imported so requests are instrumented.
    from azure.monitor.opentelemetry import configure_azure_monitor

    configure_azure_monitor(logger_name="timekeeping")

import psycopg
from azure.core.exceptions import ClientAuthenticationError
from fastapi import FastAPI, HTTPException, Query, Request
from fastapi.responses import JSONResponse, Response
from pydantic import BaseModel
from starlette.concurrency import run_in_threadpool

import auth
import db
import server
import signatures

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("timekeeping.api")

API_SHARED_KEY = os.environ.get("API_SHARED_KEY", "")
OPEN_PATHS = {"/healthz", "/status"}
BREAK_MINUTES = {"lunch": 60, "restroom": 15}
BREAK_LABELS = {"lunch": "lunch break", "restroom": "restroom break"}
LONG_SHIFT_HOURS = 12


@asynccontextmanager
async def lifespan(_app: FastAPI):
    try:
        await run_in_threadpool(db.ensure_setup)
    except Exception:
        # Keep the app running so /status can report the problem. The next request retries.
        log.exception("Database setup failed at startup.")
    yield


app = FastAPI(title="Timekeeping API", version="3.0.0", lifespan=lifespan,
              docs_url=None, redoc_url=None, openapi_url=None)


@app.middleware("http")
async def require_shared_key(request: Request, call_next):
    if request.url.path not in OPEN_PATHS:
        if not API_SHARED_KEY:
            return JSONResponse(status_code=503, content={"detail": "The API_SHARED_KEY app setting is missing."})
        supplied = request.headers.get("x-timekeeping-key", "")
        if not hmac.compare_digest(supplied.encode(), API_SHARED_KEY.encode()):
            return JSONResponse(status_code=401, content={"detail": "Only the timekeeping web app can call this API."})
    return await call_next(request)


# --- Request bodies -----------------------------------------------------------------

class SignIn(BaseModel):
    badge: str
    dob: str


class ShiftStart(BaseModel):
    guard_id: int
    witness_guard_id: int
    equipment_on: bool
    signature: str | None = None


class ShiftEnd(BaseModel):
    equipment_off: bool
    signature: str | None = None


class AssignmentCreate(BaseModel):
    guard_id: int
    post_id: int


class Relief(BaseModel):
    relief_guard_id: int
    relief_dob: str | None = None
    signature: str | None = None


class BreakStart(BaseModel):
    guard_id: int
    break_type: str
    cover_guard_id: int
    cover_dob: str | None = None
    signature: str | None = None


class BreakReturn(BaseModel):
    signature: str | None = None


class AdjustmentRequest(BaseModel):
    proposed_time: str
    reason: str


class AdjustmentDecision(BaseModel):
    approve: bool
    note: str = ""


# --- Who is calling -------------------------------------------------------------------

def get_actor(request: Request) -> dict | None:
    kind = request.headers.get("x-actor-kind", "")
    actor_id = request.headers.get("x-actor-id", "")
    if kind not in ("guard", "supervisor") or not actor_id.isdigit():
        return None
    site = request.headers.get("x-actor-site", "")
    return {
        "kind": kind,
        "id": int(actor_id),
        "badge": request.headers.get("x-actor-badge", ""),
        "site_id": int(site) if site.isdigit() else None,
    }


def require_actor(request: Request) -> dict:
    actor = get_actor(request)
    if actor is None:
        raise HTTPException(status_code=401, detail="Sign in first.")
    return actor


def require_guard(request: Request, guard_id: int) -> dict:
    actor = require_actor(request)
    if actor["kind"] != "guard" or actor["id"] != guard_id:
        raise HTTPException(status_code=403, detail="Only the signed-in guard can do this for themselves.")
    return actor


def require_supervisor(request: Request, site_id: int | None = None) -> dict:
    actor = require_actor(request)
    if actor["kind"] != "supervisor":
        raise HTTPException(status_code=403, detail="Only a supervisor can do this.")
    if site_id is not None and actor["site_id"] is not None and actor["site_id"] != site_id:
        raise HTTPException(status_code=403, detail="This supervisor works at a different site.")
    return actor


# --- Database helpers ---------------------------------------------------------------------

@contextmanager
def database() -> Iterator[psycopg.Connection]:
    """One transaction per request. Commits on success and rolls back on any error."""
    try:
        db.ensure_setup()
        with db.connect() as conn:
            yield conn
    except psycopg.errors.UniqueViolation:
        raise HTTPException(
            status_code=409,
            detail="Someone else changed this record at the same time. Refresh the page and try again.",
        )
    except signatures.StorageUnavailable:
        raise HTTPException(status_code=503, detail="Signature storage is not available. Try again shortly.")
    except (psycopg.OperationalError, ClientAuthenticationError):
        log.exception("Database call failed.")
        raise HTTPException(
            status_code=503,
            detail="The database is not available. Open the Status page to check it, and start it there if it is stopped.",
        )


def conflict(message: str) -> HTTPException:
    return HTTPException(status_code=409, detail=message)


def auth_error(exc: auth.AuthFailed) -> HTTPException:
    return HTTPException(status_code=exc.status, detail=exc.message)


def read_signature(data_url: str | None) -> bytes:
    try:
        return signatures.decode(data_url)
    except signatures.SignatureInvalid as exc:
        raise HTTPException(status_code=400, detail=str(exc))


def full_name(row: dict) -> str:
    return f"{row['first_name']} {row['last_name']}"


def get_guard(conn: psycopg.Connection, guard_id: int, lock: bool = False) -> dict:
    sql = "SELECT id, site_id, first_name, last_name, badge FROM guards WHERE id = %s"
    if lock:
        sql += " FOR UPDATE"
    row = conn.execute(sql, (guard_id,)).fetchone()
    if row is None:
        raise HTTPException(status_code=404, detail=f"Guard {guard_id} does not exist.")
    return row


def get_site(conn: psycopg.Connection, site_id: int) -> dict:
    row = conn.execute("SELECT id, name, time_zone FROM sites WHERE id = %s", (site_id,)).fetchone()
    if row is None:
        raise HTTPException(status_code=404, detail=f"Site {site_id} does not exist.")
    return row


def open_shift(conn: psycopg.Connection, guard_id: int) -> dict | None:
    return conn.execute(
        "SELECT id, guard_id, witness_guard_id, started_at, equipment_on"
        " FROM shifts WHERE guard_id = %s AND ended_at IS NULL",
        (guard_id,),
    ).fetchone()


def open_assignment(conn: psycopg.Connection, guard_id: int) -> dict | None:
    return conn.execute(
        "SELECT pa.id, pa.post_id, p.name AS post_name, pa.shift_id, pa.started_at"
        " FROM post_assignments pa JOIN posts p ON p.id = pa.post_id"
        " WHERE pa.guard_id = %s AND pa.ended_at IS NULL",
        (guard_id,),
    ).fetchone()


BREAK_COLUMNS = (
    "b.id, b.guard_id, b.cover_guard_id, b.post_id, p.name AS post_name, b.break_type, b.started_at, b.due_at,"
    " b.original_assignment_id, b.cover_assignment_id,"
    " g.first_name || ' ' || g.last_name AS guard_name, c.first_name || ' ' || c.last_name AS cover_name,"
    " GREATEST(0, floor(extract(epoch FROM now() - b.due_at) / 60))::int AS overdue_minutes"
)
BREAK_JOINS = " FROM breaks b JOIN posts p ON p.id = b.post_id JOIN guards g ON g.id = b.guard_id JOIN guards c ON c.id = b.cover_guard_id"


def open_break(conn: psycopg.Connection, guard_id: int) -> dict | None:
    """The guard's own open break."""
    return conn.execute(
        f"SELECT {BREAK_COLUMNS}{BREAK_JOINS} WHERE b.guard_id = %s AND b.ended_at IS NULL", (guard_id,)
    ).fetchone()


def open_cover(conn: psycopg.Connection, guard_id: int) -> dict | None:
    """The open break this guard is covering for someone else."""
    return conn.execute(
        f"SELECT {BREAK_COLUMNS}{BREAK_JOINS} WHERE b.cover_guard_id = %s AND b.ended_at IS NULL", (guard_id,)
    ).fetchone()


def state_of(shift, assignment, own_break, cover) -> str:
    if own_break:
        return "on-break"
    if cover:
        return "covering"
    if assignment:
        return "on-post"
    if shift:
        return "available"
    return "off-shift"


def require_available(conn: psycopg.Connection, guard: dict, role: str) -> dict:
    """The guard must be on shift, off post and not on a break. Returns the open shift."""
    name = full_name(guard)
    shift = open_shift(conn, guard["id"])
    if shift is None:
        raise conflict(f"{name} is not on shift, so cannot be the {role}.")
    if open_break(conn, guard["id"]):
        raise conflict(f"{name} is on a break, so cannot be the {role}.")
    assignment = open_assignment(conn, guard["id"])
    if assignment:
        raise conflict(f"{name} is already on {assignment['post_name']}, so cannot be the {role}.")
    return shift


def add_event(
    conn: psycopg.Connection,
    site_id: int,
    event_type: str,
    detail: str,
    guard_id: int | None = None,
    post_id: int | None = None,
    recorded_by: str | None = None,
) -> dict:
    return conn.execute(
        "INSERT INTO events (site_id, guard_id, post_id, event_type, detail, recorded_by)"
        " VALUES (%s, %s, %s, %s, %s, %s) RETURNING id, occurred_at",
        (site_id, guard_id, post_id, event_type, detail, recorded_by),
    ).fetchone()


def commit_signed_event(
    conn: psycopg.Connection,
    image: bytes,
    signer_id: int,
    site_id: int,
    event_type: str,
    detail: str,
    meaning: str,
    guard_id: int | None = None,
    post_id: int | None = None,
    recorded_by: str | None = None,
) -> int:
    """Write the event with the signature's SHA-256 and meaning, upload the signature,
    then commit.

    The blob goes up first. If the commit then fails, the blob is deleted so no
    signature exists without its event.
    """
    event = add_event(conn, site_id, event_type, detail, guard_id, post_id, recorded_by)
    name = signatures.blob_name(site_id, event["occurred_at"], event["id"])
    conn.execute(
        "UPDATE events SET signed_by_guard_id = %s, signature_blob = %s, signature_sha256 = %s,"
        " signature_meaning = %s WHERE id = %s",
        (signer_id, name, hashlib.sha256(image).hexdigest(), meaning, event["id"]),
    )
    signatures.upload(name, image)
    try:
        conn.commit()
    except Exception:
        signatures.delete_quietly(name)
        raise
    return event["id"]


EVENT_COLUMNS = (
    "e.id, e.site_id, e.guard_id, e.post_id, e.event_type, e.detail, e.occurred_at, e.recorded_by,"
    " e.signed_by_guard_id, s.first_name || ' ' || s.last_name AS signed_by_name, e.signature_meaning,"
    " (e.signature_blob IS NOT NULL) AS has_signature,"
    " latest.status AS adjustment_status, latest.proposed_occurred_at AS adjustment_proposed_at,"
    " approved.proposed_occurred_at AS adjusted_at"
)
EVENT_JOINS = (
    " FROM events e LEFT JOIN guards s ON s.id = e.signed_by_guard_id"
    " LEFT JOIN LATERAL (SELECT a.status, a.proposed_occurred_at FROM adjustments a"
    "   WHERE a.event_id = e.id ORDER BY a.requested_at DESC, a.id DESC LIMIT 1) latest ON true"
    " LEFT JOIN LATERAL (SELECT a.proposed_occurred_at FROM adjustments a"
    "   WHERE a.event_id = e.id AND a.status = 'approved' ORDER BY a.decided_at DESC, a.id DESC LIMIT 1) approved ON true"
)


def recent_events(conn: psycopg.Connection, site_id: int | None, guard_id: int | None, limit: int) -> list[dict]:
    clauses, params = [], []
    if site_id is not None:
        clauses.append("e.site_id = %s")
        params.append(site_id)
    if guard_id is not None:
        clauses.append("(e.guard_id = %s OR e.signed_by_guard_id = %s)")
        params.extend([guard_id, guard_id])
    where = f"WHERE {' AND '.join(clauses)}" if clauses else ""
    params.append(limit)
    return conn.execute(
        f"SELECT {EVENT_COLUMNS}{EVENT_JOINS} {where} ORDER BY e.occurred_at DESC, e.id DESC LIMIT %s",
        params,
    ).fetchall()


# --- Open routes ------------------------------------------------------------------------

@app.get("/healthz")
def healthz():
    """Liveness only. /status checks the database and storage."""
    return {"status": "ok"}


@app.get("/status")
def status():
    result = {"status": "ok", "database": "ok", "storage": "ok", "counts": {}, "errors": {}}
    try:
        db.ensure_setup()
        with db.connect() as conn:
            result["counts"] = conn.execute(
                "SELECT (SELECT count(*) FROM sites) AS sites,"
                " (SELECT count(*) FROM posts) AS posts,"
                " (SELECT count(*) FROM guards) AS guards,"
                " (SELECT count(*) FROM supervisors) AS supervisors,"
                " (SELECT count(*) FROM events WHERE signature_blob IS NOT NULL) AS signatures"
            ).fetchone()
    except Exception as exc:
        log.exception("Status check could not reach the database.")
        result["database"] = "error"
        result["errors"]["database"] = type(exc).__name__
        # Tell a stopped server apart from other database problems.
        try:
            result["database_server"] = server.get_state()
        except server.ServerControlUnavailable as state_exc:
            result["database_server"] = "Unknown"
            result["errors"]["database_server"] = str(state_exc)
    try:
        signatures.check()
    except signatures.StorageUnavailable as exc:
        log.warning("Status check could not read signature storage: %s", exc)
        result["storage"] = "error"
        result["errors"]["storage"] = str(exc)
    if result["database"] != "ok" or result["storage"] != "ok":
        result["status"] = "degraded"
        return JSONResponse(status_code=503, content=result)
    return result


# --- Sign-in --------------------------------------------------------------------------------

@app.post("/auth/login")
def login(body: SignIn):
    try:
        return auth.sign_in(body.badge, body.dob)
    except auth.AuthFailed as exc:
        raise auth_error(exc)
    except (psycopg.OperationalError, ClientAuthenticationError):
        log.exception("Sign-in could not reach the database.")
        raise HTTPException(
            status_code=503,
            detail="The database is not available. Open the Status page to check it, and start it there if it is stopped.",
        )


# --- Reads ------------------------------------------------------------------------------------

@app.get("/sites")
def list_sites(request: Request):
    actor = require_actor(request)
    with database() as conn:
        if actor["site_id"] is not None:
            return conn.execute("SELECT id, name, time_zone FROM sites WHERE id = %s", (actor["site_id"],)).fetchall()
        return conn.execute("SELECT id, name, time_zone FROM sites ORDER BY id").fetchall()


@app.get("/sites/{site_id}/board")
def site_board(site_id: int, request: Request):
    actor = require_actor(request)
    if actor["site_id"] is not None and actor["site_id"] != site_id:
        raise HTTPException(status_code=403, detail="This site is not yours.")
    with database() as conn:
        site = get_site(conn, site_id)
        posts = conn.execute(
            "SELECT p.id, p.name, pa.id AS assignment_id, pa.started_at AS assigned_at,"
            " g.id AS guard_id, g.first_name || ' ' || g.last_name AS guard_name,"
            " b.id AS break_id, b.break_type, b.due_at AS break_due_at,"
            " bg.first_name || ' ' || bg.last_name AS on_break_name,"
            " GREATEST(0, floor(extract(epoch FROM now() - b.due_at) / 60))::int AS overdue_minutes"
            " FROM posts p"
            " LEFT JOIN post_assignments pa ON pa.post_id = p.id AND pa.ended_at IS NULL"
            " LEFT JOIN guards g ON g.id = pa.guard_id"
            " LEFT JOIN breaks b ON b.cover_assignment_id = pa.id AND b.ended_at IS NULL"
            " LEFT JOIN guards bg ON bg.id = b.guard_id"
            " WHERE p.site_id = %s ORDER BY p.id",
            (site_id,),
        ).fetchall()
        guards = conn.execute(
            "SELECT g.id, g.first_name || ' ' || g.last_name AS name, g.badge,"
            " s.id AS shift_id, s.started_at AS shift_started_at,"
            " pa.id AS assignment_id, p.id AS post_id, p.name AS post_name,"
            " ob.id AS break_id, ob.break_type, ob.due_at AS break_due_at, op.name AS break_post_name,"
            " GREATEST(0, floor(extract(epoch FROM now() - ob.due_at) / 60))::int AS overdue_minutes,"
            " oc.first_name || ' ' || oc.last_name AS break_cover_name,"
            " cb.id AS covering_break_id, cg.first_name || ' ' || cg.last_name AS covering_for_name"
            " FROM guards g"
            " LEFT JOIN shifts s ON s.guard_id = g.id AND s.ended_at IS NULL"
            " LEFT JOIN post_assignments pa ON pa.guard_id = g.id AND pa.ended_at IS NULL"
            " LEFT JOIN posts p ON p.id = pa.post_id"
            " LEFT JOIN breaks ob ON ob.guard_id = g.id AND ob.ended_at IS NULL"
            " LEFT JOIN posts op ON op.id = ob.post_id"
            " LEFT JOIN guards oc ON oc.id = ob.cover_guard_id"
            " LEFT JOIN breaks cb ON cb.cover_guard_id = g.id AND cb.ended_at IS NULL"
            " LEFT JOIN guards cg ON cg.id = cb.guard_id"
            " WHERE g.site_id = %s ORDER BY g.id",
            (site_id,),
        ).fetchall()
        for guard in guards:
            guard["state"] = state_of(guard["shift_id"], guard["assignment_id"], guard["break_id"],
                                      guard["covering_break_id"])
        events = recent_events(conn, site_id, None, 15)
    return {"site": site, "posts": posts, "guards": guards, "events": events}


@app.get("/guards/{guard_id}")
def guard_detail(guard_id: int, request: Request):
    actor = require_actor(request)
    with database() as conn:
        guard = get_guard(conn, guard_id)
        if actor["kind"] == "guard" and actor["id"] != guard_id:
            raise HTTPException(status_code=403, detail="Guards can only open their own page.")
        if actor["kind"] == "supervisor" and actor["site_id"] not in (None, guard["site_id"]):
            raise HTTPException(status_code=403, detail="This guard works at a different site.")
        site = get_site(conn, guard["site_id"])
        shift = open_shift(conn, guard_id)
        assignment = open_assignment(conn, guard_id)
        own_break = open_break(conn, guard_id)
        cover = open_cover(conn, guard_id)
        events = recent_events(conn, None, guard_id, 10)
    return {
        "guard": {**guard, "name": full_name(guard)},
        "site": site,
        "state": state_of(shift, assignment, own_break, cover),
        "open_shift": shift,
        "open_assignment": assignment,
        "open_break": own_break,
        "covering": cover,
        "events": events,
    }


@app.get("/events")
def list_events(request: Request, site_id: int | None = None, limit: int = Query(default=20, ge=1, le=100)):
    require_actor(request)
    with database() as conn:
        return recent_events(conn, site_id, None, limit)


@app.get("/events/{event_id}/signature")
def event_signature(event_id: int, request: Request):
    require_actor(request)
    with database() as conn:
        row = conn.execute("SELECT signature_blob FROM events WHERE id = %s", (event_id,)).fetchone()
        if row is None:
            raise HTTPException(status_code=404, detail=f"Event {event_id} does not exist.")
        if not row["signature_blob"]:
            raise HTTPException(status_code=404, detail=f"Event {event_id} has no signature.")
        image = signatures.download(row["signature_blob"])
    if image is None:
        raise HTTPException(status_code=404, detail=f"The signature for event {event_id} is missing from storage.")
    return Response(content=image, media_type="image/png", headers={"Cache-Control": "private, max-age=3600"})


# --- Shifts and posts ---------------------------------------------------------------------

@app.post("/shifts", status_code=201)
def start_shift(body: ShiftStart, request: Request):
    actor = require_guard(request, body.guard_id)
    image = read_signature(body.signature)
    with database() as conn:
        guard = get_guard(conn, body.guard_id, lock=True)
        witness = get_guard(conn, body.witness_guard_id)
        name = full_name(guard)
        if witness["id"] == guard["id"]:
            raise conflict("The witness must be a different guard.")
        if witness["site_id"] != guard["site_id"]:
            raise conflict(f"{full_name(witness)} works at a different site.")
        if not body.equipment_on:
            raise HTTPException(status_code=400, detail="Confirm that the guard has their equipment on.")
        if open_shift(conn, guard["id"]):
            raise conflict(f"{name} already has an open shift.")
        shift = conn.execute(
            "INSERT INTO shifts (guard_id, witness_guard_id, equipment_on) VALUES (%s, %s, true)"
            " RETURNING id, guard_id, witness_guard_id, started_at, equipment_on",
            (guard["id"], witness["id"]),
        ).fetchone()
        event_id = commit_signed_event(
            conn, image, signer_id=guard["id"], site_id=guard["site_id"], event_type="shift_started",
            detail=f"{name} started a shift. Witness: {full_name(witness)}. Equipment on. Signed.",
            meaning="Authorship: starts the shift with equipment on",
            guard_id=guard["id"], recorded_by=actor["badge"],
        )
    return {**shift, "event_id": event_id}


@app.post("/shifts/{shift_id}/end")
def end_shift(shift_id: int, body: ShiftEnd, request: Request):
    image = read_signature(body.signature)
    with database() as conn:
        shift = conn.execute(
            "SELECT id, guard_id, ended_at FROM shifts WHERE id = %s FOR UPDATE", (shift_id,)
        ).fetchone()
        if shift is None:
            raise HTTPException(status_code=404, detail=f"Shift {shift_id} does not exist.")
        actor = require_guard(request, shift["guard_id"])
        guard = get_guard(conn, shift["guard_id"], lock=True)
        name = full_name(guard)
        if shift["ended_at"] is not None:
            raise conflict("This shift has already ended.")
        if not body.equipment_off:
            raise HTTPException(status_code=400, detail="Confirm that the guard has their equipment off.")
        own_break = open_break(conn, guard["id"])
        if own_break:
            raise conflict(f"{name} is on a {BREAK_LABELS[own_break['break_type']]}. Return from the break before ending the shift.")
        cover = open_cover(conn, guard["id"])
        if cover:
            raise conflict(
                f"{name} is covering {cover['post_name']} for {cover['guard_name']}'s {BREAK_LABELS[cover['break_type']]}. "
                f"{cover['guard_name']} must return first."
            )
        assignment = open_assignment(conn, guard["id"])
        if assignment:
            raise conflict(
                f"{name} is still on {assignment['post_name']}. "
                "Hand the post to a relief guard before ending the shift."
            )
        ended = conn.execute(
            "UPDATE shifts SET ended_at = now(), equipment_off = true WHERE id = %s"
            " RETURNING id, guard_id, started_at, ended_at",
            (shift_id,),
        ).fetchone()
        event_id = commit_signed_event(
            conn, image, signer_id=guard["id"], site_id=guard["site_id"], event_type="shift_ended",
            detail=f"{name} ended a shift. Equipment off. Signed.",
            meaning="Authorship: ends the shift with equipment off",
            guard_id=guard["id"], recorded_by=actor["badge"],
        )
    return {**ended, "event_id": event_id}


@app.post("/assignments", status_code=201)
def take_post(body: AssignmentCreate, request: Request):
    actor = require_guard(request, body.guard_id)
    with database() as conn:
        guard = get_guard(conn, body.guard_id, lock=True)
        name = full_name(guard)
        post = conn.execute(
            "SELECT id, site_id, name FROM posts WHERE id = %s FOR UPDATE", (body.post_id,)
        ).fetchone()
        if post is None:
            raise HTTPException(status_code=404, detail=f"Post {body.post_id} does not exist.")
        shift = open_shift(conn, guard["id"])
        if shift is None:
            raise conflict(f"{name} must start a shift before taking a post.")
        if open_break(conn, guard["id"]):
            raise conflict(f"{name} is on a break. Return from the break first.")
        current = open_assignment(conn, guard["id"])
        if current:
            raise conflict(f"{name} is already on {current['post_name']}.")
        if post["site_id"] != guard["site_id"]:
            raise conflict(f"{post['name']} is at a different site from {name}.")
        occupant = conn.execute(
            "SELECT g.first_name, g.last_name FROM post_assignments pa JOIN guards g ON g.id = pa.guard_id"
            " WHERE pa.post_id = %s AND pa.ended_at IS NULL",
            (post["id"],),
        ).fetchone()
        if occupant:
            raise conflict(f"{post['name']} is already covered by {full_name(occupant)}.")
        assignment = conn.execute(
            "INSERT INTO post_assignments (post_id, guard_id, shift_id) VALUES (%s, %s, %s)"
            " RETURNING id, post_id, guard_id, shift_id, started_at",
            (post["id"], guard["id"], shift["id"]),
        ).fetchone()
        add_event(conn, guard["site_id"], "post_taken", f"{name} took {post['name']}.", guard["id"], post["id"],
                  recorded_by=actor["badge"])
    return assignment


@app.post("/assignments/{assignment_id}/relieve")
def relieve(assignment_id: int, body: Relief, request: Request):
    image = read_signature(body.signature)
    with database() as conn:
        assignment = conn.execute(
            "SELECT pa.id, pa.post_id, pa.guard_id, pa.ended_at FROM post_assignments pa WHERE pa.id = %s",
            (assignment_id,),
        ).fetchone()
        if assignment is None:
            raise HTTPException(status_code=404, detail=f"Assignment {assignment_id} does not exist.")
        require_guard(request, assignment["guard_id"])
    # The relief guard proves who they are in a separate transaction, so a wrong try counts.
    try:
        auth.confirm_guard(body.relief_guard_id, body.relief_dob, "relief guard")
    except auth.AuthFailed as exc:
        raise auth_error(exc)
    actor = require_actor(request)
    with database() as conn:
        assignment = conn.execute(
            "SELECT pa.id, pa.post_id, pa.guard_id, pa.ended_at, p.name AS post_name, p.site_id"
            " FROM post_assignments pa JOIN posts p ON p.id = pa.post_id"
            " WHERE pa.id = %s FOR UPDATE OF pa",
            (assignment_id,),
        ).fetchone()
        if assignment["ended_at"] is not None:
            raise conflict("This guard has already been relieved from the post.")
        current = get_guard(conn, assignment["guard_id"])
        cover = open_cover(conn, current["id"])
        if cover:
            raise conflict(
                f"{full_name(current)} is covering {cover['post_name']} for {cover['guard_name']}'s "
                f"{BREAK_LABELS[cover['break_type']]}. {cover['guard_name']} must return first."
            )
        relief_guard = get_guard(conn, body.relief_guard_id, lock=True)
        relief_name = full_name(relief_guard)
        if relief_guard["id"] == current["id"]:
            raise conflict("The relief guard must be a different guard.")
        if relief_guard["site_id"] != assignment["site_id"]:
            raise conflict(f"{relief_name} works at a different site.")
        relief_shift = require_available(conn, relief_guard, "relief guard")

        # One transaction ends the old assignment and starts the new one.
        conn.execute("UPDATE post_assignments SET ended_at = now() WHERE id = %s", (assignment_id,))
        new_assignment = conn.execute(
            "INSERT INTO post_assignments (post_id, guard_id, shift_id, relieves_assignment_id)"
            " VALUES (%s, %s, %s, %s) RETURNING id, post_id, guard_id, shift_id, started_at",
            (assignment["post_id"], relief_guard["id"], relief_shift["id"], assignment_id),
        ).fetchone()
        event_id = commit_signed_event(
            conn, image, signer_id=relief_guard["id"], site_id=assignment["site_id"], event_type="post_relieved",
            detail=f"{relief_name} relieved {full_name(current)} on {assignment['post_name']}. Signed by {relief_name}.",
            meaning=f"Responsibility: accepts {assignment['post_name']}",
            guard_id=relief_guard["id"], post_id=assignment["post_id"], recorded_by=actor["badge"],
        )
    return {"ended_assignment_id": assignment_id, "assignment": new_assignment, "event_id": event_id}


# --- Breaks ------------------------------------------------------------------------------------

@app.post("/breaks", status_code=201)
def start_break(body: BreakStart, request: Request):
    actor = require_guard(request, body.guard_id)
    if body.break_type not in BREAK_MINUTES:
        raise HTTPException(status_code=400, detail="Pick a lunch break or a restroom break.")
    image = read_signature(body.signature)
    if body.cover_guard_id == body.guard_id:
        raise conflict("The cover guard must be a different guard.")
    try:
        auth.confirm_guard(body.cover_guard_id, body.cover_dob, "cover guard")
    except auth.AuthFailed as exc:
        raise auth_error(exc)
    label = BREAK_LABELS[body.break_type]
    minutes = BREAK_MINUTES[body.break_type]
    with database() as conn:
        guard = get_guard(conn, body.guard_id, lock=True)
        name = full_name(guard)
        shift = open_shift(conn, guard["id"])
        if shift is None:
            raise conflict(f"{name} is not on shift.")
        if open_break(conn, guard["id"]):
            raise conflict(f"{name} is already on a break.")
        cover_for = open_cover(conn, guard["id"])
        if cover_for:
            raise conflict(
                f"{name} is covering {cover_for['post_name']} for {cover_for['guard_name']}. "
                f"{cover_for['guard_name']} must return before {name} can take a break."
            )
        assignment = open_assignment(conn, guard["id"])
        if assignment is None:
            raise conflict(f"{name} is not on a post. A break hands a post to a cover guard.")
        cover = get_guard(conn, body.cover_guard_id, lock=True)
        cover_name = full_name(cover)
        if cover["site_id"] != guard["site_id"]:
            raise conflict(f"{cover_name} works at a different site.")
        cover_shift = require_available(conn, cover, "cover guard")

        conn.execute("UPDATE post_assignments SET ended_at = now() WHERE id = %s", (assignment["id"],))
        cover_assignment = conn.execute(
            "INSERT INTO post_assignments (post_id, guard_id, shift_id, relieves_assignment_id)"
            " VALUES (%s, %s, %s, %s) RETURNING id",
            (assignment["post_id"], cover["id"], cover_shift["id"], assignment["id"]),
        ).fetchone()
        new_break = conn.execute(
            "INSERT INTO breaks (guard_id, shift_id, post_id, cover_guard_id, break_type, due_at,"
            " original_assignment_id, cover_assignment_id)"
            " VALUES (%s, %s, %s, %s, %s, now() + make_interval(mins => %s), %s, %s)"
            " RETURNING id, started_at, due_at",
            (guard["id"], shift["id"], assignment["post_id"], cover["id"], body.break_type, minutes,
             assignment["id"], cover_assignment["id"]),
        ).fetchone()
        event_id = commit_signed_event(
            conn, image, signer_id=cover["id"], site_id=guard["site_id"], event_type="break_started",
            detail=f"{name} started a {label} ({minutes} min). {cover_name} covers {assignment['post_name']}. "
                   f"Signed by {cover_name}.",
            meaning=f"Responsibility: covers {assignment['post_name']} during {name}'s {label}",
            guard_id=guard["id"], post_id=assignment["post_id"], recorded_by=actor["badge"],
        )
    return {**new_break, "event_id": event_id}


@app.post("/breaks/{break_id}/return")
def return_from_break(break_id: int, body: BreakReturn, request: Request):
    image = read_signature(body.signature)
    with database() as conn:
        row = conn.execute(
            f"SELECT {BREAK_COLUMNS}, b.shift_id, b.ended_at, p.site_id,"
            " floor(extract(epoch FROM now() - b.started_at) / 60)::int AS minutes_away"
            f"{BREAK_JOINS} WHERE b.id = %s FOR UPDATE OF b",
            (break_id,),
        ).fetchone()
        if row is None:
            raise HTTPException(status_code=404, detail=f"Break {break_id} does not exist.")
        actor = require_guard(request, row["guard_id"])
        if row["ended_at"] is not None:
            raise conflict("This break has already ended.")
        conn.execute("UPDATE post_assignments SET ended_at = now() WHERE id = %s", (row["cover_assignment_id"],))
        conn.execute(
            "INSERT INTO post_assignments (post_id, guard_id, shift_id, relieves_assignment_id)"
            " VALUES (%s, %s, %s, %s)",
            (row["post_id"], row["guard_id"], row["shift_id"], row["cover_assignment_id"]),
        )
        conn.execute("UPDATE breaks SET ended_at = now() WHERE id = %s", (break_id,))
        late = f" {row['overdue_minutes']} min over." if row["overdue_minutes"] else ""
        event_id = commit_signed_event(
            conn, image, signer_id=row["guard_id"], site_id=row["site_id"], event_type="break_ended",
            detail=f"{row['guard_name']} returned to {row['post_name']} from a {BREAK_LABELS[row['break_type']]} "
                   f"after {row['minutes_away']} min.{late} {row['cover_name']} is available again. Signed.",
            meaning=f"Responsibility: takes {row['post_name']} back after the {BREAK_LABELS[row['break_type']]}",
            guard_id=row["guard_id"], post_id=row["post_id"], recorded_by=actor["badge"],
        )
    return {"break_id": break_id, "event_id": event_id}


# --- Corrections ---------------------------------------------------------------------------

@app.post("/events/{event_id}/adjustments", status_code=201)
def request_adjustment(event_id: int, body: AdjustmentRequest, request: Request):
    actor = require_actor(request)
    if actor["kind"] != "guard":
        raise HTTPException(status_code=403, detail="Guards request corrections. Supervisors approve them.")
    reason = body.reason.strip()
    if len(reason) < 5:
        raise HTTPException(status_code=400, detail="Explain the correction in a few words.")
    try:
        hour, minute = (int(part) for part in body.proposed_time.split(":")[:2])
    except ValueError:
        raise HTTPException(status_code=400, detail="Enter the corrected time as HH:MM.")
    with database() as conn:
        event = conn.execute(
            "SELECT e.id, e.site_id, e.guard_id, e.signed_by_guard_id, e.event_type, e.detail, e.occurred_at,"
            " s.time_zone FROM events e JOIN sites s ON s.id = e.site_id WHERE e.id = %s FOR UPDATE OF e",
            (event_id,),
        ).fetchone()
        if event is None:
            raise HTTPException(status_code=404, detail=f"Event {event_id} does not exist.")
        if actor["id"] not in (event["guard_id"], event["signed_by_guard_id"]):
            raise HTTPException(status_code=403, detail="Guards can only correct their own entries.")
        if event["event_type"].startswith("adjustment_"):
            raise conflict("A correction record cannot be corrected.")
        zone = ZoneInfo(event["time_zone"])
        original_local = event["occurred_at"].astimezone(zone)
        try:
            proposed = original_local.replace(hour=hour, minute=minute, second=0, microsecond=0)
        except ValueError:
            raise HTTPException(status_code=400, detail="Enter the corrected time as HH:MM.")
        if proposed > datetime.now(timezone.utc):
            raise HTTPException(status_code=400, detail="The corrected time cannot be in the future.")
        if abs(proposed - original_local) < timedelta(minutes=1):
            raise HTTPException(status_code=400, detail="The corrected time is the same as the recorded time.")
        pending = conn.execute(
            "SELECT 1 FROM adjustments WHERE event_id = %s AND status = 'pending'", (event_id,)
        ).fetchone()
        if pending:
            raise conflict("A correction for this entry is already waiting for a supervisor.")
        guard = get_guard(conn, actor["id"])
        adjustment = conn.execute(
            "INSERT INTO adjustments (event_id, requested_by_guard_id, original_occurred_at, proposed_occurred_at, reason)"
            " VALUES (%s, %s, %s, %s, %s) RETURNING id, status",
            (event_id, actor["id"], event["occurred_at"], proposed, reason),
        ).fetchone()
        add_event(
            conn, event["site_id"], "adjustment_requested",
            f"{full_name(guard)} asked to correct entry {event_id} from {original_local:%H:%M} to {proposed:%H:%M}. "
            f"Reason: {reason}",
            guard_id=actor["id"], recorded_by=actor["badge"],
        )
    return adjustment


@app.post("/adjustments/{adjustment_id}/decision")
def decide_adjustment(adjustment_id: int, body: AdjustmentDecision, request: Request):
    require_supervisor(request)
    note = body.note.strip()
    if not body.approve and len(note) < 5:
        raise HTTPException(status_code=400, detail="Write a short reason for rejecting the correction.")
    with database() as conn:
        row = conn.execute(
            "SELECT a.id, a.status, a.event_id, a.original_occurred_at, a.proposed_occurred_at, e.site_id, s.time_zone,"
            " g.first_name || ' ' || g.last_name AS requested_by"
            " FROM adjustments a JOIN events e ON e.id = a.event_id JOIN sites s ON s.id = e.site_id"
            " JOIN guards g ON g.id = a.requested_by_guard_id WHERE a.id = %s FOR UPDATE OF a",
            (adjustment_id,),
        ).fetchone()
        if row is None:
            raise HTTPException(status_code=404, detail=f"Correction {adjustment_id} does not exist.")
        actor = require_supervisor(request, row["site_id"])
        if row["status"] != "pending":
            raise conflict(f"This correction was already {row['status']}.")
        supervisor = conn.execute(
            "SELECT first_name, last_name FROM supervisors WHERE id = %s", (actor["id"],)
        ).fetchone()
        status = "approved" if body.approve else "rejected"
        conn.execute(
            "UPDATE adjustments SET status = %s, decided_by_supervisor_id = %s, decided_at = now(), decision_note = %s"
            " WHERE id = %s",
            (status, actor["id"], note or None, adjustment_id),
        )
        zone = ZoneInfo(row["time_zone"])
        detail = (
            f"{full_name(supervisor)} {status} {row['requested_by']}'s correction to entry {row['event_id']}: "
            f"{row['original_occurred_at'].astimezone(zone):%H:%M} to {row['proposed_occurred_at'].astimezone(zone):%H:%M}."
        )
        if note:
            detail += f" Note: {note}"
        add_event(conn, row["site_id"], f"adjustment_{status}", detail, recorded_by=actor["badge"])
    return {"id": adjustment_id, "status": status}


# --- Supervise and audit -------------------------------------------------------------------

@app.get("/sites/{site_id}/attention")
def attention(site_id: int, request: Request):
    """Entries a supervisor should look at: overdue breaks, long shifts and pending corrections."""
    require_supervisor(request, site_id)
    with database() as conn:
        get_site(conn, site_id)
        overdue = conn.execute(
            f"SELECT {BREAK_COLUMNS}{BREAK_JOINS} WHERE p.site_id = %s AND b.ended_at IS NULL AND b.due_at < now()"
            " ORDER BY b.due_at",
            (site_id,),
        ).fetchall()
        long_shifts = conn.execute(
            "SELECT s.id, s.started_at, g.id AS guard_id, g.first_name || ' ' || g.last_name AS guard_name,"
            " floor(extract(epoch FROM now() - s.started_at) / 3600)::int AS hours"
            " FROM shifts s JOIN guards g ON g.id = s.guard_id"
            " WHERE g.site_id = %s AND s.ended_at IS NULL AND s.started_at < now() - make_interval(hours => %s)"
            " ORDER BY s.started_at",
            (site_id, LONG_SHIFT_HOURS),
        ).fetchall()
        pending = conn.execute(
            "SELECT a.id, a.event_id, a.requested_at, a.original_occurred_at, a.proposed_occurred_at, a.reason,"
            " e.detail AS event_detail, e.event_type, g.first_name || ' ' || g.last_name AS requested_by"
            " FROM adjustments a JOIN events e ON e.id = a.event_id JOIN guards g ON g.id = a.requested_by_guard_id"
            " WHERE e.site_id = %s AND a.status = 'pending' ORDER BY a.requested_at",
            (site_id,),
        ).fetchall()
        locked = conn.execute(
            "SELECT badge, first_name || ' ' || last_name AS name, locked_until FROM guards"
            " WHERE site_id = %s AND locked_until > now()"
            " UNION ALL SELECT badge, first_name || ' ' || last_name, locked_until FROM supervisors"
            " WHERE site_id = %s AND locked_until > now() ORDER BY 3",
            (site_id, site_id),
        ).fetchall()
    return {"overdue_breaks": overdue, "long_shifts": long_shifts, "pending_adjustments": pending,
            "locked_accounts": locked, "long_shift_hours": LONG_SHIFT_HOURS}


@app.get("/sites/{site_id}/daily")
def daily_record(site_id: int, request: Request, day: str | None = None):
    """Every event recorded on one local day at a site, with corrections and signature checks."""
    require_supervisor(request, site_id)
    with database() as conn:
        site = get_site(conn, site_id)
        zone = ZoneInfo(site["time_zone"])
        try:
            local_day = date.fromisoformat(day) if day else datetime.now(zone).date()
        except ValueError:
            raise HTTPException(status_code=400, detail="Use a date such as 2026-10-27.")
        start = datetime(local_day.year, local_day.month, local_day.day, tzinfo=zone)
        end = start + timedelta(days=1)
        events = conn.execute(
            f"SELECT {EVENT_COLUMNS}, e.signature_blob, e.signature_sha256,"
            " g.first_name || ' ' || g.last_name AS guard_name, p.name AS post_name"
            f"{EVENT_JOINS} LEFT JOIN guards g ON g.id = e.guard_id LEFT JOIN posts p ON p.id = e.post_id"
            " WHERE e.site_id = %s AND e.occurred_at >= %s AND e.occurred_at < %s ORDER BY e.occurred_at, e.id",
            (site_id, start, end),
        ).fetchall()
        history = conn.execute(
            "SELECT a.id, a.event_id, a.status, a.requested_at, a.original_occurred_at, a.proposed_occurred_at,"
            " a.reason, a.decided_at, a.decision_note, g.first_name || ' ' || g.last_name AS requested_by,"
            " sv.first_name || ' ' || sv.last_name AS decided_by"
            " FROM adjustments a JOIN guards g ON g.id = a.requested_by_guard_id"
            " LEFT JOIN supervisors sv ON sv.id = a.decided_by_supervisor_id"
            " WHERE a.event_id = ANY(%s) ORDER BY a.requested_at, a.id",
            ([e["id"] for e in events],),
        ).fetchall()
        for event in events:
            event["adjustments"] = [a for a in history if a["event_id"] == event["id"]]
            event["signature_check"] = "none"
            if event["signature_blob"]:
                image = signatures.download(event["signature_blob"])
                if image is None:
                    event["signature_check"] = "missing"
                elif not event["signature_sha256"]:
                    event["signature_check"] = "unverified"
                elif hmac.compare_digest(hashlib.sha256(image).hexdigest(), event["signature_sha256"]):
                    event["signature_check"] = "verified"
                else:
                    event["signature_check"] = "mismatch"
            del event["signature_blob"]
    summary = {
        "events": len(events),
        "signed": sum(1 for e in events if e["has_signature"]),
        "verified": sum(1 for e in events if e["signature_check"] == "verified"),
        "problems": sum(1 for e in events if e["signature_check"] in ("missing", "mismatch")),
        "adjusted": sum(1 for e in events if e["adjusted_at"]),
        "pending": sum(1 for e in events if e["adjustment_status"] == "pending"),
    }
    return {"site": site, "day": local_day.isoformat(), "events": events, "summary": summary}


# --- Admin -----------------------------------------------------------------------------------

@app.post("/admin/start-database")
def start_database():
    """Start the PostgreSQL server if it is stopped. Azure takes about 2 minutes.

    No sign-in is needed: with the database stopped, nobody can sign in, and starting
    a stopped server changes no data.
    """
    try:
        return {"database_server": server.start()}
    except server.ServerControlUnavailable as exc:
        raise HTTPException(status_code=503, detail=str(exc))


@app.post("/admin/reset")
def reset_demo_data(request: Request):
    """Put the demo back to its seeded state: database rows first, then signature files.

    The database goes first so no event ever points at a deleted signature. If storage
    then fails, the old files stay behind unused and the response says so.
    """
    require_supervisor(request)
    try:
        result = db.reset()
    except (psycopg.Error, ClientAuthenticationError):
        log.exception("Reset could not reach the database.")
        raise HTTPException(status_code=503, detail="The database is not available. Try again shortly.")
    try:
        result["signatures_deleted"] = signatures.delete_all()
    except signatures.StorageUnavailable as exc:
        result["signatures_deleted"] = None
        result["storage_warning"] = f"The data was reset, but old signature files could not be deleted ({exc})."
    return result
