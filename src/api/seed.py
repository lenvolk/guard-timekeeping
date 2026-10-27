"""Synthetic seed data. Every site, post and person here is made up."""

from __future__ import annotations

import psycopg

SITES = [
    {
        "name": "Riverside Office Park",
        "time_zone": "America/New_York",
        "posts": ["Main Gate", "Lobby Desk"],
        # Badge, first name, last name, date of birth (synthetic, MM/DD/YYYY).
        "guards": [
            ("Jordan", "Avila", "G-1001", "03/14/1988"),
            ("Priya", "Hollis", "G-1002", "07/22/1991"),
            ("Marcus", "Ferrin", "G-1003", "11/05/1985"),
            ("Elena", "Brandt", "G-1004", "01/30/1993"),
            ("Tomas", "Reyna", "G-1005", "09/09/1979"),
            ("Grace", "Okafor", "G-1006", "05/17/1996"),
        ],
        "supervisor": ("Riley", "Chen", "S-1001", "04/04/1980"),
    },
    {
        "name": "Lakeshore Distribution Center",
        "time_zone": "America/Chicago",
        "posts": ["North Dock Gate", "Control Room"],
        "guards": [
            ("Dana", "Whitlock", "G-2001", "12/02/1987"),
            ("Samuel", "Ortiz-Lane", "G-2002", "04/26/1990"),
            ("Keisha", "Morrow", "G-2003", "08/11/1984"),
            ("Victor", "Lindqvist", "G-2004", "02/19/1992"),
            ("Hannah", "Prescott", "G-2005", "10/03/1995"),
            ("Omar", "Castellano", "G-2006", "06/28/1982"),
        ],
        "supervisor": ("Morgan", "Patel", "S-2001", "10/10/1983"),
    },
]

# Sees every site.
REGIONAL_SUPERVISOR = ("Avery", "Brooks", "S-9001", "01/15/1976")


def _dob_hash(us_date: str) -> str:
    # Imported here because auth imports db, which imports this module.
    from auth import hash_dob, normalize_dob

    return hash_dob(normalize_dob(us_date))

# Starting state for each site, by position in the guard list:
# guard 1 is on shift and on the first post (a busy relief candidate),
# guard 2 is on shift and off post (an available relief candidate),
# guard 4 witnessed both shifts. The second post starts vacant.
ON_POST = 1
AVAILABLE = 2
WITNESS = 4


def load(conn: psycopg.Connection) -> None:
    """Insert the seed data. The caller holds the setup lock and commits."""
    for site in SITES:
        site_id = conn.execute(
            "INSERT INTO sites (name, time_zone) VALUES (%s, %s) RETURNING id",
            (site["name"], site["time_zone"]),
        ).fetchone()["id"]

        post_ids = [
            conn.execute(
                "INSERT INTO posts (site_id, name) VALUES (%s, %s) RETURNING id",
                (site_id, post_name),
            ).fetchone()["id"]
            for post_name in site["posts"]
        ]

        guard_ids = []
        names = []
        for first, last, badge, dob in site["guards"]:
            guard_ids.append(
                conn.execute(
                    "INSERT INTO guards (site_id, first_name, last_name, badge, dob_hash)"
                    " VALUES (%s, %s, %s, %s, %s) RETURNING id",
                    (site_id, first, last, badge, _dob_hash(dob)),
                ).fetchone()["id"]
            )
            names.append(f"{first} {last}")

        first, last, badge, dob = site["supervisor"]
        conn.execute(
            "INSERT INTO supervisors (site_id, first_name, last_name, badge, dob_hash) VALUES (%s, %s, %s, %s, %s)",
            (site_id, first, last, badge, _dob_hash(dob)),
        )

        witness_id = guard_ids[WITNESS]
        witness_name = names[WITNESS]
        shift_ids = {}
        for index, hours_ago in ((ON_POST, 3), (AVAILABLE, 2)):
            shift_ids[index] = conn.execute(
                "INSERT INTO shifts (guard_id, witness_guard_id, started_at, equipment_on)"
                " VALUES (%s, %s, now() - make_interval(hours => %s), true) RETURNING id",
                (guard_ids[index], witness_id, hours_ago),
            ).fetchone()["id"]
            conn.execute(
                "INSERT INTO events (site_id, guard_id, event_type, detail, occurred_at)"
                " VALUES (%s, %s, 'shift_started', %s, now() - make_interval(hours => %s))",
                (
                    site_id,
                    guard_ids[index],
                    f"{names[index]} started a shift. Witness: {witness_name}. Equipment on.",
                    hours_ago,
                ),
            )

        conn.execute(
            "INSERT INTO post_assignments (post_id, guard_id, shift_id, started_at)"
            " VALUES (%s, %s, %s, now() - interval '170 minutes')",
            (post_ids[0], guard_ids[ON_POST], shift_ids[ON_POST]),
        )
        conn.execute(
            "INSERT INTO events (site_id, guard_id, post_id, event_type, detail, occurred_at)"
            " VALUES (%s, %s, %s, 'post_taken', %s, now() - interval '170 minutes')",
            (
                site_id,
                guard_ids[ON_POST],
                post_ids[0],
                f"{names[ON_POST]} took {site['posts'][0]}.",
            ),
        )

    first, last, badge, dob = REGIONAL_SUPERVISOR
    conn.execute(
        "INSERT INTO supervisors (site_id, first_name, last_name, badge, dob_hash) VALUES (NULL, %s, %s, %s, %s)",
        (first, last, badge, _dob_hash(dob)),
    )


def ensure_credentials(conn: psycopg.Connection) -> None:
    """Adds sign-in data to a database seeded before sign-in existed. The caller holds
    the setup lock and commits."""
    for site in SITES:
        for first, last, badge, dob in site["guards"]:
            conn.execute(
                "UPDATE guards SET dob_hash = %s WHERE badge = %s AND dob_hash IS NULL", (_dob_hash(dob), badge)
            )
        site_row = conn.execute("SELECT id FROM sites WHERE name = %s", (site["name"],)).fetchone()
        if site_row:
            first, last, badge, dob = site["supervisor"]
            conn.execute(
                "INSERT INTO supervisors (site_id, first_name, last_name, badge, dob_hash)"
                " VALUES (%s, %s, %s, %s, %s) ON CONFLICT (badge) DO NOTHING",
                (site_row["id"], first, last, badge, _dob_hash(dob)),
            )
    first, last, badge, dob = REGIONAL_SUPERVISOR
    conn.execute(
        "INSERT INTO supervisors (site_id, first_name, last_name, badge, dob_hash)"
        " VALUES (NULL, %s, %s, %s, %s) ON CONFLICT (badge) DO NOTHING",
        (first, last, badge, _dob_hash(dob)),
    )
