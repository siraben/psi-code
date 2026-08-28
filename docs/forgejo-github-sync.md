# Forgejo-to-GitHub synchronization

`siraben/psi-coding-agent` on Forgejo is authoritative. The GitHub repository
`siraben/psi-code` is a one-way publication target; changes made only on GitHub
are not imported into Forgejo.

The daily job performs a complete Forgejo read rather than an incremental
GitHub refresh. It hydrates every issue, pull request, ordinary comment,
timeline event, review, review comment, branch, tag, release, label, and
milestone from Forgejo. Git refs are force-updated on GitHub from Forgejo-owned
refs. GitHub-only refs are retained because deleting them would destroy legacy
history that is not present in Forgejo.

## Audit ledger

The SQLite ledger uses three layers:

- `entity_versions` stores one canonical JSON payload for each distinct
  SHA-256 version of a Forgejo entity.
- `entity_observations` records every completed full scan, including unchanged
  entities and explicit tombstones for entities removed from Forgejo.
- `entity_heads` provides constant-time current-version lookup without
  duplicating payloads.

`action_events` records target operations as append-only planned, succeeded,
failed, or skipped events. `target_mappings` relates stable Forgejo IDs to the
different issue and PR numbers assigned by GitHub. Database triggers reject
updates and deletes of versions, observations, and action events.

The hot ledger lives at
`~/.local/state/psi-code-forgejo-sync/audit.sqlite3`, avoiding synchronous WAL
latency on the external Btrfs volume. Every successful run creates an atomic
gzip backup and SHA-256 sidecar under
`/mnt/siraben-ext/forgejo-github-sync/backups/`; no automatic retention deletes
old backups.

Useful queries:

```sql
-- All revisions of Forgejo issue #111.
SELECT observed_at, is_change, is_present, content_sha256, payload
FROM entity_history
WHERE entity_kind = 'issue' AND source_index = 111
ORDER BY observed_at;

-- Deleted comments whose prior text remains recoverable.
SELECT h.entity_key, h.last_observed_at, v.payload_json AS tombstone
FROM entity_heads h
JOIN entity_versions v ON v.id = h.version_id
WHERE h.entity_kind IN ('issue_comment', 'pull_comment', 'pull_review_comment')
  AND h.is_present = 0;

-- Exact target-side actions from a run.
SELECT sequence, event, action, entity_key, details_json
FROM action_events
WHERE run_id = ?
ORDER BY sequence;
```

## Commands

```sh
# Apply ledger migrations only.
python scripts/forgejo_github_sync.py migrate

# Audit Forgejo without reading or writing GitHub.
python scripts/forgejo_github_sync.py snapshot

# One-time target read after importing existing issues and PRs.
python scripts/forgejo_github_sync.py bootstrap

# Full source snapshot, ref push, and metadata synchronization.
python scripts/forgejo_github_sync.py sync

# Print the latest run as canonical JSON.
python scripts/forgejo_github_sync.py status
```

The normal daily command does not use GitHub as an ingestion source. A target
read is only used by the explicit one-time `bootstrap` command to discover
pre-existing migration mappings. Subsequent runs use the audited local mapping
table and target mutation responses.

Install the user units after creating the external state directory:

```sh
mkdir -p /mnt/siraben-ext/forgejo-github-sync/backups
install -Dm0644 systemd/user/psi-code-forgejo-sync.service \
  ~/.config/systemd/user/psi-code-forgejo-sync.service
install -Dm0644 systemd/user/psi-code-forgejo-sync.timer \
  ~/.config/systemd/user/psi-code-forgejo-sync.timer
systemctl --user daemon-reload
systemctl --user enable --now psi-code-forgejo-sync.timer
```
