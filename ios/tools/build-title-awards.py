"""Build the offline title index from a commit ZIP of eunaotenhoid/TMDB-awards-database."""
import argparse
from collections import defaultdict
import json
from pathlib import Path
import re
import sqlite3
import tempfile
from zipfile import ZipFile


def build(archive, destination):
    titles = defaultdict(dict)
    with ZipFile(archive) as source:
        root = source.namelist()[0].split("/")[0]
        match = re.fullmatch(r"TMDB-awards-database-([0-9a-f]{40})", root)
        if not match:
            raise ValueError("Expected a TMDB-awards-database ZIP for a specific commit.")
        revision = match.group(1)
        license_text = source.read(f"{root}/LICENSE").decode("utf-8")
        for path in sorted(source.namelist()):
            if not (path.startswith(f"{root}/awards/") and path.endswith(".json")):
                continue
            ceremony = json.loads(source.read(path))
            name = ceremony["award_info"]["name"].strip()
            for year, results in (ceremony["years"] or {}).items():
                if not re.fullmatch(r"[0-9]{4}", year):
                    continue
                for result in results:
                    kind, identifier = result["media_type"], result["tmdb_id"]
                    category = result["category"].strip()
                    won = result["is_winner"]
                    if kind not in ("movie", "tv") or not category or not name:
                        continue
                    if type(identifier) is not int or identifier <= 0 or type(won) is not bool:
                        continue
                    records = titles[f"{kind}:{identifier}"]
                    key = (int(year), name, category)
                    records[key] = won or records.get(key, False)

    if not titles:
        raise ValueError("No title-linked awards in the source archive.")
    with tempfile.TemporaryDirectory(dir=destination.parent) as folder:
        output = Path(folder) / "TitleAwards.sqlite"
        db = sqlite3.connect(output)
        try:
            db.execute("CREATE TABLE titles (identity TEXT PRIMARY KEY, records TEXT NOT NULL) WITHOUT ROWID")
            db.execute("CREATE TABLE source (revision TEXT, license TEXT)")
            db.execute("INSERT INTO source VALUES (?, ?)", (revision, license_text))
            for identity, records in sorted(titles.items()):
                rows = [dict(year=y, ceremony=c, category=k, won=w)
                        for (y, c, k), w in sorted(records.items())]
                db.execute("INSERT INTO titles VALUES (?, ?)",
                           (identity, json.dumps(rows, ensure_ascii=False, separators=(",", ":"))))
            db.commit()
        finally:
            db.close()
        output.replace(destination)
    print(f"{len(titles):,} titles, {sum(map(len, titles.values())):,} awards")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("--output", type=Path, default=Path(__file__).resolve().parents[1] / "App/Resources/TitleAwards.sqlite")
    args = parser.parse_args()
    build(args.archive, args.output)
