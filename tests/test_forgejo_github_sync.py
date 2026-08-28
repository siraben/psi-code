import gzip
import importlib.util
import json
import pathlib
import sqlite3
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
MODULE_PATH = ROOT / "scripts" / "forgejo_github_sync.py"
SPEC = importlib.util.spec_from_file_location("forgejo_github_sync", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
sync = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = sync
SPEC.loader.exec_module(sync)


class AuditDatabaseTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temporary.name)
        self.database = sync.AuditDatabase(
            self.root / "audit.sqlite3", ROOT / "migrations" / "forgejo-github-sync"
        )

    def tearDown(self) -> None:
        self.database.close()
        self.temporary.cleanup()

    def record(self, payloads):
        run_id = self.database.start_run("source/repo", "target/repo", "snapshot")
        self.database.record_snapshot(run_id, {item.key: item for item in payloads})
        self.database.finish_run(run_id, "completed")
        return self.database.connection.execute(
            "SELECT * FROM sync_runs WHERE id=?", (run_id,)
        ).fetchone()

    def test_versions_are_deduplicated_and_changes_are_observed(self) -> None:
        first = sync.entity(
            "issue",
            1001,
            {"id": 1001, "number": 7, "title": "first", "state": "open"},
            source_index=7,
        )
        first_run = self.record([first])
        second_run = self.record([first])
        changed = sync.entity(
            "issue",
            1001,
            {"id": 1001, "number": 7, "title": "revised", "state": "open"},
            source_index=7,
        )
        third_run = self.record([changed])

        self.assertEqual(first_run["version_count"], 1)
        self.assertEqual(second_run["version_count"], 0)
        self.assertEqual(second_run["changed_entity_count"], 0)
        self.assertEqual(third_run["version_count"], 1)
        self.assertEqual(third_run["changed_entity_count"], 1)
        self.assertEqual(
            self.database.connection.execute(
                "SELECT count(*) FROM entity_versions"
            ).fetchone()[0],
            2,
        )
        self.assertEqual(
            self.database.connection.execute(
                "SELECT count(*) FROM entity_observations"
            ).fetchone()[0],
            3,
        )

    def test_disappearance_records_a_tombstone_without_losing_payload(self) -> None:
        item = sync.entity(
            "issue_comment",
            88,
            {"id": 88, "body": "text that was later deleted"},
            source_index=7,
            parent_key="issue:1001",
        )
        self.record([item])
        deleted_run = self.record([])

        head = self.database.connection.execute(
            "SELECT h.is_present, v.payload_json FROM entity_heads h "
            "JOIN entity_versions v ON v.id=h.version_id WHERE h.entity_key=?",
            (item.key,),
        ).fetchone()
        history = self.database.connection.execute(
            "SELECT payload_json FROM entity_versions WHERE entity_key=? ORDER BY id",
            (item.key,),
        ).fetchall()
        self.assertEqual(head["is_present"], 0)
        self.assertTrue(json.loads(head["payload_json"])["deleted"])
        self.assertEqual(
            json.loads(history[0]["payload_json"])["body"],
            "text that was later deleted",
        )
        self.assertEqual(deleted_run["changed_entity_count"], 1)

    def test_history_tables_reject_update_and_delete(self) -> None:
        item = sync.entity("repository", 1, {"id": 1, "name": "source"})
        self.record([item])
        with self.assertRaises(sqlite3.IntegrityError):
            self.database.connection.execute(
                "UPDATE entity_versions SET payload_json='{}'"
            )
        with self.assertRaises(sqlite3.IntegrityError):
            self.database.connection.execute("DELETE FROM entity_observations")

    def test_backup_is_gzipped_and_integrity_check_passes(self) -> None:
        self.record([sync.entity("repository", 1, {"id": 1})])
        destination = self.database.backup(self.root / "backups")
        unpacked = self.root / "restored.sqlite3"
        with gzip.open(destination, "rb") as source, unpacked.open("wb") as target:
            target.write(source.read())
        restored = sqlite3.connect(unpacked)
        try:
            self.assertEqual(
                restored.execute("PRAGMA integrity_check").fetchone()[0], "ok"
            )
            self.assertEqual(
                restored.execute("SELECT count(*) FROM sync_runs").fetchone()[0], 1
            )
        finally:
            restored.close()
        self.assertTrue(
            destination.with_suffix(destination.suffix + ".sha256").is_file()
        )


