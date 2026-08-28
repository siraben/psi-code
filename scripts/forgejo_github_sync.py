#!/usr/bin/env python3
"""Audit Forgejo and synchronize its current state one-way to GitHub.

Forgejo is always the source of truth. GitHub is only a publication target.
Every source snapshot and target mutation is recorded in an append-only SQLite
ledger before the target is changed.
"""

from __future__ import annotations

import argparse
import copy
import concurrent.futures
import dataclasses
import datetime as dt
import fcntl
import gzip
import hashlib
import json
import os
import pathlib
import re
import signal
import sqlite3
import subprocess
import sys
from collections.abc import Sequence
from typing import Any

PAGE_SIZE = 50
ISSUE_MARKER = re.compile(
    r"(?:Imported from Forgejo issue #|forgejo-sync:issue:[^:\s>]+:)(\d+)",
    re.IGNORECASE,
)
PULL_MARKER = re.compile(
    r"(?:Imported from Forgejo PR #|forgejo-sync:pull:[^:\s>]+:)(\d+)",
    re.IGNORECASE,
)
PULL_REPLACEMENT_MARKER = re.compile(
    r"Replacement for Forgejo PR #(\d+)", re.IGNORECASE
)
COMMENT_MARKER = re.compile(r"forgejo-sync:comment:(\d+)")


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="microseconds")


