import importlib.util
from contextlib import closing
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("rollout", Path(__file__).with_name("prepare-d1-rollout.py"))
rollout = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rollout)
MIGRATIONS = {path.name: path.read_text(encoding="utf-8")
              for path in sorted((rollout.ROOT / "drizzle").glob("*.sql"))}


def fixture(applied=14):
    """A synthetic interrupted import with applied, skipped and uncertain work."""
    db = sqlite3.connect(":memory:")
    db.execute("PRAGMA foreign_keys=ON")
    db.execute("CREATE TABLE d1_migrations(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT UNIQUE, applied_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL)")
    for name in list(MIGRATIONS)[:14]:
        db.executescript(MIGRATIONS[name])
        db.execute("INSERT INTO d1_migrations(name) VALUES(?)", (name,))
    db.execute("INSERT INTO titles(id,name,sort_name,kind,category,status,favorite,score,notes,queued,created_at,updated_at) VALUES('fixture-show','Fixture show','fixture show','series','show','watching',1,8.5,'Preserve this note',1,'2026-10-25','2026-10-25')")
    db.execute("INSERT INTO seasons(id,title_id,number,name,expected_episodes) VALUES('fixture-season','fixture-show',1,'Season 1',8)")
    db.execute("INSERT INTO episodes(id,title_id,season_id,number) VALUES('fixture-episode','fixture-show','fixture-season',1)")
    for identifier, revoked in (("original", None), ("undone", "2026-10-25T02:00:00Z")):
        db.execute("INSERT INTO watch_events(id,operation_id,title_id,episode_id,watched_at,recorded_at,revoked_at,origin) VALUES(?,?,'fixture-show','fixture-episode','2026-10-25T01:00:00Z','2026-10-25T01:00:00Z',?,'manual')", (identifier, "operation-" + identifier, revoked))
    db.execute("INSERT INTO trakt_connections(id,account_id,client_id,ciphertext,state,updated_at) VALUES('trakt','fixture-account','fixture-client','SYNTHETIC-NOT-A-CREDENTIAL','connected','2026-10-25')")
    db.execute("INSERT INTO trakt_incoming(id,account_id,client_id,enabled,generation,next_at,page) VALUES('trakt','fixture-account','fixture-client',1,7,1792886400000,3)")
    db.execute("INSERT INTO trakt_sync_runs(id,account_id,state,stage,page,progress,rating_mode,created_at,updated_at) VALUES('review-fixture','fixture-account','review','ready',51,600,'round','2026-10-25','2026-10-25')")
    for i in range(2000):
        state = "applied" if i < 600 else ("skipped" if i == 600 else ("uncertain" if i == 601 else "pending"))
        db.execute("INSERT INTO trakt_sync_changes(id,run_id,kind,direction,name,detail,payload,review,state) VALUES(?,'review-fixture','rating','pull','Fixture','Import','{}',?,?)", ("change-" + str(i).zfill(5), 1 if i == 602 else 0, state))
    db.execute("INSERT INTO trakt_sync_baselines(id,account_id,kind,local_key,remote_key,local_value,remote_value,updated_at) VALUES('fixture-baseline','fixture-account','history','original','remote-fixture','local-date','remote-date','2026-10-25')")
    db.execute("INSERT INTO trakt_incoming_history(account_id,remote_id,payload,state,created_at) VALUES('fixture-account','remote-fixture','{}','complete','2026-10-25')")
    db.execute("INSERT INTO trakt_incoming_removed(kind,external_id) VALUES('movie','fixture-removed')")
    db.execute("INSERT INTO progress_operations(id,attempt,input,payload,created_at) VALUES('fixture-receipt','fixture-attempt','{}','{}','2026-10-25')")
    db.commit()
    for name in list(MIGRATIONS)[14:applied]:
        db.executescript(MIGRATIONS[name])
        db.execute("INSERT INTO d1_migrations(name) VALUES(?)", (name,))
    db.commit()
    return closing(db)


def dump(db):
    return ("\n".join(db.iterdump()) + "\n").encode("utf-8")


def run_operator_queries(db, name):
    queries = (rollout.ROOT / "ios/deploy" / name).read_text(encoding="utf-8")
    pending, result = "", []
    for line in queries.splitlines(keepends=True):
        pending += line
        if sqlite3.complete_statement(pending):
            result.append(list(db.execute(pending)))
            pending = ""
    return result