class FormattingTest(unittest.TestCase):
    def test_pull_normalization_removes_volatile_embedded_repo_fields(self) -> None:
        payload = {
            "id": 4,
            "base": {
                "ref": "master",
                "repo": {
                    "id": 1,
                    "full_name": "source/repo",
                    "default_branch": "master",
                    "updated_at": "later",
                    "size": 99,
                },
            },
            "head": {"ref": "topic", "repo": {"id": 1, "size": 99}},
        }
        normalized = sync.normalize_pull_payload(payload)
        self.assertEqual(
            normalized["base"]["repo"],
            {"id": 1, "full_name": "source/repo", "default_branch": "master"},
        )
        self.assertEqual(normalized["head"]["repo"], {"id": 1})
        self.assertEqual(payload["base"]["repo"]["size"], 99)

    def test_provenance_is_machine_readable(self) -> None:
        payload = {
            "number": 7,
            "title": "Example",
            "body": "body",
            "state": "open",
            "labels": [],
            "html_url": "https://forgejo.example/source/repo/issues/7",
        }
        desired = sync.desired_issue(payload, "source/repo")
        self.assertIn("authoritative Forgejo issue #7", desired["body"])
        self.assertIn("<!-- forgejo-sync:issue:source/repo:7 -->", desired["body"])
        self.assertEqual(desired["labels"], ["forgejo-sync"])

    def test_closed_pull_does_not_request_a_base_branch_change(self) -> None:
        payload = {
            "number": 9,
            "title": "Merged",
            "body": "body",
            "state": "closed",
            "merged": True,
            "base": {"ref": "master"},
            "html_url": "https://forgejo.example/source/repo/pulls/9",
        }
        desired = sync.desired_pull(payload, "source/repo")
        self.assertEqual(desired["state"], "closed")
        self.assertNotIn("base", desired)

    def test_current_provenance_markers_are_bootstrap_readable(self) -> None:
        self.assertEqual(
            sync.ISSUE_MARKER.search(
                "<!-- forgejo-sync:issue:source/repo:81 -->"
            ).group(1),
            "81",
        )
        self.assertEqual(
            sync.PULL_MARKER.search("<!-- forgejo-sync:pull:source/repo:225 -->").group(
                1
            ),
            "225",
        )


class BootstrapMappingTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temporary.name)
        self.database = sync.AuditDatabase(
            self.root / "audit.sqlite3", ROOT / "migrations" / "forgejo-github-sync"
        )

    def tearDown(self) -> None:
        self.database.close()
        self.temporary.cleanup()

    def test_open_replacement_supersedes_merged_pull_mapping(self) -> None:
        old = sync.entity(
            "pull",
            1536,
            {
                "id": 1536,
                "number": 202,
                "title": "Persistent goals",
                "body": "original",
                "state": "closed",
                "merged": True,
                "html_url": "https://forgejo.example/pulls/202",
                "base": {"ref": "master"},
            },
            source_index=202,
        )
        replacement = sync.entity(
            "pull",
            1586,
            {
                "id": 1586,
                "number": 225,
                "title": "Persistent goals",
                "body": "Replacement for Forgejo PR #202.",
                "state": "open",
                "merged": False,
                "html_url": "https://forgejo.example/pulls/225",
                "base": {"ref": "master"},
            },
            source_index=225,
        )
        run_id = self.database.start_run("source/repo", "target/repo", "snapshot")
        self.database.record_snapshot(
            run_id, {old.key: old, replacement.key: replacement}
        )
        self.database.finish_run(run_id, "completed")
        self.database.save_mapping(
            old.key, "pull", 202, "pull", target_number=55, target_id=55
        )
        self.database.save_mapping(
            replacement.key,
            "pull",
            225,
            "pull",
            target_number=95,
            target_id=95,
            synced_sha256="a" * 64,
        )

        class Target:
            @staticmethod
            def repo_path(suffix):
                return f"/repos/target/repo{suffix}"

            @staticmethod
            def pages(path):
                if "/issues?" in path:
                    return []
                if "/pulls?" in path:
                    return [
                        {
                            "id": 55,
                            "number": 55,
                            "title": "Persistent goals",
                            "body": "Imported from Forgejo PR #202",
                            "state": "open",
                            "html_url": "https://github.example/pulls/55",
                        }
                    ]
                if "/issues/55/comments?" in path:
                    return []
                raise AssertionError(f"unexpected target path: {path}")

        sync.bootstrap_mappings(self.database, Target(), "source/repo")
        self.assertIsNone(self.database.mapping(old.key))
        mapping = self.database.mapping(replacement.key)
        self.assertIsNotNone(mapping)
        self.assertEqual(mapping["target_number"], 55)
        self.assertEqual(mapping["source_index"], 225)
        self.assertIsNone(mapping["last_synced_sha256"])


if __name__ == "__main__":
    unittest.main()