def canonical_json(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def sha256_text(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def run_command(
    argv: Sequence[str],
    *,
    input_text: str | None = None,
    cwd: pathlib.Path | None = None,
) -> str:
    completed = subprocess.run(
        list(argv),
        input=input_text,
        text=True,
        capture_output=True,
        cwd=cwd,
        check=False,
    )
    if completed.returncode != 0:
        stderr = completed.stderr.strip()
        raise RuntimeError(
            f"command failed ({completed.returncode}): {argv[0]}: {stderr}"
        )
    return completed.stdout


class ForgejoClient:
    def __init__(self, repo: str, login: str) -> None:
        self.repo = repo
        self.login = login

    def get(self, endpoint: str) -> Any:
        output = run_command(["tea", "api", endpoint, "--login", self.login])
        return json.loads(output)

    def pages(self, endpoint: str) -> list[Any]:
        separator = "&" if "?" in endpoint else "?"
        result: list[Any] = []
        for page in range(1, 100_000):
            batch = self.get(f"{endpoint}{separator}limit={PAGE_SIZE}&page={page}")
            # Forgejo serializes empty timeline/review collections as JSON null.
            if batch is None:
                return result
            if not isinstance(batch, list):
                raise TypeError(f"expected an array from Forgejo endpoint {endpoint}")
            result.extend(batch)
            if len(batch) < PAGE_SIZE:
                return result
        raise RuntimeError(f"Forgejo pagination did not terminate for {endpoint}")

    def repo_path(self, suffix: str = "") -> str:
        return f"/repos/{self.repo}{suffix}"


class GitHubClient:
    def __init__(self, repo: str) -> None:
        self.repo = repo

    def request(self, method: str, path: str, payload: Any | None = None) -> Any:
        argv = ["gh", "api", "--method", method, path]
        input_text = None
        if payload is not None:
            argv.extend(["--input", "-"])
            input_text = canonical_json(payload)
        output = run_command(argv, input_text=input_text)
        return json.loads(output) if output.strip() else None

    def pages(self, path: str) -> list[Any]:
        separator = "&" if "?" in path else "?"
        result: list[Any] = []
        for page in range(1, 100_000):
            batch = self.request(
                "GET", f"{path}{separator}per_page={PAGE_SIZE}&page={page}"
            )
            if not isinstance(batch, list):
                raise TypeError(f"expected an array from GitHub endpoint {path}")
            result.extend(batch)
            if len(batch) < PAGE_SIZE:
                return result
        raise RuntimeError(f"GitHub pagination did not terminate for {path}")

    def repo_path(self, suffix: str = "") -> str:
        return f"repos/{self.repo}{suffix}"


@dataclasses.dataclass(frozen=True)
class EntitySnapshot:
    key: str
    kind: str
    source_id: str
    source_index: int | None
    parent_key: str | None
    payload: Any

    @property
    def payload_json(self) -> str:
        return canonical_json(self.payload)

    @property
    def content_sha256(self) -> str:
        return sha256_text(self.payload_json)


def entity(
    kind: str,
    source_id: str | int,
    payload: Any,
    *,
    source_index: int | None = None,
    parent_key: str | None = None,
) -> EntitySnapshot:
    source_id_text = str(source_id)
    return EntitySnapshot(
        key=f"{kind}:{source_id_text}",
        kind=kind,
        source_id=source_id_text,
        source_index=source_index,
        parent_key=parent_key,
        payload=payload,
    )


def stable_event_id(payload: dict[str, Any]) -> str:
    if payload.get("id") is not None:
        return str(payload["id"])
    identity = {
        key: payload.get(key)
        for key in (
            "type",
            "created_at",
            "updated_at",
            "sha",
            "ref",
            "new_ref",
            "old_ref",
        )
    }
    user = payload.get("user") or payload.get("actor")
    if isinstance(user, dict):
        identity["user"] = user.get("id") or user.get("login")
    return sha256_text(canonical_json(identity))


def normalize_pull_payload(payload: dict[str, Any]) -> dict[str, Any]:
    """Remove duplicated volatile repository expansions from a PR payload.

    Forgejo embeds the complete repository object under both base and head.
    Repository size and updated_at changes would otherwise manufacture two
    changes in every PR; the complete repository is already its own entity.
    """
    normalized = copy.deepcopy(payload)
    stable_repo_fields = (
        "id",
        "full_name",
        "html_url",
        "default_branch",
        "object_format_name",
    )
    for side in ("base", "head"):
        reference = normalized.get(side)
        if not isinstance(reference, dict) or not isinstance(
            reference.get("repo"), dict
        ):
            continue
        repository = reference["repo"]
        reference["repo"] = {
            key: repository.get(key) for key in stable_repo_fields if key in repository
        }
    return normalized


def add_unique(destination: dict[str, EntitySnapshot], item: EntitySnapshot) -> None:
    previous = destination.get(item.key)
    if previous is not None and previous.content_sha256 != item.content_sha256:
        raise RuntimeError(f"source returned conflicting payloads for {item.key}")
    destination[item.key] = item


def hydrate_issue(
    client: ForgejoClient, summary: dict[str, Any]
) -> list[EntitySnapshot]:
    number = int(summary["number"])
    detail = client.get(client.repo_path(f"/issues/{number}"))
    issue = entity("issue", detail["id"], detail, source_index=number)
    result = [issue]
    for comment in client.pages(client.repo_path(f"/issues/{number}/comments?")):
        result.append(
            entity(
                "issue_comment",
                comment["id"],
                comment,
                source_index=number,
                parent_key=issue.key,
            )
        )
    for event_payload in client.pages(client.repo_path(f"/issues/{number}/timeline?")):
        result.append(
            entity(
                "issue_timeline",
                f"{detail['id']}:{stable_event_id(event_payload)}",
                event_payload,
                source_index=number,
                parent_key=issue.key,
            )
        )
    return result


def hydrate_pull(
    client: ForgejoClient, summary: dict[str, Any]
) -> list[EntitySnapshot]:
    number = int(summary["number"])
    detail = normalize_pull_payload(client.get(client.repo_path(f"/pulls/{number}")))
    pull = entity("pull", detail["id"], detail, source_index=number)
    result = [pull]
    for comment in client.pages(client.repo_path(f"/issues/{number}/comments?")):
        result.append(
            entity(
                "pull_comment",
                comment["id"],
                comment,
                source_index=number,
                parent_key=pull.key,
            )
        )
    for event_payload in client.pages(client.repo_path(f"/issues/{number}/timeline?")):
        result.append(
            entity(
                "pull_timeline",
                f"{detail['id']}:{stable_event_id(event_payload)}",
                event_payload,
                source_index=number,
                parent_key=pull.key,
            )
        )
    reviews = client.pages(client.repo_path(f"/pulls/{number}/reviews?"))
    for review_payload in reviews:
        review = entity(
            "pull_review",
            review_payload["id"],
            review_payload,
            source_index=number,
            parent_key=pull.key,
        )
        result.append(review)
        for comment in client.pages(
            client.repo_path(
                f"/pulls/{number}/reviews/{review_payload['id']}/comments?"
            )
        ):
            result.append(
                entity(
                    "pull_review_comment",
                    comment["id"],
                    comment,
                    source_index=number,
                    parent_key=review.key,
                )
            )
    return result


def collect_source(client: ForgejoClient, workers: int) -> dict[str, EntitySnapshot]:
    snapshots: dict[str, EntitySnapshot] = {}
    repository = client.get(client.repo_path())
    add_unique(snapshots, entity("repository", repository["id"], repository))

    collection_endpoints = (
        ("label", "/labels?", "id", None),
        ("milestone", "/milestones?state=all&", "id", "id"),
        ("release", "/releases?", "id", "id"),
        ("branch", "/branches?", "name", None),
        ("tag", "/tags?", "name", None),
    )
    for kind, suffix, id_field, index_field in collection_endpoints:
        for payload in client.pages(client.repo_path(suffix)):
            source_index = (
                int(payload[index_field])
                if index_field and payload.get(index_field)
                else None
            )
            add_unique(
                snapshots,
                entity(kind, payload[id_field], payload, source_index=source_index),
            )

    issues = client.pages(client.repo_path("/issues?state=all&type=issues&"))
    pulls = client.pages(client.repo_path("/pulls?state=all&"))
    jobs: list[tuple[Any, dict[str, Any]]] = [
        *((hydrate_issue, item) for item in issues),
        *((hydrate_pull, item) for item in pulls),
    ]
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as executor:
        futures = [
            executor.submit(function, client, summary) for function, summary in jobs
        ]
        for future in concurrent.futures.as_completed(futures):
            for snapshot in future.result():
                add_unique(snapshots, snapshot)
    return snapshots


class AuditDatabase:
    def __init__(self, path: pathlib.Path, migrations_dir: pathlib.Path) -> None:
        self.path = path
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.connection = sqlite3.connect(path)
        self.connection.row_factory = sqlite3.Row
        self.connection.execute("PRAGMA foreign_keys = ON")
        self.connection.execute("PRAGMA journal_mode = WAL")
        self.connection.execute("PRAGMA synchronous = FULL")
        self.connection.execute("PRAGMA busy_timeout = 30000")
        self.apply_migrations(migrations_dir)
        os.chmod(path, 0o600)

    def close(self) -> None:
        self.connection.close()

    def apply_migrations(self, migrations_dir: pathlib.Path) -> None:
        migrations: list[tuple[int, pathlib.Path]] = []
        for path in migrations_dir.glob("V*__*.sql"):
            match = re.fullmatch(r"V(\d+)__(.+)\.sql", path.name)
            if match:
                migrations.append((int(match.group(1)), path))
        migrations.sort()
        try:
            applied = {
                int(row["version"]): row
                for row in self.connection.execute(
                    "SELECT version, name, sha256 FROM schema_migrations"
                )
            }
        except sqlite3.OperationalError as error:
            if "no such table" not in str(error):
                raise
            applied = {}
        for version, path in migrations:
            sql = path.read_text(encoding="utf-8")
            digest = sha256_text(sql)
            if version in applied:
                if applied[version]["sha256"] != digest:
                    raise RuntimeError(
                        f"applied migration V{version} checksum differs from {path}"
                    )
                continue
            self.connection.executescript(sql)
            self.connection.execute(
                "INSERT INTO schema_migrations(version, name, sha256, applied_at) VALUES (?, ?, ?, ?)",
                (version, path.name, digest, utc_now()),
            )
            self.connection.commit()

    def interrupt_stale_runs(self) -> None:
        self.connection.execute(
            "UPDATE sync_runs SET status='interrupted', finished_at=?, "
            "error=COALESCE(error, 'superseded by a later invocation') WHERE status='running'",
            (utc_now(),),
        )
        self.connection.commit()

    def start_run(self, source_repo: str, target_repo: str, mode: str) -> int:
        self.interrupt_stale_runs()
        cursor = self.connection.execute(
            "INSERT INTO sync_runs(source_repo, target_repo, mode, status, started_at) "
            "VALUES (?, ?, ?, 'running', ?)",
            (source_repo, target_repo, mode, utc_now()),
        )
        self.connection.commit()
        return int(cursor.lastrowid)

    def finish_run(self, run_id: int, status: str, error: str | None = None) -> None:
        action_count = self.connection.execute(
            "SELECT count(*) FROM action_events WHERE run_id=? AND event='planned'",
            (run_id,),
        ).fetchone()[0]
        self.connection.execute(
            "UPDATE sync_runs SET status=?, finished_at=?, action_count=?, error=? WHERE id=?",
            (status, utc_now(), action_count, error, run_id),
        )
        self.connection.commit()

    def record_snapshot(
        self, run_id: int, snapshots: dict[str, EntitySnapshot]
    ) -> None:
        observed_at = utc_now()
        manifest = canonical_json(
            [[key, snapshots[key].content_sha256] for key in sorted(snapshots)]
        )
        version_count = 0
        changed_count = 0
        current_keys = set(snapshots)
        with self.connection:
            for key in sorted(snapshots):
                snapshot = snapshots[key]
                version_id, inserted, changed = self._record_entity(
                    run_id, snapshot, observed_at, is_present=True
                )
                del version_id
                version_count += int(inserted)
                changed_count += int(changed)

            rows = self.connection.execute(
                "SELECT * FROM entity_heads WHERE is_present=1"
            ).fetchall()
            for head in rows:
                if head["entity_key"] in current_keys:
                    continue
                tombstone = entity(
                    head["entity_kind"],
                    head["source_id"],
                    {
                        "deleted": True,
                        "last_content_sha256": head["content_sha256"],
                        "detected_at": observed_at,
                    },
                    source_index=head["source_index"],
                    parent_key=head["parent_key"],
                )
                _, inserted, changed = self._record_entity(
                    run_id, tombstone, observed_at, is_present=False
                )
                version_count += int(inserted)
                changed_count += int(changed)

            absent_rows = self.connection.execute(
                "SELECT * FROM entity_heads WHERE is_present=0 AND run_id<>?", (run_id,)
            ).fetchall()
            for head in absent_rows:
                version_id = int(head["version_id"])
                self.connection.execute(
                    "INSERT INTO entity_observations"
                    "(run_id, version_id, entity_key, observed_at, is_change, is_present) "
                    "VALUES (?, ?, ?, ?, 0, 0)",
                    (run_id, version_id, head["entity_key"], observed_at),
                )
                self.connection.execute(
                    "UPDATE entity_heads SET run_id=?, last_observed_at=?, missing_runs=missing_runs+1 "
                    "WHERE entity_key=?",
                    (run_id, observed_at, head["entity_key"]),
                )

            entity_count = self.connection.execute(
                "SELECT count(*) FROM entity_observations WHERE run_id=?", (run_id,)
            ).fetchone()[0]
            self.connection.execute(
                "UPDATE sync_runs SET snapshot_sha256=?, entity_count=?, version_count=?, "
                "changed_entity_count=? WHERE id=?",
                (
                    sha256_text(manifest),
                    entity_count,
                    version_count,
                    changed_count,
                    run_id,
                ),
            )

    def _record_entity(
        self,
        run_id: int,
        snapshot: EntitySnapshot,
        observed_at: str,
        *,
        is_present: bool,
    ) -> tuple[int, bool, bool]:
        payload_json = snapshot.payload_json
        digest = snapshot.content_sha256
        prior = self.connection.execute(
            "SELECT version_id, content_sha256, is_present, first_observed_at "
            "FROM entity_heads WHERE entity_key=?",
            (snapshot.key,),
        ).fetchone()
        cursor = self.connection.execute(
            "INSERT OR IGNORE INTO entity_versions"
            "(entity_key, entity_kind, source_id, source_index, parent_key, content_sha256, "
            "payload_json, payload_bytes, first_observed_run_id, first_observed_at) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (
                snapshot.key,
                snapshot.kind,
                snapshot.source_id,
                snapshot.source_index,
                snapshot.parent_key,
                digest,
                payload_json,
                len(payload_json.encode("utf-8")),
                run_id,
                observed_at,
            ),
        )
        inserted = cursor.rowcount == 1
        version_id = int(
            self.connection.execute(
                "SELECT id FROM entity_versions WHERE entity_key=? AND content_sha256=?",
                (snapshot.key, digest),
            ).fetchone()[0]
        )
        changed = prior is not None and (
            prior["content_sha256"] != digest or bool(prior["is_present"]) != is_present
        )
        self.connection.execute(
            "INSERT INTO entity_observations"
            "(run_id, version_id, entity_key, observed_at, is_change, is_present) "
            "VALUES (?, ?, ?, ?, ?, ?)",
            (
                run_id,
                version_id,
                snapshot.key,
                observed_at,
                int(changed),
                int(is_present),
            ),
        )
        first_observed_at = prior["first_observed_at"] if prior else observed_at
        self.connection.execute(
            "INSERT INTO entity_heads"
            "(entity_key, entity_kind, source_id, source_index, parent_key, version_id, run_id, "
            "content_sha256, is_present, first_observed_at, last_observed_at, missing_runs) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) "
            "ON CONFLICT(entity_key) DO UPDATE SET "
            "entity_kind=excluded.entity_kind, source_id=excluded.source_id, "
            "source_index=excluded.source_index, parent_key=excluded.parent_key, "
            "version_id=excluded.version_id, run_id=excluded.run_id, "
            "content_sha256=excluded.content_sha256, is_present=excluded.is_present, "
            "last_observed_at=excluded.last_observed_at, "
            "missing_runs=CASE WHEN excluded.is_present=1 THEN 0 ELSE entity_heads.missing_runs+1 END",
            (
                snapshot.key,
                snapshot.kind,
                snapshot.source_id,
                snapshot.source_index,
                snapshot.parent_key,
                version_id,
                run_id,
                digest,
                int(is_present),
                first_observed_at,
                observed_at,
                0 if is_present else 1,
            ),
        )
        return version_id, inserted, changed

    def heads(self, kind: str, *, present: bool = True) -> list[sqlite3.Row]:
        return self.connection.execute(
            "SELECT h.*, v.payload_json FROM entity_heads h "
            "JOIN entity_versions v ON v.id=h.version_id "
            "WHERE h.entity_kind=? AND h.is_present=? "
            "ORDER BY h.source_index, h.source_id",
            (kind, int(present)),
        ).fetchall()

    def children(self, parent_key: str, kind: str) -> list[sqlite3.Row]:
        return self.connection.execute(
            "SELECT h.*, v.payload_json FROM entity_heads h "
            "JOIN entity_versions v ON v.id=h.version_id "
            "WHERE h.parent_key=? AND h.entity_kind=? AND h.is_present=1 "
            "ORDER BY h.source_id",
            (parent_key, kind),
        ).fetchall()

    def mapping(self, entity_key: str) -> sqlite3.Row | None:
        return self.connection.execute(
            "SELECT * FROM target_mappings WHERE entity_key=?", (entity_key,)
        ).fetchone()

    def save_mapping(
        self,
        entity_key: str,
        source_kind: str,
        source_index: int | None,
        target_kind: str,
        *,
        target_number: int | None = None,
        target_id: str | int | None = None,
        target_url: str | None = None,
        synced_sha256: str | None = None,
    ) -> None:
        now = utc_now()
        self.connection.execute(
            "INSERT INTO target_mappings"
            "(entity_key, source_kind, source_index, target_kind, target_number, target_id, "
            "target_url, last_synced_sha256, created_at, updated_at) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) "
            "ON CONFLICT(entity_key) DO UPDATE SET target_kind=excluded.target_kind, "
            "target_number=COALESCE(excluded.target_number, target_mappings.target_number), "
            "target_id=COALESCE(excluded.target_id, target_mappings.target_id), "
            "target_url=COALESCE(excluded.target_url, target_mappings.target_url), "
            "last_synced_sha256=COALESCE(excluded.last_synced_sha256, target_mappings.last_synced_sha256), "
            "updated_at=excluded.updated_at",
            (
                entity_key,
                source_kind,
                source_index,
                target_kind,
                target_number,
                str(target_id) if target_id is not None else None,
                target_url,
                synced_sha256,
                now,
                now,
            ),
        )
        self.connection.commit()

    def latest_run(self) -> sqlite3.Row | None:
        return self.connection.execute(
            "SELECT * FROM sync_runs ORDER BY id DESC LIMIT 1"
        ).fetchone()

    def backup(self, backup_dir: pathlib.Path) -> pathlib.Path:
        backup_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        destination = backup_dir / f"audit-{stamp}.sqlite3.gz"
        temporary_database = backup_dir / f".{destination.stem}.{os.getpid()}.sqlite3"
        temporary_gzip = destination.with_name(f".{destination.name}.{os.getpid()}.tmp")
        backup_connection = sqlite3.connect(temporary_database)
        try:
            self.connection.backup(backup_connection)
        finally:
            backup_connection.close()
        try:
            with (
                temporary_database.open("rb") as source,
                gzip.open(temporary_gzip, "wb", 6) as target,
            ):
                while chunk := source.read(1024 * 1024):
                    target.write(chunk)
            os.replace(temporary_gzip, destination)
            digest = hashlib.sha256(destination.read_bytes()).hexdigest()
            checksum = destination.with_suffix(destination.suffix + ".sha256")
            checksum.write_text(f"{digest}  {destination.name}\n", encoding="utf-8")
            os.chmod(destination, 0o600)
            os.chmod(checksum, 0o600)
        finally:
            temporary_database.unlink(missing_ok=True)
            temporary_gzip.unlink(missing_ok=True)
        return destination


class ActionLog:
    def __init__(self, database: AuditDatabase, run_id: int) -> None:
        self.database = database
        self.run_id = run_id
        self.sequence = int(
            database.connection.execute(
                "SELECT COALESCE(max(sequence), 0) FROM action_events WHERE run_id=?",
                (run_id,),
            ).fetchone()[0]
        )

    def record(
        self,
        event: str,
        action: str,
        *,
        entity_key: str | None = None,
        target_kind: str | None = None,
        target_number: int | None = None,
        request_sha256: str | None = None,
        details: Any | None = None,
    ) -> None:
        self.sequence += 1
        self.database.connection.execute(
            "INSERT INTO action_events"
            "(run_id, sequence, event, action, entity_key, target_kind, target_number, "
            "request_sha256, details_json, recorded_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (
                self.run_id,
                self.sequence,
                event,
                action,
                entity_key,
                target_kind,
                target_number,
                request_sha256,
                canonical_json(details or {}),
                utc_now(),
            ),
        )
        self.database.connection.commit()


