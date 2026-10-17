"""Synthetic warm worker for tests: no model, standard library only.

It exercises the real worker protocol end to end (load, progress, result,
errors, cancellation by kill) without weights. ``DEMO_WORKER_LOAD_S`` and
``DEMO_WORKER_STEP_S`` slow it down so tests can observe the warm/cold
difference and cancel mid-job.
"""

from __future__ import annotations

import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from protocol import WorkerFailure, serve  # noqa: E402


def load(channel):
    channel.progress(None, 0.3, "Loading synthetic model")
    time.sleep(float(os.environ.get("DEMO_WORKER_LOAD_S", "0.2")))
    if os.environ.get("DEMO_WORKER_FAIL_LOAD"):
        raise WorkerFailure("Synthetic weights are missing.", hint="Run setup.", not_ready=True)
    return {"loaded_at": time.time()}, {"device": "cpu", "info": {"pid": os.getpid()}}


def predict(state, request, channel):
    sequence = request["request"]["sequence"]
    if "Z" in sequence:
        raise WorkerFailure("Synthetic model rejects Z.", hint="Remove Z from the sequence.")
    step = float(os.environ.get("DEMO_WORKER_STEP_S", "0.02"))
    for index, stage in enumerate(("validate", "fold", "confidence", "write")):
        channel.progress(stage, 0.5, f"{stage} {index + 1}/4")
        time.sleep(step)
    n = len(sequence)
    lines = []
    for i in range(n):
        lines.append(
            f"ATOM  {i + 1:5d}  CA  ALA A{i + 1:4d}    "
            f"{3.8 * i:8.3f}{0.0:8.3f}{0.0:8.3f}{1.00:6.2f}{80.0:6.2f}           C"
        )
    lines.append("END")
    return {
        "pdb_text": "\n".join(lines) + "\n",
        "per_residue_plddt": [80.0] * n,
        "metrics": {"plddt": 80.0, "ptm": None, "iptm": None},
        "device": "cpu",
        "worker_pid": os.getpid(),
        "loaded_at": state["loaded_at"],
        "timings": {"predict_s": round(step * 4, 3)},
    }


if __name__ == "__main__":
    raise SystemExit(serve(load, predict))
