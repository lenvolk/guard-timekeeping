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

-- Sign-in. The date of birth is never stored, only a salted PBKDF2 hash of it.
-- Five wrong tries lock the account for five minutes.
ALTER TABLE guards ADD COLUMN IF NOT EXISTS dob_hash text;
ALTER TABLE guards ADD COLUMN IF NOT EXISTS failed_logins integer NOT NULL DEFAULT 0;
ALTER TABLE guards ADD COLUMN IF NOT EXISTS locked_until timestamptz;

-- A supervisor with no site is regional and sees every site.
CREATE TABLE IF NOT EXISTS supervisors (
    id             integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    site_id        integer REFERENCES sites (id),
    first_name     text NOT NULL,
    last_name      text NOT NULL,
    badge          text NOT NULL UNIQUE,
    dob_hash       text NOT NULL,
    failed_logins  integer NOT NULL DEFAULT 0,
    locked_until   timestamptz
);

-- Binds each signature to its event: the PNG's SHA-256 and who was signed in.
-- The meaning is the 21 CFR 11.50 "meaning of the signature", such as responsibility.
ALTER TABLE events ADD COLUMN IF NOT EXISTS signature_sha256 text;
ALTER TABLE events ADD COLUMN IF NOT EXISTS signature_meaning text;
ALTER TABLE events ADD COLUMN IF NOT EXISTS recorded_by text;

-- A break hands the post to a cover guard and gives it back on return.
CREATE TABLE IF NOT EXISTS breaks (
    id                      integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    guard_id                integer NOT NULL REFERENCES guards (id),
    shift_id                integer NOT NULL REFERENCES shifts (id),
    post_id                 integer NOT NULL REFERENCES posts (id),
    cover_guard_id          integer NOT NULL REFERENCES guards (id),
    break_type              text NOT NULL CHECK (break_type IN ('lunch', 'restroom')),
    started_at              timestamptz NOT NULL DEFAULT now(),
    due_at                  timestamptz NOT NULL,
    ended_at                timestamptz,
    original_assignment_id  integer NOT NULL REFERENCES post_assignments (id),
    cover_assignment_id     integer NOT NULL REFERENCES post_assignments (id),
    CONSTRAINT breaks_cover_is_other_guard CHECK (cover_guard_id <> guard_id)
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_breaks_one_open_per_guard
    ON breaks (guard_id) WHERE ended_at IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS ux_breaks_one_open_per_cover
    ON breaks (cover_guard_id) WHERE ended_at IS NULL;

-- Corrections never change an event. Each one is a request with a reason, and a
-- supervisor approves or rejects it. The latest approved time is the effective time.
CREATE TABLE IF NOT EXISTS adjustments (
    id                        integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    event_id                  bigint NOT NULL REFERENCES events (id),
    requested_by_guard_id     integer NOT NULL REFERENCES guards (id),
    requested_at              timestamptz NOT NULL DEFAULT now(),
    original_occurred_at      timestamptz NOT NULL,
    proposed_occurred_at      timestamptz NOT NULL,
    reason                    text NOT NULL CHECK (length(btrim(reason)) >= 5),
    status                    text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'rejected')),
    decided_by_supervisor_id  integer REFERENCES supervisors (id),
    decided_at                timestamptz,
    decision_note             text
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_adjustments_one_pending_per_event
    ON adjustments (event_id) WHERE status = 'pending';
