"""Offline release preparation. Never invokes Wrangler or contacts a database.

Pin a qualified Git commit, hash its release inputs, and optionally rehearse its
pending migrations against an in-memory restore of a private SQL export. Only
hashes/counts are written to the report; SQL, row values and credentials stay out.
"""
import argparse
from contextlib import closing
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import sqlite3
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
MIGRATIONS = (
    "0014_trakt_review_counts.sql",
    "0015_trakt_planning_cursor.sql",
    "0016_native_query_bounds.sql",
)
spec = importlib.util.spec_from_file_location(
    "promotion", Path(__file__).with_name("verify-codemagic.py"))
promotion = importlib.util.module_from_spec(spec)
spec.loader.exec_module(promotion)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def git(*args):
    # Separate argv, no shell interpolation, no credential-bearing commands.
    return subprocess.run(["git", *args], cwd=ROOT, check=True,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout


def quoted(name):
    return '"' + name.replace('"', '""') + '"'


def application_tables(db):
    return [row[0] for row in db.execute(
        "SELECT name FROM sqlite_schema WHERE type='table' ORDER BY name")
        if not row[0].startswith(("sqlite_", "_cf_")) and row[0] != "d1_migrations"]


def snapshot(db):
    """Order-independent, streaming row digests; never return raw values."""
    result = {}
    for table in application_tables(db):
        columns = [row[1] for row in db.execute("PRAGMA table_info(" + quoted(table) + ")")]
        order = ",".join(quoted(column) for column in columns)
        checksum, count = hashlib.sha256(), 0
        for row in db.execute("SELECT * FROM " + quoted(table) + " ORDER BY " + order):
            # SQL blobs can occur in an export even though today's app uses text.
            encoded = json.dumps(list(row), ensure_ascii=True, separators=(",", ":"),
                                 default=lambda value: {"blob": value.hex()}).encode()
            checksum.update(len(encoded).to_bytes(8, "big"))
            checksum.update(encoded)
            count += 1
        result[table] = {"columns": columns, "rows": count, "sha256": checksum.hexdigest()}
    return result


def check_integrity(db):
    if list(db.execute("PRAGMA integrity_check")) != [("ok",)]:
        raise ValueError("Backup or rehearsed database failed SQLite integrity checks.")
    if db.execute("PRAGMA foreign_key_check").fetchone() is not None:
        raise ValueError("Backup or rehearsed database has broken foreign keys.")


def migration_ledger(db, migrations):
    if db.execute("SELECT 1 FROM sqlite_schema WHERE name='d1_migrations' AND type='table'").fetchone() is None:
        raise ValueError("Full export must include its d1_migrations ledger.")
    names = [row[0] for row in db.execute("SELECT name FROM d1_migrations ORDER BY name")]
    if len(names) < 14 or names != list(migrations)[:len(names)]:
        raise ValueError("Migration ledger is missing, non-contiguous or outside this release.")
    return names


def verify_schema(db, migrations, applied):
    """A partial previous rollout is allowed only when its ledger/schema agree."""
    with closing(sqlite3.connect(":memory:")) as expected:
        for name in applied:
            expected.executescript(migrations[name])
        if application_tables(db) != application_tables(expected):
            raise ValueError("Export table inventory does not match the recorded migration ledger.")
        for table in application_tables(expected):
            pragma = "PRAGMA table_info(" + quoted(table) + ")"
            if list(db.execute(pragma)) != list(expected.execute(pragma)):
                raise ValueError("Export columns differ from the recorded migration ledger.")
        # Schema exports can quote identifiers differently; compare structural
        # PRAGMAs above, plus required index/trigger identities rather than SQL text.
        objects = "SELECT type,name,tbl_name FROM sqlite_schema WHERE type IN ('index','trigger') AND name NOT LIKE 'sqlite_%' AND tbl_name!='d1_migrations' ORDER BY type,name"
        if list(db.execute(objects)) != list(expected.execute(objects)):
            raise ValueError("Export indexes/triggers differ from the recorded migration ledger.")


def compare_original_rows(db, before):
    """0015 may add NULL plan_after; every original column must stay byte-identical."""
    after = snapshot(db)
    for table, old in before.items():
        columns = old["columns"]
        order = ",".join(quoted(column) for column in columns)
        checksum, count = hashlib.sha256(), 0
        for row in db.execute("SELECT " + order + " FROM " + quoted(table) + " ORDER BY " + order):
            encoded = json.dumps(list(row), ensure_ascii=True, separators=(",", ":"),
                                 default=lambda value: {"blob": value.hex()}).encode()
            checksum.update(len(encoded).to_bytes(8, "big"))
            checksum.update(encoded)
            count += 1
        if count != old["rows"] or checksum.hexdigest() != old["sha256"]:
            raise ValueError("Migration altered pre-existing application rows.")
    return after


def verify_counts(db):
    live = list(db.execute("SELECT run_id,state,review,direction,COUNT(*) FROM trakt_sync_changes GROUP BY run_id,state,review,direction ORDER BY run_id,state,review,direction"))
    saved = list(db.execute("SELECT run_id,state,review,direction,amount FROM trakt_sync_change_counts WHERE amount>0 ORDER BY run_id,state,review,direction"))
    if live != saved:
        raise ValueError("Review aggregate counts do not match the preserved proposals.")
    if db.execute("SELECT 1 FROM trakt_sync_change_counts WHERE amount<0 LIMIT 1").fetchone():
        raise ValueError("Negative review aggregate bucket.")


def rehearse(sql_bytes, migrations):
    db = sqlite3.connect(":memory:")
    try:
        # SQL exports are private trusted input, but cannot attach/write other DBs
        # or load an extension. All execution stays in this in-memory connection.
        def authorize(action, first, second, _database, _trigger):
            if action in (sqlite3.SQLITE_ATTACH, sqlite3.SQLITE_DETACH):
                return sqlite3.SQLITE_DENY
            if action == sqlite3.SQLITE_FUNCTION and (second or "").lower() in (
                    "load_extension", "writefile", "readfile"):
                return sqlite3.SQLITE_DENY
            return sqlite3.SQLITE_OK
        db.set_authorizer(authorize)
        db.executescript(sql_bytes.decode("utf-8-sig"))
        db.execute("PRAGMA foreign_keys=ON")
        check_integrity(db)
        applied = migration_ledger(db, migrations)
        verify_schema(db, migrations, applied)
        before = snapshot(db)
        pending = list(migrations)[len(applied):]
        if any(name not in MIGRATIONS for name in pending):
            raise ValueError("Unexpected pending migration; stop before rollout.")
        for name in pending:
            db.executescript(migrations[name])
            db.execute("INSERT INTO d1_migrations(name) VALUES(?)", (name,))
            db.commit()
            check_integrity(db)
            compare_original_rows(db, before)
        verify_schema(db, migrations, list(migrations))
        verify_counts(db)
        after = compare_original_rows(db, before)
        return {"input_sha256": digest(sql_bytes), "applied_before": applied,
                "rehearsed_migrations": pending, "integrity": "ok",
                "original_rows_preserved": True, "review_counts": "exact",
                "before": before, "after": after}
    finally:
        db.close()


def prepare(source, checks, output, backup=None):
    if not re.fullmatch(r"[0-9a-f]{40}", source):
        raise ValueError("Use a full immutable 40-character source commit SHA.")
    if git("rev-parse", "--verify", source + "^{commit}").decode().strip() != source:
        raise ValueError("Source commit is unavailable.")
    check = promotion.accepted_check(json.loads(checks.read_text(encoding="utf-8-sig")), source)
    names = git("ls-tree", "-r", "--name-only", source).decode().splitlines()
    for name in names:
        parts = Path(name).parts
        base = Path(name).name
        if ".local" in parts or "node_modules" in parts or (
                (base.startswith(".env") or base.startswith(".dev.vars"))
                and not base.endswith(".example")):
            raise ValueError("Source includes a private environment/build file.")
    files = [name for name in names if name.startswith("drizzle/") and name.endswith(".sql")]
    migrations = {Path(name).name: git("show", source + ":" + name).decode("utf-8")
                  for name in sorted(files)}
    if tuple(list(migrations)[14:]) != MIGRATIONS:
        raise ValueError("Release migration set differs from the reviewed 0014–0016 plan.")
    inputs = files + [name for name in names if name in (
        "package.json", "package-lock.json", "wrangler.production.jsonc", "wrangler.jsonc",
        "vite.config.ts", "svelte.config.js", "workers/trakt-incoming/wrangler.production.jsonc")]
    manifest = {"source": source, "prepared_at": datetime.now(timezone.utc).isoformat(),
                "codemagic": {"id": check["id"], "url": check["html_url"],
                               "conclusion": "success"},
                "migration_order": list(MIGRATIONS),
                "backend_git_trees": {name: git("rev-parse", source + ":" + name).decode().strip()
                                      for name in ("src", "workers", "drizzle")},
                "input_sha256": {name: digest(git("show", source + ":" + name)) for name in inputs},
                "remote_actions": [], "hosted_rollout": "not_started"}
    if backup is not None:
        manifest["offline_rehearsal"] = rehearse(backup.read_bytes(), migrations)
    # Never overwrite an earlier package/evidence directory.
    output.mkdir(parents=True, exist_ok=False)
    archive = output / "source.tar"
    git("archive", "--format=tar", "--output=" + str(archive.resolve()), source)
    manifest["archive_sha256"] = digest(archive.read_bytes())
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    return manifest


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True)
    parser.add_argument("--checks", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--backup", type=Path, help="Optional private full SQL export; offline restore only")
    args = parser.parse_args()
    try:
        result = prepare(args.source, args.checks, args.output, args.backup)
    except (ValueError, OSError, sqlite3.Error, subprocess.CalledProcessError, KeyError, TypeError):
        # Exceptions/SQL may contain private data. Do not echo them into CI/chat.
        sys.exit("Preparation failed. No remote action was attempted; check the private input, migration ledger and qualified source.")
    print("Prepared immutable backend source " + result["source"])
    print("Source archive SHA256: " + result["archive_sha256"])
    if "offline_rehearsal" in result:
        print("Offline restore/migration rehearsal passed; all original application rows preserved.")
    print("Hosted actions: none. No iOS build started.")