def provenance(kind: str, number: int, source_repo: str, source_url: str) -> str:
    display = "PR" if kind == "pull" else "issue"
    return (
        f"\n\n---\nMirrored one-way from authoritative Forgejo {display} #{number}.\n\n"
        f"Source: {source_url}\n\n"
        f"<!-- forgejo-sync:{kind}:{source_repo}:{number} -->"
    )


def comment_body(payload: dict[str, Any], source_repo: str) -> str:
    author = (payload.get("user") or {}).get("login") or "unknown"
    created = payload.get("created_at") or "unknown"
    return (
        f"{payload.get('body') or ''}\n\n---\n"
        f"Mirrored from Forgejo comment by @{author}, created {created}.\n"
        f"<!-- forgejo-sync:comment:{payload['id']}:{source_repo} -->"
    )


def desired_issue(payload: dict[str, Any], source_repo: str) -> dict[str, Any]:
    labels = [
        label["name"] for label in payload.get("labels") or [] if label.get("name")
    ]
    if "forgejo-sync" not in labels:
        labels.append("forgejo-sync")
    return {
        "title": payload["title"],
        "body": (payload.get("body") or "")
        + provenance("issue", int(payload["number"]), source_repo, payload["html_url"]),
        "state": "open" if payload["state"] == "open" else "closed",
        "labels": sorted(labels),
    }


