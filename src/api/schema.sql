-- Timekeeping schema. The API runs this file on startup inside an advisory lock.
-- Every statement is idempotent so a restart or a second worker changes nothing.
-- Timestamps are stored in UTC (timestamptz). Pages convert them to the site's time zone.

CREATE TABLE IF NOT EXISTS sites (
    id          integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name        text NOT NULL UNIQUE,
    time_zone   text NOT NULL
);

CREATE TABLE IF NOT EXISTS posts (
    id          integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    site_id     integer NOT NULL REFERENCES sites (id),
    name        text NOT NULL,
    UNIQUE (site_id, name)
);

CREATE TABLE IF NOT EXISTS guards (
    id          integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    site_id     integer NOT NULL REFERENCES sites (id),
    first_name  text NOT NULL,
    last_name   text NOT NULL,
    badge       text NOT NULL UNIQUE
);

CREATE TABLE IF NOT EXISTS shifts (
    id                integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    guard_id          integer NOT NULL REFERENCES guards (id),
    witness_guard_id  integer NOT NULL REFERENCES guards (id),
    started_at        timestamptz NOT NULL DEFAULT now(),
    equipment_on      boolean NOT NULL,
    ended_at          timestamptz,
    equipment_off     boolean,
    CONSTRAINT shifts_witness_is_other_guard CHECK (witness_guard_id <> guard_id)
);

CREATE TABLE IF NOT EXISTS post_assignments (
    id                       integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    post_id                  integer NOT NULL REFERENCES posts (id),
    guard_id                 integer NOT NULL REFERENCES guards (id),
    shift_id                 integer NOT NULL REFERENCES shifts (id),
    started_at               timestamptz NOT NULL DEFAULT now(),
    ended_at                 timestamptz,
    relieves_assignment_id   integer REFERENCES post_assignments (id)
);

CREATE TABLE IF NOT EXISTS events (
    id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    site_id             integer NOT NULL REFERENCES sites (id),
    guard_id            integer REFERENCES guards (id),
    post_id             integer REFERENCES posts (id),
    event_type          text NOT NULL,
    detail              text NOT NULL,
    occurred_at         timestamptz NOT NULL DEFAULT now(),
    -- Set when a guard signed for the action. The PNG lives in Blob Storage.
    signed_by_guard_id  integer REFERENCES guards (id),
    signature_blob      text
);

-- One open shift per guard, one open assignment per post and one per guard.
-- A violation becomes HTTP 409, which also stops double submissions.
CREATE UNIQUE INDEX IF NOT EXISTS ux_shifts_one_open_per_guard
    ON shifts (guard_id) WHERE ended_at IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS ux_assignments_one_open_per_post
    ON post_assignments (post_id) WHERE ended_at IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS ux_assignments_one_open_per_guard
    ON post_assignments (guard_id) WHERE ended_at IS NULL;

CREATE INDEX IF NOT EXISTS ix_events_site_time
    ON events (site_id, occurred_at DESC);
