PRAGMA foreign_keys = ON;

CREATE TABLE schema_migrations (
    version INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    sha256 TEXT NOT NULL,
    applied_at TEXT NOT NULL
) STRICT;

CREATE TABLE sync_runs (
    id INTEGER PRIMARY KEY,
    source_repo TEXT NOT NULL,
    target_repo TEXT NOT NULL,
    mode TEXT NOT NULL CHECK (mode IN ('snapshot', 'sync')),
    status TEXT NOT NULL CHECK (status IN ('running', 'completed', 'failed', 'interrupted')),
    started_at TEXT NOT NULL,
    finished_at TEXT,
    snapshot_sha256 TEXT,
    entity_count INTEGER NOT NULL DEFAULT 0 CHECK (entity_count >= 0),
    version_count INTEGER NOT NULL DEFAULT 0 CHECK (version_count >= 0),
    changed_entity_count INTEGER NOT NULL DEFAULT 0 CHECK (changed_entity_count >= 0),
    action_count INTEGER NOT NULL DEFAULT 0 CHECK (action_count >= 0),
    error TEXT
) STRICT;

CREATE INDEX sync_runs_started_idx ON sync_runs(started_at DESC);
CREATE INDEX sync_runs_running_idx ON sync_runs(started_at) WHERE status = 'running';

CREATE TABLE entity_versions (
    id INTEGER PRIMARY KEY,
    entity_key TEXT NOT NULL,
    entity_kind TEXT NOT NULL,
    source_id TEXT NOT NULL,
    source_index INTEGER,
    parent_key TEXT,
    content_sha256 TEXT NOT NULL CHECK (length(content_sha256) = 64),
    payload_json TEXT NOT NULL CHECK (json_valid(payload_json)),
    payload_bytes INTEGER NOT NULL CHECK (payload_bytes >= 0),
    first_observed_run_id INTEGER NOT NULL REFERENCES sync_runs(id),
    first_observed_at TEXT NOT NULL,
    UNIQUE(entity_key, content_sha256)
) STRICT;

CREATE INDEX entity_versions_history_idx
    ON entity_versions(entity_key, first_observed_at DESC, id DESC);
CREATE INDEX entity_versions_kind_index_idx
    ON entity_versions(entity_kind, source_index, first_observed_at DESC);

CREATE TABLE entity_observations (
    id INTEGER PRIMARY KEY,
    run_id INTEGER NOT NULL REFERENCES sync_runs(id),
    version_id INTEGER NOT NULL REFERENCES entity_versions(id),
    entity_key TEXT NOT NULL,
    observed_at TEXT NOT NULL,
    is_change INTEGER NOT NULL CHECK (is_change IN (0, 1)),
    is_present INTEGER NOT NULL CHECK (is_present IN (0, 1)),
    UNIQUE(run_id, entity_key)
) STRICT;

CREATE INDEX entity_observations_version_idx
    ON entity_observations(version_id, observed_at DESC);
CREATE INDEX entity_observations_run_idx
    ON entity_observations(run_id, entity_key);

CREATE TABLE entity_heads (
    entity_key TEXT PRIMARY KEY,
    entity_kind TEXT NOT NULL,
    source_id TEXT NOT NULL,
    source_index INTEGER,
    parent_key TEXT,
    version_id INTEGER NOT NULL REFERENCES entity_versions(id),
    run_id INTEGER NOT NULL REFERENCES sync_runs(id),
    content_sha256 TEXT NOT NULL CHECK (length(content_sha256) = 64),
    is_present INTEGER NOT NULL CHECK (is_present IN (0, 1)),
    first_observed_at TEXT NOT NULL,
    last_observed_at TEXT NOT NULL,
    missing_runs INTEGER NOT NULL DEFAULT 0 CHECK (missing_runs >= 0)
) STRICT;

CREATE INDEX entity_heads_kind_index_idx
    ON entity_heads(entity_kind, source_index);
CREATE INDEX entity_heads_missing_idx
    ON entity_heads(missing_runs, entity_kind) WHERE is_present = 1;

CREATE TABLE target_mappings (
    entity_key TEXT PRIMARY KEY,
    source_kind TEXT NOT NULL,
    source_index INTEGER,
    target_kind TEXT NOT NULL,
    target_number INTEGER,
    target_id TEXT,
    target_url TEXT,
    last_synced_sha256 TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
) STRICT;

CREATE INDEX target_mappings_target_idx
    ON target_mappings(target_kind, target_number, target_id);

CREATE TABLE action_events (
    id INTEGER PRIMARY KEY,
    run_id INTEGER NOT NULL REFERENCES sync_runs(id),
    sequence INTEGER NOT NULL,
    event TEXT NOT NULL CHECK (event IN ('planned', 'succeeded', 'failed', 'skipped')),
    action TEXT NOT NULL,
    entity_key TEXT,
    target_kind TEXT,
    target_number INTEGER,
    request_sha256 TEXT,
    details_json TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(details_json)),
    recorded_at TEXT NOT NULL,
    UNIQUE(run_id, sequence)
) STRICT;

CREATE INDEX action_events_entity_idx
    ON action_events(entity_key, recorded_at DESC);
CREATE INDEX action_events_run_idx
    ON action_events(run_id, sequence);

CREATE VIEW entity_history AS
SELECT
    v.entity_key,
    v.entity_kind,
    v.source_id,
    v.source_index,
    v.parent_key,
    o.observed_at,
    o.is_change,
    o.is_present,
    o.run_id,
    v.content_sha256,
    json(v.payload_json) AS payload
FROM entity_observations AS o
JOIN entity_versions AS v ON v.id = o.version_id;

CREATE TRIGGER entity_versions_no_update
BEFORE UPDATE ON entity_versions BEGIN
    SELECT RAISE(ABORT, 'entity_versions is append-only');
END;

CREATE TRIGGER entity_versions_no_delete
BEFORE DELETE ON entity_versions BEGIN
    SELECT RAISE(ABORT, 'entity_versions is append-only');
END;

CREATE TRIGGER entity_observations_no_update
BEFORE UPDATE ON entity_observations BEGIN
    SELECT RAISE(ABORT, 'entity_observations is append-only');
END;

CREATE TRIGGER entity_observations_no_delete
BEFORE DELETE ON entity_observations BEGIN
    SELECT RAISE(ABORT, 'entity_observations is append-only');
END;

CREATE TRIGGER action_events_no_update
BEFORE UPDATE ON action_events BEGIN
    SELECT RAISE(ABORT, 'action_events is append-only');
END;

CREATE TRIGGER action_events_no_delete
BEFORE DELETE ON action_events BEGIN
    SELECT RAISE(ABORT, 'action_events is append-only');
END;