def desired_pull(payload: dict[str, Any], source_repo: str) -> dict[str, Any]:
    state = (
        "open" if payload["state"] == "open" and not payload.get("merged") else "closed"
    )
    desired = {
        "title": payload["title"],
        "body": (payload.get("body") or "")
        + provenance("pull", int(payload["number"]), source_repo, payload["html_url"]),
        "state": state,
    }
    # GitHub rejects base-branch changes on some closed or already-merged PRs.
    if state == "open":
        desired["base"] = payload["base"]["ref"]
    return desired


def log_target_request(
    github: GitHubClient,
    actions: ActionLog,
    method: str,
    path: str,
    payload: Any,
    *,
    action: str,
    entity_key: str,
    target_kind: str,
    target_number: int | None = None,
) -> Any:
    request_hash = sha256_text(canonical_json(payload))
    actions.record(
        "planned",
        action,
        entity_key=entity_key,
        target_kind=target_kind,
        target_number=target_number,
        request_sha256=request_hash,
        details={"method": method, "path": path},
    )
    try:
        response = github.request(method, path, payload)
    except Exception as error:
        actions.record(
            "failed",
            action,
            entity_key=entity_key,
            target_kind=target_kind,
            target_number=target_number,
            request_sha256=request_hash,
            details={"error": str(error)},
        )
        raise
    actions.record(
        "succeeded",
        action,
        entity_key=entity_key,
        target_kind=target_kind,
        target_number=target_number,
        request_sha256=request_hash,
        details={
            "response_id": response.get("id") if isinstance(response, dict) else None,
            "response_url": response.get("html_url")
            if isinstance(response, dict)
            else None,
        },
    )
    return response