class RolloutTests(unittest.TestCase):
    def test_operator_sql_is_read_only_and_verifies_old_then_new_schema(self):
        with fixture() as db:
            db.execute("PRAGMA query_only=ON")
            before = rollout.snapshot(db)
            preflight = run_operator_queries(db, "preflight-d1.sql")
            self.assertEqual(len(preflight[0]), 14)
            self.assertEqual(preflight[1], [])
            self.assertEqual(preflight[2][0][0], "review-fixture")
            self.assertEqual(before, rollout.snapshot(db))
        with fixture(18) as db:
            db.execute("PRAGMA query_only=ON")
            before = rollout.snapshot(db)
            postflight = run_operator_queries(db, "postflight-d1.sql")
            self.assertEqual(len(postflight[0]), 18)
            self.assertEqual(len(postflight[1]), 15)
            self.assertEqual(postflight[2], [("plan_after", "TEXT", 0)])
            self.assertEqual(postflight[4], [], "No active review bucket may differ")
            self.assertEqual(before, rollout.snapshot(db))

    def test_postflight_reports_a_corrupt_active_review_bucket(self):
        with fixture(18) as db:
            db.execute("UPDATE trakt_sync_change_counts SET amount=amount+1 WHERE state='pending'")
            db.execute("PRAGMA query_only=ON")
            self.assertTrue(run_operator_queries(db, "postflight-d1.sql")[4])

    def test_full_upgrade_preserves_2000_changes_history_receipts_and_settings(self):
        with fixture() as db:
            result = rollout.rehearse(dump(db), MIGRATIONS)
        self.assertEqual(result["rehearsed_migrations"], list(rollout.MIGRATIONS))
        self.assertTrue(result["original_rows_preserved"])
        self.assertEqual(result["before"]["trakt_sync_changes"]["rows"], 2000)
        self.assertEqual(result["after"]["watch_events"]["rows"], 2)
        self.assertEqual(result["before"]["trakt_incoming"], result["after"]["trakt_incoming"])
        self.assertNotIn("SYNTHETIC-NOT-A-CREDENTIAL", str(result))
        self.assertNotIn("Preserve this note", str(result))

    def test_partial_and_already_completed_rollouts_do_not_reapply_migrations(self):
        for applied in (15, 16, 17, 18):
            with self.subTest(applied=applied), fixture(applied) as db:
                result = rollout.rehearse(dump(db), MIGRATIONS)
                self.assertEqual(result["rehearsed_migrations"], list(MIGRATIONS)[applied:])

    def test_ledger_holes_or_unknown_migration_fail_closed(self):
        for sql in ("DELETE FROM d1_migrations WHERE name LIKE '0007%'",
                    "INSERT INTO d1_migrations(name) VALUES('0099_unreviewed.sql')"):
            with self.subTest(sql=sql), fixture() as db:
                db.execute(sql)
                with self.assertRaisesRegex(ValueError, "ledger"):
                    rollout.rehearse(dump(db), MIGRATIONS)

    def test_schema_only_or_truncated_export_is_rejected(self):
        with fixture() as db:
            with self.assertRaisesRegex(ValueError, "ledger"):
                rollout.rehearse(dump(db) + b"DROP TABLE d1_migrations;", MIGRATIONS)
        with self.assertRaises(sqlite3.Error):
            rollout.rehearse(b"CREATE TABLE truncated(", MIGRATIONS)

    def test_schema_drift_or_lied_migration_ledger_is_rejected(self):
        for sql in ("ALTER TABLE titles ADD COLUMN unexpected TEXT",
                    "INSERT INTO d1_migrations(name) VALUES('0014_trakt_review_counts.sql')"):
            with self.subTest(sql=sql), fixture() as db:
                db.execute(sql)
                with self.assertRaisesRegex(ValueError, "Export"):
                    rollout.rehearse(dump(db), MIGRATIONS)

    def test_existing_damaged_aggregate_is_rejected(self):
        for applied in (17, 18):
            with self.subTest(applied=applied), fixture(applied) as db:
                db.execute("UPDATE trakt_sync_change_counts SET amount=amount+1")
                with self.assertRaisesRegex(ValueError, "aggregate counts"):
                    rollout.rehearse(dump(db), MIGRATIONS)

    def test_0017_adds_only_indexes_and_keeps_every_row(self):
        # Hosted D1 already has 0014-0016; the pending release is 0017 alone.
        with fixture(17) as db:
            result = rollout.rehearse(dump(db), MIGRATIONS)
        self.assertEqual(result["rehearsed_migrations"], ["0017_trakt_import_indexes.sql"])
        self.assertEqual({t: v["columns"] for t, v in result["before"].items()},
                         {t: v["columns"] for t, v in result["after"].items()})
        self.assertEqual(result["before"], result["after"])

    def test_migration_cannot_mutate_original_rows_unnoticed(self):
        migrations = dict(MIGRATIONS)
        migrations[rollout.MIGRATIONS[1]] += "\nUPDATE titles SET notes='changed';"
        with fixture() as db:
            with self.assertRaisesRegex(ValueError, "pre-existing"):
                rollout.rehearse(dump(db), migrations)

    def test_dump_cannot_attach_or_write_another_database(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "must-not-exist.sqlite"
            script = ("ATTACH DATABASE '" + target.as_posix() + "' AS other;").encode()
            with self.assertRaises(sqlite3.Error):
                rollout.rehearse(script, MIGRATIONS)
            self.assertFalse(target.exists())

    def test_preparation_rejects_mutable_ref_and_failed_qualification_before_archive(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "release"
            checks = Path(directory) / "checks.json"
            checks.write_text('[{"check_runs": []}]', encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "immutable"):
                rollout.prepare("HEAD", checks, output)
            self.assertFalse(output.exists())
            source = "a" * 40
            with patch.object(rollout, "git", return_value=(source + "\n").encode()) as git:
                with self.assertRaises(ValueError):
                    rollout.prepare(source, checks, output)
                self.assertEqual(git.call_count, 1)
            self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
