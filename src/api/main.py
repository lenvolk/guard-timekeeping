"""Timekeeping API. Signs in to PostgreSQL and Blob Storage with its managed
identity. The web app calls it from the server."""

from __future__ import annotations

import logging
import os
from contextlib import asynccontextmanager, contextmanager
from typing import Iterator

if os.environ.get("APPLICATIONINSIGHTS_CONNECTION_STRING"):
    # Configure telemetry before FastAPI is imported so requests are instrumented.
    from azure.monitor.opentelemetry import configure_azure_monitor

    configure_azure_monitor(logger_name="timekeeping")

import psycopg
from azure.core.exceptions import ClientAuthenticationError
from fastapi import FastAPI, HTTPException, Query
from fastapi.responses import JSONResponse, Response
from pydantic import BaseModel
from starlette.concurrency import run_in_threadpool

import db
import signatures

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("timekeeping.api")


@asynccontextmanager
async def lifespan(_app: FastAPI):
    try:
        await run_in_threadpool(db.ensure_setup)
    except Exception:
        # Keep the app running so /status can report the problem. The next request retries.
        log.exception("Database setup failed at startup.")
    yield


app = FastAPI(title="Timekeeping API", version="2.0.0", lifespan=lifespan)


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
    signature: str | None = None


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
        raise HTTPException(status_code=503, detail="The database is not available. Try again shortly.")


def conflict(message: str) -> HTTPException:
    return HTTPException(status_code=409, detail=message)


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


def add_event(
    conn: psycopg.Connection,
    site_id: int,
    event_type: str,
    detail: str,
    guard_id: int | None = None,
    post_id: int | None = None,
) -> dict:
    return conn.execute(
        "INSERT INTO events (site_id, guard_id, post_id, event_type, detail)"
        " VALUES (%s, %s, %s, %s, %s) RETURNING id, occurred_at",
        (site_id, guard_id, post_id, event_type, detail),
    ).fetchone()


def commit_signed_event(
    conn: psycopg.Connection,
    image: bytes,
    signer_id: int,
    site_id: int,
    event_type: str,
    detail: str,
    guard_id: int | None = None,
    post_id: int | None = None,
) -> int:
    """Write the event, upload the signature, then commit.

    The blob goes up first. If the commit then fails, the blob is deleted so no
    signature exists without its event.
    """
    event = add_event(conn, site_id, event_type, detail, guard_id, post_id)
    name = signatures.blob_name(site_id, event["occurred_at"], event["id"])
    conn.execute(
        "UPDATE events SET signed_by_guard_id = %s, signature_blob = %s WHERE id = %s",
        (signer_id, name, event["id"]),
    )
    signatures.upload(name, image)
    try:
        conn.commit()
    except Exception:
        signatures.delete_quietly(name)
        raise
    return event["id"]


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
        "SELECT e.id, e.site_id, e.guard_id, e.post_id, e.event_type, e.detail, e.occurred_at,"
        " e.signed_by_guard_id, s.first_name || ' ' || s.last_name AS signed_by_name,"
        " (e.signature_blob IS NOT NULL) AS has_signature"
        " FROM events e LEFT JOIN guards s ON s.id = e.signed_by_guard_id"
        f" {where} ORDER BY e.occurred_at DESC, e.id DESC LIMIT %s",
        params,
    ).fetchall()


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
                " (SELECT count(*) FROM events WHERE signature_blob IS NOT NULL) AS signatures"
            ).fetchone()
    except Exception as exc:
        log.exception("Status check could not reach the database.")
        result["database"] = "error"
        result["errors"]["database"] = type(exc).__name__
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


@app.get("/sites")
def list_sites():
    with database() as conn:
        return conn.execute("SELECT id, name, time_zone FROM sites ORDER BY id").fetchall()


@app.get("/sites/{site_id}/board")
def site_board(site_id: int):
    with database() as conn:
        site = get_site(conn, site_id)
        posts = conn.execute(
            "SELECT p.id, p.name, pa.id AS assignment_id, pa.started_at AS assigned_at,"
            " g.id AS guard_id, g.first_name || ' ' || g.last_name AS guard_name"
            " FROM posts p"
            " LEFT JOIN post_assignments pa ON pa.post_id = p.id AND pa.ended_at IS NULL"
            " LEFT JOIN guards g ON g.id = pa.guard_id"
            " WHERE p.site_id = %s ORDER BY p.id",
            (site_id,),
        ).fetchall()
        guards = conn.execute(
            "SELECT g.id, g.first_name || ' ' || g.last_name AS name, g.badge,"
            " s.id AS shift_id, s.started_at AS shift_started_at,"
            " pa.id AS assignment_id, p.id AS post_id, p.name AS post_name"
            " FROM guards g"
            " LEFT JOIN shifts s ON s.guard_id = g.id AND s.ended_at IS NULL"
            " LEFT JOIN post_assignments pa ON pa.guard_id = g.id AND pa.ended_at IS NULL"
            " LEFT JOIN posts p ON p.id = pa.post_id"
            " WHERE g.site_id = %s ORDER BY g.id",
            (site_id,),
        ).fetchall()
        for guard in guards:
            if guard["assignment_id"]:
                guard["state"] = "on-post"
            elif guard["shift_id"]:
                guard["state"] = "available"
            else:
                guard["state"] = "off-shift"
        events = recent_events(conn, site_id, None, 15)
    return {"site": site, "posts": posts, "guards": guards, "events": events}


