#!/usr/bin/env python3
"""Build the study-mode dictionary (SQLite) from meikipop's dictionary.pkl.

meikipop publishes a JMdict/KANJIDIC-based pickle with deconjugation rules
(https://github.com/rtr46/meikipop/releases/tag/dictionary-latest). Plezy reads
the same data from SQLite, so this converts one into the other:

    python3 scripts/study/build_study_dictionary.py dictionary.pkl study_dictionary.sqlite

The result is gzipped and attached to this fork's `study-dictionary` release,
which the app downloads the first time study mode is turned on.
"""

import json
import pickle
import sqlite3
import sys

SCHEMA_VERSION = 1


def main(src: str, dst: str) -> None:
    with open(src, "rb") as f:
        data = pickle.load(f)

    db = sqlite3.connect(dst)
    db.executescript(
        """
        DROP TABLE IF EXISTS terms;
        DROP TABLE IF EXISTS entries;
        DROP TABLE IF EXISTS kanji;
        DROP TABLE IF EXISTS meta;
        CREATE TABLE terms (key TEXT NOT NULL, written TEXT, reading TEXT, freq INTEGER NOT NULL, entry_id INTEGER NOT NULL);
        CREATE TABLE entries (id INTEGER PRIMARY KEY, senses TEXT NOT NULL);
        CREATE TABLE kanji (ch TEXT PRIMARY KEY, data TEXT NOT NULL);
        CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        """
    )

    db.executemany(
        "INSERT INTO terms VALUES (?, ?, ?, ?, ?)",
        (
            (key, written, reading, freq, entry_id)
            for key, refs in data["lookup_map"].items()
            for written, reading, freq, entry_id in refs
        ),
    )
    db.executemany(
        "INSERT INTO entries VALUES (?, ?)",
        (
            (entry_id, json.dumps(
                [{"glosses": s.get("glosses", []), "pos": s.get("pos", []), "tags": s.get("tags", []) or s.get("misc", [])} for s in senses],
                ensure_ascii=False, separators=(",", ":")))
            for entry_id, senses in data["entries"].items()
        ),
    )
    db.executemany(
        "INSERT INTO kanji VALUES (?, ?)",
        (
            (ch, json.dumps(
                {"meanings": k.get("meanings", []), "readings": k.get("readings", [])},
                ensure_ascii=False, separators=(",", ":")))
            for ch, k in data.get("kanji_entries", {}).items()
        ),
    )
    db.executemany(
        "INSERT INTO meta VALUES (?, ?)",
        [
            ("schema_version", str(SCHEMA_VERSION)),
            ("deconjugator_rules", json.dumps(
                [r for r in data.get("deconjugator_rules", []) if isinstance(r, dict)],
                ensure_ascii=False, separators=(",", ":"))),
        ],
    )
    db.execute("CREATE INDEX terms_key ON terms (key)")
    db.commit()
    db.execute("VACUUM")
    db.close()


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
