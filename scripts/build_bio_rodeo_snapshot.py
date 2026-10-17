#!/usr/bin/env python3
"""Build the shipped bio.rodeo snapshot from live public pages.

Run from the repository root:

    PYTHONPATH=backend backend/.venv/bin/python scripts/build_bio_rodeo_snapshot.py

The app also ships with this snapshot so the Library works offline on first
launch. ``POST /api/catalog/refresh`` updates a local cache from the same source.
"""

from __future__ import annotations

import json
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "backend"))

from dimitri.catalog import (  # noqa: E402
    BIO_RODEO_BASE,
    SNAPSHOT_FILE,
    parse_model_page,
)


def main() -> int:
    slugs = [
        "alphafold-3",
        "rhofold-plus",
        "openfold3",
        "alphafold-2",
        "esmfold",
        "rosettafold",
    ]
    import httpx

    client = httpx.Client(
        timeout=25.0,
        follow_redirects=True,
        headers={"User-Agent": "DimitriStudio/0.1 (local research app)"},
    )
    records = []
    for slug in slugs:
        response = client.get(f"{BIO_RODEO_BASE}/models/{slug}")
        status = response.status_code
        record = parse_model_page(slug, response.text) if status == 200 else None
        print(f"{slug}: HTTP {status} -> {'ok' if record else 'no record'}")
        if record:
            records.append(record)
        time.sleep(0.3)
    payload = {
        "source": "bio.rodeo",
        "base_url": BIO_RODEO_BASE,
        "fetched_at": time.time(),
        "mode": "html + schema.org JSON-LD",
        "api": None,
        "verified_at": "2026-10-17",
        "entries": records,
        "note": (
            "bio.rodeo has no public API (checked 2026-10-17). Records are parsed "
            "from public model pages; fields may change without notice."
        ),
    }
    SNAPSHOT_FILE.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {len(records)} records to {SNAPSHOT_FILE}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