def bootstrap_mappings(
    database: AuditDatabase, github: GitHubClient, source_repo: str
) -> None:
    source_issues = {int(row["source_index"]): row for row in database.heads("issue")}
    source_pulls = {int(row["source_index"]): row for row in database.heads("pull")}
    replacement_pulls: dict[int, sqlite3.Row] = {}
    for row in source_pulls.values():
        payload = json.loads(row["payload_json"])
        marker = PULL_REPLACEMENT_MARKER.search(payload.get("body") or "")
        if (
            marker is not None
            and payload.get("state") == "open"
            and not payload.get("merged")
        ):
            replacement_pulls[int(marker.group(1))] = row
    target_issues = github.pages(github.repo_path("/issues?state=all"))
    for target in target_issues:
        if "pull_request" in target:
            continue
        body = target.get("body") or ""
        match = ISSUE_MARKER.search(body)
        source_index = int(match.group(1)) if match else int(target["number"])
        source = source_issues.get(source_index)
        if source is None:
            continue
        source_payload = json.loads(source["payload_json"])
        if not match and source_payload.get("title") != target.get("title"):
            continue
        database.save_mapping(
            source["entity_key"],
            "issue",
            source_index,
            "issue",
            target_number=int(target["number"]),
            target_id=target["id"],
            target_url=target["html_url"],
            synced_sha256=(
                sha256_text(canonical_json(desired_issue(source_payload, source_repo)))
                if not match
                and (source_payload.get("body") or "").strip()
                == (target.get("body") or "").strip()
                and source_payload.get("state") == target.get("state")
                else None
            ),
        )
        bootstrap_comment_mappings(
            database,
            github,
            source,
            int(target["number"]),
            "issue_comment",
            source_repo,
        )

    target_pulls = github.pages(github.repo_path("/pulls?state=all"))
    for target in target_pulls:
        body = target.get("body") or ""
        match = PULL_MARKER.search(body)
        source_index = int(match.group(1)) if match else int(target["number"])
        source = replacement_pulls.get(source_index) or source_pulls.get(source_index)
        if source is None:
            continue
        source_index = int(source["source_index"])
        source_payload = json.loads(source["payload_json"])
        if not match and source_payload.get("title") != target.get("title"):
            continue
        database.connection.execute(
            "DELETE FROM target_mappings "
            "WHERE target_kind='pull' AND target_number=? AND entity_key<>?",
            (int(target["number"]), source["entity_key"]),
        )
        database.connection.commit()
        database.save_mapping(
            source["entity_key"],
            "pull",
            source_index,
            "pull",
            target_number=int(target["number"]),
            target_id=target["id"],
            target_url=target["html_url"],
            synced_sha256=(
                sha256_text(canonical_json(desired_pull(source_payload, source_repo)))
                if not match
                and (source_payload.get("body") or "").strip()
                == (target.get("body") or "").strip()
                and (
                    (
                        source_payload.get("state") == "open"
                        and target.get("state") == "open"
                    )
                    or (
                        source_payload.get("state") != "open"
                        and target.get("state") == "closed"
                    )
                )
                else None
            ),
        )
        bootstrap_comment_mappings(
            database, github, source, int(target["number"]), "pull_comment", source_repo
        )


