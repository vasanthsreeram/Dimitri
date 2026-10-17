"""Before/after timing of real model jobs through Dimitri's job API.

Runs a small input end to end through the backend's job API, in-process,
against the models installed on this Mac:

  cold  warm_workers off: every job starts a fresh model process (Python
        start-up, imports, weight load, prediction). For RhoFold+ that is
        rhofold-mac's ./run.sh. This is how phase 1 ran every model.
  warm  warm_workers on: the first job starts the worker and loads the model;
        later jobs reuse it.

Usage (from the repository root):
  backend/.venv/bin/python scripts/bench_runner.py                 # RhoFold+, 52-nt sample
  backend/.venv/bin/python scripts/bench_runner.py --model alphafold3-mac --jobs 1 --samples 2

Job wall time is created → finished as recorded by the backend, so it
includes queueing, the runner, PDB/mmCIF conversion and result writing.
"""

from __future__ import annotations

import argparse
import json
import platform
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "backend"))

from fastapi.testclient import TestClient  # noqa: E402

from dimitri.config import Settings  # noqa: E402
from dimitri.main import create_app  # noqa: E402


def wait(client: TestClient, job_id: str, timeout: float = 600) -> dict:
    deadline = time.time() + timeout
    while time.time() < deadline:
        job = client.get(f"/api/jobs/{job_id}").json()
        if job["status"] in ("completed", "failed", "cancelled"):
            return job
        time.sleep(0.05)
    raise SystemExit(f"job {job_id} did not finish")


def run_jobs(client: TestClient, args, entity: str, sequence: str, count: int, label: str) -> list[dict]:
    rows = []
    for index in range(count):
        job = client.post(
            "/api/jobs",
            json={
                "model_id": args.model,
                "entity_type": entity,
                "sequence": sequence,
                "name": f"{label}-{index + 1}",
                "samples": args.samples,
            },
        ).json()["job"]
        done = wait(client, job["id"])
        if done["status"] != "completed":
            raise SystemExit(f"{label} job failed: {done.get('error')}")
        result = done["result"]
        rows.append(
            {
                "mode": label,
                "job": index + 1,
                "wall_s": round(done["finished_at"] - done["created_at"], 2),
                "warm": result.get("warm"),
                "timings": result.get("timings"),
                "plddt": result["metrics"]["plddt"],
            }
        )
        print(f"{label} job {index + 1}: {rows[-1]['wall_s']:.2f} s  warm={rows[-1]['warm']}  timings={rows[-1]['timings']}")
    return rows


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", default="rhofold", choices=["rhofold", "alphafold3-mac"])
    parser.add_argument("--jobs", type=int, default=3, help="cold jobs; warm runs one more")
    parser.add_argument("--samples", type=int, default=1)
    parser.add_argument("--out", type=Path, default=None)
    args = parser.parse_args()

    real = Settings.load()
    if args.model == "rhofold":
        fasta = Path(real.rhofold_repo).expanduser() / "examples" / "sample.fasta"
        entity = "rna"
        sequence = "".join(line.strip() for line in fasta.read_text().splitlines() if not line.startswith(">"))
        described = f"{len(sequence)}-nt RNA (6TB7 chain A, rhofold-mac sample)"
    else:
        entity, sequence = "protein", "NLYIQWLKDGGPSSGRPPPS"
        described = f"Trp-cage (PDB 1L2Y), {len(sequence)} residues, {args.samples} sample(s)"
    paths = {key: getattr(real, key) for key in ("rhofold_repo", "af3_repo", "mac_af3_repo", "af3_weights_dir")}

    with tempfile.TemporaryDirectory(prefix="dimitri-bench-") as tmp:
        home = Path(tmp) / "home"
        home.mkdir()
        (home / "settings.json").write_text(json.dumps(paths))
        with TestClient(create_app(home)) as client:
            client.put("/api/settings", json={"warm_workers": False})
            cold = run_jobs(client, args, entity, sequence, args.jobs, "cold")
            client.put("/api/settings", json={"warm_workers": True, "keep_warm_minutes": -1})
            warm = run_jobs(client, args, entity, sequence, args.jobs + 1, "warm")

    chip = subprocess.run(["sysctl", "-n", "machdep.cpu.brand_string"], capture_output=True, text=True).stdout.strip()
    memory = int(subprocess.run(["sysctl", "-n", "hw.memsize"], capture_output=True, text=True).stdout) // 1024**3
    warm_steady = [row["wall_s"] for row in warm[1:]]
    summary = {
        "machine": f"{chip}, {memory} GB, macOS {platform.mac_ver()[0]}",
        "date": time.strftime("%Y-%m-%d %H:%M"),
        "model": args.model,
        "input": described,
        "cold_median_s": statistics.median(row["wall_s"] for row in cold),
        "warm_first_s": warm[0]["wall_s"],
        "warm_median_s": statistics.median(warm_steady),
        "speedup": round(statistics.median(row["wall_s"] for row in cold) / statistics.median(warm_steady), 2),
        "rows": cold + warm,
    }
    print(json.dumps({k: v for k, v in summary.items() if k != "rows"}, indent=1))
    if args.out:
        args.out.write_text(json.dumps(summary, indent=1))


if __name__ == "__main__":
    main()