@app.get("/guards/{guard_id}")
def guard_detail(guard_id: int):
    with database() as conn:
        guard = get_guard(conn, guard_id)
        site = get_site(conn, guard["site_id"])
        shift = open_shift(conn, guard_id)
        assignment = open_assignment(conn, guard_id)
        events = recent_events(conn, None, guard_id, 10)
    if assignment:
        state = "on-post"
    elif shift:
        state = "available"
    else:
        state = "off-shift"
    return {
        "guard": {**guard, "name": full_name(guard)},
        "site": site,
        "state": state,
        "open_shift": shift,
        "open_assignment": assignment,
        "events": events,
    }


@app.post("/shifts", status_code=201)
def start_shift(body: ShiftStart):
    image = read_signature(body.signature)
    with database() as conn:
        guard = get_guard(conn, body.guard_id, lock=True)
        witness = get_guard(conn, body.witness_guard_id)
        name = full_name(guard)
        if witness["id"] == guard["id"]:
            raise conflict("The witness must be a different guard.")
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
            conn,
            image,
            signer_id=guard["id"],
            site_id=guard["site_id"],
            event_type="shift_started",
            detail=f"{name} started a shift. Witness: {full_name(witness)}. Equipment on. Signed.",
            guard_id=guard["id"],
        )
    return {**shift, "event_id": event_id}


@app.post("/shifts/{shift_id}/end")
def end_shift(shift_id: int, body: ShiftEnd):
    image = read_signature(body.signature)
    with database() as conn:
        shift = conn.execute(
            "SELECT id, guard_id, ended_at FROM shifts WHERE id = %s FOR UPDATE", (shift_id,)
        ).fetchone()
        if shift is None:
            raise HTTPException(status_code=404, detail=f"Shift {shift_id} does not exist.")
        guard = get_guard(conn, shift["guard_id"], lock=True)
        name = full_name(guard)
        if shift["ended_at"] is not None:
            raise conflict("This shift has already ended.")
        if not body.equipment_off:
            raise HTTPException(status_code=400, detail="Confirm that the guard has their equipment off.")
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
            conn,
            image,
            signer_id=guard["id"],
            site_id=guard["site_id"],
            event_type="shift_ended",
            detail=f"{name} ended a shift. Equipment off. Signed.",
            guard_id=guard["id"],
        )
    return {**ended, "event_id": event_id}


@app.post("/assignments", status_code=201)
def take_post(body: AssignmentCreate):
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
        add_event(conn, guard["site_id"], "post_taken", f"{name} took {post['name']}.", guard["id"], post["id"])
    return assignment


@app.post("/assignments/{assignment_id}/relieve")
def relieve(assignment_id: int, body: Relief):
    image = read_signature(body.signature)
    with database() as conn:
        assignment = conn.execute(
            "SELECT pa.id, pa.post_id, pa.guard_id, pa.ended_at, p.name AS post_name, p.site_id"
            " FROM post_assignments pa JOIN posts p ON p.id = pa.post_id"
            " WHERE pa.id = %s FOR UPDATE OF pa",
            (assignment_id,),
        ).fetchone()
        if assignment is None:
            raise HTTPException(status_code=404, detail=f"Assignment {assignment_id} does not exist.")
        if assignment["ended_at"] is not None:
            raise conflict("This guard has already been relieved from the post.")
        current = get_guard(conn, assignment["guard_id"])
        relief_guard = get_guard(conn, body.relief_guard_id, lock=True)
        relief_name = full_name(relief_guard)
        if relief_guard["id"] == current["id"]:
            raise conflict("The relief guard must be a different guard.")
        if relief_guard["site_id"] != assignment["site_id"]:
            raise conflict(f"{relief_name} works at a different site.")
        relief_shift = open_shift(conn, relief_guard["id"])
        if relief_shift is None:
            raise conflict(f"{relief_name} is not on shift.")
        relief_assignment = open_assignment(conn, relief_guard["id"])
        if relief_assignment:
            raise conflict(f"{relief_name} is already on {relief_assignment['post_name']}.")

        # One transaction ends the old assignment and starts the new one.
        conn.execute("UPDATE post_assignments SET ended_at = now() WHERE id = %s", (assignment_id,))
        new_assignment = conn.execute(
            "INSERT INTO post_assignments (post_id, guard_id, shift_id, relieves_assignment_id)"
            " VALUES (%s, %s, %s, %s) RETURNING id, post_id, guard_id, shift_id, started_at",
            (assignment["post_id"], relief_guard["id"], relief_shift["id"], assignment_id),
        ).fetchone()
        event_id = commit_signed_event(
            conn,
            image,
            signer_id=relief_guard["id"],
            site_id=assignment["site_id"],
            event_type="post_relieved",
            detail=f"{relief_name} relieved {full_name(current)} on {assignment['post_name']}. Signed by {relief_name}.",
            guard_id=relief_guard["id"],
            post_id=assignment["post_id"],
        )
    return {"ended_assignment_id": assignment_id, "assignment": new_assignment, "event_id": event_id}


@app.get("/events")
def list_events(site_id: int | None = None, limit: int = Query(default=20, ge=1, le=100)):
    with database() as conn:
        return recent_events(conn, site_id, None, limit)


@app.get("/events/{event_id}/signature")
def event_signature(event_id: int):
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