def bootstrap_comment_mappings(
    database: AuditDatabase,
    github: GitHubClient,
    parent: sqlite3.Row,
    target_number: int,
    source_kind: str,
    source_repo: str,
) -> None:
    source_comments = database.children(parent["entity_key"], source_kind)
    if not source_comments:
        return
    target_comments = github.pages(
        github.repo_path(f"/issues/{target_number}/comments?")
    )
    available = list(target_comments)
    for source in source_comments:
        payload = json.loads(source["payload_json"])
        matched: dict[str, Any] | None = None
        for target in available:
            marker = COMMENT_MARKER.search(target.get("body") or "")
            if marker and marker.group(1) == str(payload["id"]):
                matched = target
                break
        if matched is None:
            for target in available:
                if (target.get("body") or "").strip() == (
                    payload.get("body") or ""
                ).strip():
                    matched = target
                    break
        if matched is None:
            continue
        available.remove(matched)
        database.save_mapping(
            source["entity_key"],
            source_kind,
            source["source_index"],
            "comment",
            target_number=target_number,
            target_id=matched["id"],
            target_url=matched["html_url"],
            synced_sha256=(
                sha256_text(
                    canonical_json({"body": comment_body(payload, source_repo)})
                )
                if not COMMENT_MARKER.search(matched.get("body") or "")
                else None
            ),
        )


def sync_comments(
    database: AuditDatabase,
    github: GitHubClient,
    actions: ActionLog,
    parent: sqlite3.Row,
    target_number: int,
    source_kind: str,
    source_repo: str,
) -> None:
    for row in database.children(parent["entity_key"], source_kind):
        payload = json.loads(row["payload_json"])
        body = comment_body(payload, source_repo)
        desired_hash = sha256_text(canonical_json({"body": body}))
        mapping = database.mapping(row["entity_key"])
        if mapping is not None and mapping["last_synced_sha256"] == desired_hash:
            actions.record(
                "skipped",
                "comment_unchanged",
                entity_key=row["entity_key"],
                target_kind="comment",
                target_number=target_number,
            )
            continue
        if mapping is None:
            response = log_target_request(
                github,
                actions,
                "POST",
                github.repo_path(f"/issues/{target_number}/comments"),
                {"body": body},
                action="create_comment",
                entity_key=row["entity_key"],
                target_kind="comment",
                target_number=target_number,
            )
            database.save_mapping(
                row["entity_key"],
                source_kind,
                row["source_index"],
                "comment",
                target_number=target_number,
                target_id=response["id"],
                target_url=response["html_url"],
                synced_sha256=desired_hash,
            )
        else:
            log_target_request(
                github,
                actions,
                "PATCH",
                github.repo_path(f"/issues/comments/{mapping['target_id']}"),
                {"body": body},
                action="update_comment",
                entity_key=row["entity_key"],
                target_kind="comment",
                target_number=target_number,
            )
            database.save_mapping(
                row["entity_key"],
                source_kind,
                row["source_index"],
                "comment",
                synced_sha256=desired_hash,
            )


def review_body(
    payload: dict[str, Any], inline_comments: list[dict[str, Any]], source_repo: str
) -> str:
    author = (payload.get("user") or {}).get("login") or "unknown"
    state = payload.get("state") or "unknown"
    submitted = payload.get("submitted_at") or payload.get("created_at") or "unknown"
    sections = [
        f"Forgejo review by @{author}: **{state}** ({submitted})",
        payload.get("body") or "_No review summary._",
    ]
    for comment in inline_comments:
        location = comment.get("path") or "unknown path"
        line = (
            comment.get("new_position")
            or comment.get("old_position")
            or comment.get("line")
        )
        if line is not None:
            location = f"{location}:{line}"
        sections.append(
            f"**Inline comment on `{location}`**\n\n{comment.get('body') or ''}"
        )
    sections.append(f"<!-- forgejo-sync:review:{payload['id']}:{source_repo} -->")
    return "\n\n---\n\n".join(sections)


def sync_reviews(
    database: AuditDatabase,
    github: GitHubClient,
    actions: ActionLog,
    pull: sqlite3.Row,
    target_number: int,
    source_repo: str,
) -> None:
    for row in database.children(pull["entity_key"], "pull_review"):
        payload = json.loads(row["payload_json"])
        inline_comments = [
            json.loads(child["payload_json"])
            for child in database.children(row["entity_key"], "pull_review_comment")
        ]
        body = review_body(payload, inline_comments, source_repo)
        desired_hash = sha256_text(canonical_json({"body": body}))
        mapping = database.mapping(row["entity_key"])
        if mapping is not None and mapping["last_synced_sha256"] == desired_hash:
            actions.record(
                "skipped",
                "review_unchanged",
                entity_key=row["entity_key"],
                target_kind="comment",
                target_number=target_number,
            )
            continue
        if mapping is None:
            response = log_target_request(
                github,
                actions,
                "POST",
                github.repo_path(f"/issues/{target_number}/comments"),
                {"body": body},
                action="create_review_archive",
                entity_key=row["entity_key"],
                target_kind="comment",
                target_number=target_number,
            )
            database.save_mapping(
                row["entity_key"],
                "pull_review",
                row["source_index"],
                "comment",
                target_number=target_number,
                target_id=response["id"],
                target_url=response["html_url"],
                synced_sha256=desired_hash,
            )
        else:
            log_target_request(
                github,
                actions,
                "PATCH",
                github.repo_path(f"/issues/comments/{mapping['target_id']}"),
                {"body": body},
                action="update_review_archive",
                entity_key=row["entity_key"],
                target_kind="comment",
                target_number=target_number,
            )
            database.save_mapping(
                row["entity_key"],
                "pull_review",
                row["source_index"],
                "comment",
                synced_sha256=desired_hash,
            )


