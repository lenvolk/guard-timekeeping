"""Synthetic seed data. Every site, post and person here is made up."""

from __future__ import annotations

import psycopg

SITES = [
    {
        "name": "Riverside Office Park",
        "time_zone": "America/New_York",
        "posts": ["Main Gate", "Lobby Desk"],
        "guards": [
            ("Jordan", "Avila", "G-1001"),
            ("Priya", "Hollis", "G-1002"),
            ("Marcus", "Ferrin", "G-1003"),
            ("Elena", "Brandt", "G-1004"),
            ("Tomas", "Reyna", "G-1005"),
            ("Grace", "Okafor", "G-1006"),
        ],
    },
    {
        "name": "Lakeshore Distribution Center",
        "time_zone": "America/Chicago",
        "posts": ["North Dock Gate", "Control Room"],
        "guards": [
            ("Dana", "Whitlock", "G-2001"),
            ("Samuel", "Ortiz-Lane", "G-2002"),
            ("Keisha", "Morrow", "G-2003"),
            ("Victor", "Lindqvist", "G-2004"),
            ("Hannah", "Prescott", "G-2005"),
            ("Omar", "Castellano", "G-2006"),
        ],
    },
]

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
        for first, last, badge in site["guards"]:
            guard_ids.append(
                conn.execute(
                    "INSERT INTO guards (site_id, first_name, last_name, badge)"
                    " VALUES (%s, %s, %s, %s) RETURNING id",
                    (site_id, first, last, badge),
                ).fetchone()["id"]
            )
            names.append(f"{first} {last}")

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
