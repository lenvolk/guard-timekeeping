"""Sign-in with an employee ID (the badge) and a date of birth.

This is a demo scheme for synthetic data. A date of birth is weak as a password,
so only a salted PBKDF2 hash is stored, and five wrong tries lock the account for
five minutes. Production should use Microsoft Entra ID or a PIN instead.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import os
import re
from datetime import date

import psycopg

import db

ITERATIONS = 120_000
MAX_FAILED_TRIES = 5
LOCK_MINUTES = 5
WRONG_CREDENTIALS = "The employee ID or date of birth is wrong."


class AuthFailed(Exception):
    def __init__(self, status: int, message: str):
        super().__init__(message)
        self.status = status
        self.message = message


def normalize_badge(text: str | None) -> str | None:
    """G-1001, g1001 and "G 1001" all become G-1001."""
    match = re.fullmatch(r"\s*([GSgs])\s*-?\s*(\d{4})\s*", text or "")
    return f"{match.group(1).upper()}-{match.group(2)}" if match else None


def normalize_dob(text: str | None) -> str | None:
    """MM/DD/YYYY, M/D/YYYY, MM-DD-YYYY or MMDDYYYY become an ISO date string."""
    value = (text or "").strip()
    match = re.fullmatch(r"(\d{1,2})[/.\-](\d{1,2})[/.\-](\d{4})", value) or re.fullmatch(
        r"(\d{2})(\d{2})(\d{4})", value
    )
    if not match:
        return None
    try:
        return date(int(match.group(3)), int(match.group(1)), int(match.group(2))).isoformat()
    except ValueError:
        return None


def hash_dob(iso_date: str, salt: bytes | None = None) -> str:
    salt = salt or os.urandom(16)
    digest = hashlib.pbkdf2_hmac("sha256", iso_date.encode(), salt, ITERATIONS)
    return "pbkdf2_sha256${}${}${}".format(
        ITERATIONS, base64.b64encode(salt).decode(), base64.b64encode(digest).decode()
    )


def check_dob(iso_date: str, stored: str) -> bool:
    try:
        _, iterations, salt, expected = stored.split("$")
        digest = hashlib.pbkdf2_hmac("sha256", iso_date.encode(), base64.b64decode(salt), int(iterations))
        return hmac.compare_digest(digest, base64.b64decode(expected))
    except (ValueError, TypeError):
        return False


def _verify(conn: psycopg.Connection, badge: str, iso_date: str) -> dict:
    table = "guards" if badge.startswith("G") else "supervisors"
    row = conn.execute(
        f"SELECT id, site_id, first_name, last_name, badge, dob_hash, failed_logins,"
        f" locked_until > now() AS locked,"
        f" ceil(extract(epoch FROM locked_until - now()) / 60) AS minutes_left"
        f" FROM {table} WHERE badge = %s FOR UPDATE",
        (badge,),
    ).fetchone()
    if row is None or not row["dob_hash"]:
        raise AuthFailed(401, WRONG_CREDENTIALS)
    if row["locked"]:
        raise AuthFailed(423, f"Too many wrong tries. {badge} is locked for {int(row['minutes_left'])} more minute(s).")
    if not check_dob(iso_date, row["dob_hash"]):
        failed = row["failed_logins"] + 1
        if failed >= MAX_FAILED_TRIES:
            conn.execute(
                f"UPDATE {table} SET failed_logins = 0, locked_until = now() + make_interval(mins => %s) WHERE id = %s",
                (LOCK_MINUTES, row["id"]),
            )
            # 21 CFR 11.300(d): report attempted unauthorized use. The event lands in the
            # site's audit trail, and the supervisor sees the locked account.
            if row["site_id"] is not None:
                conn.execute(
                    "INSERT INTO events (site_id, guard_id, event_type, detail, recorded_by) VALUES (%s, %s, %s, %s, %s)",
                    (row["site_id"], row["id"] if table == "guards" else None, "account_locked",
                     f"{badge} was locked for {LOCK_MINUTES} minutes after {MAX_FAILED_TRIES} wrong sign-in tries.",
                     "system"),
                )
            conn.commit()
            raise AuthFailed(423, f"Too many wrong tries. {badge} is locked for {LOCK_MINUTES} minutes.")
        conn.execute(f"UPDATE {table} SET failed_logins = %s WHERE id = %s", (failed, row["id"]))
        conn.commit()
        raise AuthFailed(401, WRONG_CREDENTIALS)
    conn.execute(f"UPDATE {table} SET failed_logins = 0, locked_until = NULL WHERE id = %s", (row["id"],))
    conn.commit()
    return {
        "kind": "guard" if table == "guards" else "supervisor",
        "id": row["id"],
        "badge": row["badge"],
        "name": f"{row['first_name']} {row['last_name']}",
        "site_id": row["site_id"],
    }


def sign_in(badge_text: str | None, dob_text: str | None) -> dict:
    """Checks the credentials and returns the person. Raises AuthFailed."""
    badge = normalize_badge(badge_text)
    if not badge:
        raise AuthFailed(400, "Enter an employee ID such as G-1001.")
    iso_date = normalize_dob(dob_text)
    if not iso_date:
        raise AuthFailed(400, "Enter the date of birth as MM/DD/YYYY.")
    db.ensure_setup()
    with db.connect() as conn:
        return _verify(conn, badge, iso_date)


def confirm_guard(guard_id: int, dob_text: str | None, role: str) -> dict:
    """Checks the date of birth of a second guard, such as a relief or cover guard,
    in its own transaction so a wrong try still counts toward the lockout."""
    iso_date = normalize_dob(dob_text)
    db.ensure_setup()
    with db.connect() as conn:
        row = conn.execute(
            "SELECT badge, first_name || ' ' || last_name AS name FROM guards WHERE id = %s", (guard_id,)
        ).fetchone()
        if row is None:
            raise AuthFailed(404, f"Guard {guard_id} does not exist.")
        if not iso_date:
            raise AuthFailed(400, f"Enter the {role}'s date of birth as MM/DD/YYYY.")
        try:
            return _verify(conn, row["badge"], iso_date)
        except AuthFailed as exc:
            if exc.status == 401:
                raise AuthFailed(401, f"The date of birth for {row['name']} is wrong.") from exc
            raise