def sync_issues(
    database: AuditDatabase,
    github: GitHubClient,
    actions: ActionLog,
    source_repo: str,
) -> None:
    for row in database.heads("issue"):
        payload = json.loads(row["payload_json"])
        desired = desired_issue(payload, source_repo)
        desired_hash = sha256_text(canonical_json(desired))
        mapping = database.mapping(row["entity_key"])
        if mapping is None:
            create_payload = {key: desired[key] for key in ("title", "body", "labels")}
            response = log_target_request(
                github,
                actions,
                "POST",
                github.repo_path("/issues"),
                create_payload,
                action="create_issue",
                entity_key=row["entity_key"],
                target_kind="issue",
            )
            target_number = int(response["number"])
            database.save_mapping(
                row["entity_key"],
                "issue",
                row["source_index"],
                "issue",
                target_number=target_number,
                target_id=response["id"],
                target_url=response["html_url"],
            )
            if desired["state"] == "closed":
                log_target_request(
                    github,
                    actions,
                    "PATCH",
                    github.repo_path(f"/issues/{target_number}"),
                    {"state": "closed"},
                    action="close_created_issue",
                    entity_key=row["entity_key"],
                    target_kind="issue",
                    target_number=target_number,
                )
            database.save_mapping(
                row["entity_key"],
                "issue",
                row["source_index"],
                "issue",
                synced_sha256=desired_hash,
            )
        else:
            target_number = int(mapping["target_number"])
            if mapping["last_synced_sha256"] != desired_hash:
                log_target_request(
                    github,
                    actions,
                    "PATCH",
                    github.repo_path(f"/issues/{target_number}"),
                    desired,
                    action="update_issue",
                    entity_key=row["entity_key"],
                    target_kind="issue",
                    target_number=target_number,
                )
                database.save_mapping(
                    row["entity_key"],
                    "issue",
                    row["source_index"],
                    "issue",
                    synced_sha256=desired_hash,
                )
            else:
                actions.record(
                    "skipped",
                    "issue_unchanged",
                    entity_key=row["entity_key"],
                    target_kind="issue",
                    target_number=target_number,
                )
        sync_comments(
            database,
            github,
            actions,
            row,
            target_number,
            "issue_comment",
            source_repo,
        )


def sync_deletions(
    database: AuditDatabase, github: GitHubClient, actions: ActionLog
) -> None:
    for kind in ("issue", "pull"):
        for row in database.heads(kind, present=False):
            mapping = database.mapping(row["entity_key"])
            if mapping is None:
                continue
            tombstone_hash = row["content_sha256"]
            if mapping["last_synced_sha256"] == tombstone_hash:
                continue
            target_number = int(mapping["target_number"])
            endpoint = "issues" if kind == "issue" else "pulls"
            log_target_request(
                github,
                actions,
                "PATCH",
                github.repo_path(f"/{endpoint}/{target_number}"),
                {"state": "closed"},
                action=f"close_deleted_{kind}",
                entity_key=row["entity_key"],
                target_kind=kind,
                target_number=target_number,
            )
            database.save_mapping(
                row["entity_key"],
                kind,
                row["source_index"],
                kind,
                synced_sha256=tombstone_hash,
            )

    for kind in ("issue_comment", "pull_comment", "pull_review"):
        for row in database.heads(kind, present=False):
            mapping = database.mapping(row["entity_key"])
            if mapping is None:
                continue
            tombstone_hash = row["content_sha256"]
            if mapping["last_synced_sha256"] == tombstone_hash:
                continue
            body = (
                "_Deleted from the authoritative Forgejo repository. The prior "
                "content remains in the local append-only audit ledger._\n\n"
                f"<!-- forgejo-sync:deleted:{row['entity_key']} -->"
            )
            log_target_request(
                github,
                actions,
                "PATCH",
                github.repo_path(f"/issues/comments/{mapping['target_id']}"),
                {"body": body},
                action="tombstone_deleted_comment",
                entity_key=row["entity_key"],
                target_kind="comment",
                target_number=mapping["target_number"],
            )
            database.save_mapping(
                row["entity_key"],
                kind,
                row["source_index"],
                "comment",
                synced_sha256=tombstone_hash,
            )


def sync_pulls(
    database: AuditDatabase,
    github: GitHubClient,
    actions: ActionLog,
    source_repo: str,
) -> None:
    for row in database.heads("pull"):
        payload = json.loads(row["payload_json"])
        desired = desired_pull(payload, source_repo)
        desired_hash = sha256_text(canonical_json(desired))
        mapping = database.mapping(row["entity_key"])
        if mapping is None and desired["state"] != "open":
            actions.record(
                "skipped",
                "historical_pull_archived_only",
                entity_key=row["entity_key"],
                target_kind="pull",
            )
            continue
        if mapping is None:
            create_payload = {
                "title": desired["title"],
                "body": desired["body"],
                "head": payload["head"]["ref"],
                "base": desired["base"],
                "draft": bool(payload.get("draft")),
            }
            response = log_target_request(
                github,
                actions,
                "POST",
                github.repo_path("/pulls"),
                create_payload,
                action="create_pull",
                entity_key=row["entity_key"],
                target_kind="pull",
            )
            target_number = int(response["number"])
            database.save_mapping(
                row["entity_key"],
                "pull",
                row["source_index"],
                "pull",
                target_number=target_number,
                target_id=response["id"],
                target_url=response["html_url"],
                synced_sha256=desired_hash,
            )
        else:
            target_number = int(mapping["target_number"])
            if mapping["last_synced_sha256"] != desired_hash:
                log_target_request(
                    github,
                    actions,
                    "PATCH",
                    github.repo_path(f"/pulls/{target_number}"),
                    desired,
                    action="update_pull",
                    entity_key=row["entity_key"],
                    target_kind="pull",
                    target_number=target_number,
                )
                database.save_mapping(
                    row["entity_key"],
                    "pull",
                    row["source_index"],
                    "pull",
                    synced_sha256=desired_hash,
                )
            else:
                actions.record(
                    "skipped",
                    "pull_unchanged",
                    entity_key=row["entity_key"],
                    target_kind="pull",
                    target_number=target_number,
                )
        sync_comments(
            database,
            github,
            actions,
            row,
            target_number,
            "pull_comment",
            source_repo,
        )
        sync_reviews(database, github, actions, row, target_number, source_repo)


def push_forgejo_refs(
    repo_dir: pathlib.Path,
    target_git_url: str,
    actions: ActionLog,
) -> None:
    action = "push_forgejo_refs"
    actions.record(
        "planned",
        action,
        target_kind="git_refs",
        details={"source_remote": "origin", "target": target_git_url},
    )
    try:
        run_command(
            [
                "git",
                "fetch",
                "--prune",
                "origin",
                "+refs/heads/*:refs/forgejo-sync/heads/*",
                "+refs/tags/*:refs/forgejo-sync/tags/*",
            ],
            cwd=repo_dir,
        )
        run_command(
            [
                "git",
                "push",
                "--force",
                target_git_url,
                "refs/forgejo-sync/heads/*:refs/heads/*",
                "refs/forgejo-sync/tags/*:refs/tags/*",
            ],
            cwd=repo_dir,
        )
    except Exception as error:
        actions.record(
            "failed", action, target_kind="git_refs", details={"error": str(error)}
        )
        raise
    actions.record("succeeded", action, target_kind="git_refs")


def ensure_target_label(
    database: AuditDatabase, github: GitHubClient, actions: ActionLog
) -> None:
    mapping_key = "target_label:forgejo-sync"
    if database.mapping(mapping_key) is not None:
        actions.record(
            "skipped",
            "sync_label_known",
            entity_key=mapping_key,
            target_kind="label",
        )
        return
    payload = {
        "name": "forgejo-sync",
        "color": "6f42c1",
        "description": "Mirrored from the authoritative Forgejo repository",
    }
    try:
        log_target_request(
            github,
            actions,
            "POST",
            github.repo_path("/labels"),
            payload,
            action="ensure_sync_label",
            entity_key=mapping_key,
            target_kind="label",
        )
        database.save_mapping(
            mapping_key, "target_label", None, "label", target_id="forgejo-sync"
        )
    except RuntimeError as error:
        if "already_exists" not in str(error) and "Validation Failed" not in str(error):
            raise
        actions.record(
            "skipped",
            "sync_label_exists",
            entity_key=mapping_key,
            target_kind="label",
        )
        database.save_mapping(
            mapping_key, "target_label", None, "label", target_id="forgejo-sync"
        )


def print_status(database: AuditDatabase) -> None:
    run = database.latest_run()
    if run is None:
        print("no sync runs recorded")
        return
    print(
        canonical_json(
            {
                key: run[key]
                for key in (
                    "id",
                    "source_repo",
                    "target_repo",
                    "mode",
                    "status",
                    "started_at",
                    "finished_at",
                    "snapshot_sha256",
                    "entity_count",
                    "version_count",
                    "changed_entity_count",
                    "action_count",
                    "error",
                )
            }
        )
    )


def default_migrations_dir() -> pathlib.Path:
    return (
        pathlib.Path(__file__).resolve().parent.parent
        / "migrations"
        / "forgejo-github-sync"
    )


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "command",
        choices=("migrate", "snapshot", "bootstrap", "sync", "status"),
        nargs="?",
        default="sync",
    )
    parser.add_argument("--source-repo", default="siraben/psi-coding-agent")
    parser.add_argument("--target-repo", default="siraben/psi-code")
    parser.add_argument("--forgejo-login", default="local-forgejo")
    parser.add_argument(
        "--database",
        type=pathlib.Path,
        default=pathlib.Path.home()
        / ".local/state/psi-code-forgejo-sync/audit.sqlite3",
    )
    parser.add_argument(
        "--migrations-dir", type=pathlib.Path, default=default_migrations_dir()
    )
    parser.add_argument(
        "--repo-dir",
        type=pathlib.Path,
        default=pathlib.Path.home() / "psi-coding-agent",
    )
    parser.add_argument(
        "--target-git-url", default="git@github.com:siraben/psi-code.git"
    )
    parser.add_argument("--workers", type=int, default=8)
    parser.add_argument(
        "--backup-dir",
        type=pathlib.Path,
        help="write an atomic, checksummed gzip backup after a completed run",
    )
    parser.add_argument(
        "--bootstrap-target",
        action="store_true",
        help="one-time target read to map pre-existing migrated objects",
    )
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    args.database.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    lock_path = args.database.with_suffix(args.database.suffix + ".lock")
    lock_handle = lock_path.open("a+", encoding="utf-8")
    try:
        fcntl.flock(lock_handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print(f"another Forgejo sync holds {lock_path}", file=sys.stderr)
        return 75
    database = AuditDatabase(args.database, args.migrations_dir)
    if args.command == "migrate":
        database.close()
        return 0
    if args.command == "status":
        print_status(database)
        database.close()
        return 0
    if args.command == "bootstrap":
        bootstrap_mappings(database, GitHubClient(args.target_repo), args.source_repo)
        count = database.connection.execute(
            "SELECT count(*) FROM target_mappings"
        ).fetchone()[0]
        print(canonical_json({"target_mappings": count}))
        database.close()
        return 0

    mode = "sync" if args.command == "sync" else "snapshot"
    run_id = database.start_run(args.source_repo, args.target_repo, mode)
    interrupted = False

    def handle_signal(signum: int, _frame: Any) -> None:
        nonlocal interrupted
        interrupted = True
        raise KeyboardInterrupt(f"received signal {signum}")

    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)
    try:
        forgejo = ForgejoClient(args.source_repo, args.forgejo_login)
        snapshots = collect_source(forgejo, max(1, args.workers))
        database.record_snapshot(run_id, snapshots)
        if args.command == "sync":
            github = GitHubClient(args.target_repo)
            actions = ActionLog(database, run_id)
            if args.bootstrap_target:
                bootstrap_mappings(database, github, args.source_repo)
            push_forgejo_refs(args.repo_dir, args.target_git_url, actions)
            ensure_target_label(database, github, actions)
            sync_issues(database, github, actions, args.source_repo)
            sync_pulls(database, github, actions, args.source_repo)
            sync_deletions(database, github, actions)
        database.finish_run(run_id, "completed")
        if args.backup_dir is not None:
            backup_path = database.backup(args.backup_dir)
            print(f"wrote audit backup {backup_path}", file=sys.stderr)
    except KeyboardInterrupt as error:
        database.finish_run(run_id, "interrupted", str(error))
        database.close()
        return 130
    except Exception as error:
        database.finish_run(
            run_id, "interrupted" if interrupted else "failed", str(error)
        )
        database.close()
        raise
    print_status(database)
    database.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
