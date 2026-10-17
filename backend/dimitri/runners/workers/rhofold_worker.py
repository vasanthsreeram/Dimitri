"""Warm RhoFold+ worker for Dimitri Studio, running inside rhofold-mac.

Usage (the backend starts it):
    <rhofold-mac>/.venv/bin/python rhofold_worker.py --rhofold-mac <checkout>

rhofold-mac (github.com/vasanthsreeram/rhofold-mac) is installed with its own
./setup.sh: a .venv with pinned PyTorch, upstream ml4bio/RhoFold at a fixed
commit in RhoFold/ with rhofold-mac's speed patch applied, and the checked
weights in RhoFold/pretrained/. This worker imports that code; it copies none
of it. Per job it does what rhofold-mac's predict.py does (single-sequence
mode, no Amber relaxation, RHOFOLD_FAST=1) and writes the same files:
unrelaxed_model.pdb, ss.ct, results.npz and run_info.json. The difference is
that the model is loaded once and stays on the Apple GPU between jobs.

One correction: upstream's PDB writer puts residue i-1's confidence into
residue i's B-factor. The worker rewrites the B-factor column with each
residue's own pLDDT so colouring by B-factor is right.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from protocol import WorkerFailure, memory_budget_bytes, serve  # noqa: E402

RNA_BASES = set("AUGC")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--rhofold-mac", required=True, help="rhofold-mac checkout")
    parser.add_argument("--device", default="auto", choices=["auto", "mps", "cpu"])
    parser.add_argument("--official", action="store_true", help="turn off RHOFOLD_FAST")
    parser.add_argument(
        "--warmup",
        action="store_true",
        help="run a short forward pass at load (only helps the very first run after "
        "install, when Metal compiles its shaders; they are cached on disk after that)",
    )
    return parser.parse_args()


ARGS = parse_args()
CHECKOUT = Path(ARGS.rhofold_mac).expanduser().resolve()
WEIGHTS = CHECKOUT / "RhoFold" / "pretrained" / "RhoFold_pretrained.pt"

# Read at import time by the patched rhofold modules and by PyTorch.
os.environ["RHOFOLD_FAST"] = "0" if ARGS.official else "1"
os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")


def check_sequence(sequence: str) -> None:
    """Same rules and wording as rhofold-mac's predict.py."""
    if not sequence:
        raise WorkerFailure("The sequence is empty.")
    bad = sorted(set(sequence) - RNA_BASES)
    if bad:
        hint = " DNA? Replace T with U." if "T" in bad else ""
        hint += " Lower-case? Use upper case." if any(c.islower() for c in bad) else ""
        raise WorkerFailure(
            f"sequence contains {', '.join(repr(c) for c in bad)}; "
            f"RhoFold+ accepts only A, U, G, C.{hint}"
        )


def load(channel):
    if not (CHECKOUT / "RhoFold" / "rhofold").is_dir():
        raise WorkerFailure(
            f"rhofold-mac is not set up at {CHECKOUT} (RhoFold/ is missing).",
            hint="Open Library and choose Install for RhoFold+; it runs rhofold-mac's ./setup.sh.",
            not_ready=True,
        )
    if not WEIGHTS.is_file():
        raise WorkerFailure(
            f"RhoFold+ weights not found at {WEIGHTS}.",
            hint="Run setup again (Library → RhoFold+ → Install); rhofold-mac downloads "
            "and checksums them.",
            not_ready=True,
        )
    sys.path.insert(0, str(CHECKOUT / "RhoFold"))
    channel.progress(None, 0.1, "Importing PyTorch")
    started = time.perf_counter()
    import numpy as np  # noqa: F401  (imported here so failures are reported)
    import torch
    from rhofold.config import rhofold_config
    from rhofold.rhofold import RhoFold

    import_s = time.perf_counter() - started

    device = ARGS.device
    if device == "auto":
        device = "mps" if torch.backends.mps.is_available() else "cpu"
    elif device == "mps" and not torch.backends.mps.is_available():
        raise WorkerFailure(
            "MPS (Apple GPU) is not available to PyTorch here.",
            hint="Run rhofold-mac's ./doctor.sh to see why (Rosetta, macOS version or Python build).",
            not_ready=True,
        )

    info = {"device": device, "torch": torch.__version__, "fast": not ARGS.official}
    if device == "mps":
        # Cap this process at the budget the backend sized for this Mac, so an
        # oversized job fails cleanly instead of swapping the machine to a halt.
        recommended = int(torch.mps.recommended_max_memory())
        budget = memory_budget_bytes()
        info["recommended_max_gb"] = round(recommended / 1024**3, 2)
        if budget and recommended:
            fraction = max(0.5, min(1.7, budget / recommended))
            torch.mps.set_per_process_memory_fraction(fraction)
            info["memory_fraction"] = round(fraction, 3)
            info["gpu_budget_gb"] = round(budget / 1024**3, 1)

    channel.progress(None, 0.5, "Loading RhoFold+ weights")
    t0 = time.perf_counter()
    model = RhoFold(rhofold_config)
    try:
        checkpoint = torch.load(WEIGHTS, map_location="cpu", weights_only=False)
        model.load_state_dict(checkpoint["model"])
    except Exception as exc:  # damaged file: same advice as rhofold-mac
        raise WorkerFailure(
            f"could not load the weights ({type(exc).__name__}: {exc}).",
            hint=f"The file may be damaged: delete {WEIGHTS} and run setup again.",
            not_ready=True,
        ) from exc
    model.eval().to(device)
    load_s = time.perf_counter() - t0

    state = {
        "model": model,
        "device": device,
        "torch": torch,
        "recycles": int(rhofold_config.model.recycling_embedder.recycles),
        "counter": {"n": 0, "on_recycle": None, "peak": 0},
    }

    # dist_head is the last module called in every recycle (10 per prediction;
    # structure_module and msa_embedder are called via .forward and bypass
    # hooks). Measured on the 52-nt sample, at most a few ms of GPU work is
    # still queued when it fires, so no synchronisation is needed.
    def on_recycle(_module, _inputs, _output):
        counter = state["counter"]
        counter["n"] += 1
        if device == "mps":
            counter["peak"] = max(counter["peak"], int(torch.mps.driver_allocated_memory()))
        callback = counter["on_recycle"]
        if callback is not None:
            callback(counter["n"])

    model.dist_head.register_forward_hook(on_recycle)

    warmup_s = None
    if ARGS.warmup:
        # Compile the Metal kernels once so the first real job is not slower.
        channel.progress(None, 0.85, "Warming up the GPU kernels")
        t1 = time.perf_counter()
        _forward(state, "GGGAAACCCC", None)
        warmup_s = round(time.perf_counter() - t1, 2)
        _release(state)

    info.update(
        {
            "import_s": round(import_s, 2),
            "load_s": round(load_s + import_s, 2),
            "weights_load_s": round(load_s, 2),
            "warmup_s": warmup_s,
            "recycles": state["recycles"],
            "checkout": str(CHECKOUT),
        }
    )
    return state, info


def _forward(state, sequence: str, workdir: Path | None):
    """Featurise and run one forward pass; returns (features, output)."""
    import tempfile

    torch = state["torch"]
    from rhofold.utils.alphabet import get_features

    if workdir is None:
        handle = tempfile.NamedTemporaryFile("w", suffix=".fasta", delete=False)
        with handle:
            handle.write(f">warmup\n{sequence}\n")
        fasta = handle.name
    else:
        fasta = str(workdir / "input.fasta")
    try:
        features = get_features(fasta, fasta)  # single-sequence: the MSA is the query
    finally:
        if workdir is None:
            os.unlink(fasta)
    device = state["device"]
    with torch.no_grad():
        output = state["model"](
            tokens=features["tokens"].to(device),
            rna_fm_tokens=features["rna_fm_tokens"].to(device),
            seq=features["seq"],
        )[-1]
        if device == "mps":
            torch.mps.synchronize()
    return features, output


def _release(state) -> None:
    torch = state["torch"]
    if state["device"] == "mps":
        torch.mps.empty_cache()


def predict(state, request, channel):
    import numpy as np

    torch = state["torch"]
    from rhofold.utils import save_ss2ct

    job = request["request"]
    sequence = "".join(str(job.get("sequence", "")).split())
    check_sequence(sequence)
    workdir = Path(request["workdir"])
    out_dir = workdir / "rhofold-out"
    out_dir.mkdir(parents=True, exist_ok=True)
    name = "".join(ch if ch.isalnum() or ch in "-_." else "_" for ch in job.get("name", "query"))
    (workdir / "input.fasta").write_text(f">{name or 'query'}\n{sequence}\n", encoding="utf-8")

    recycles = state["recycles"]
    counter = state["counter"]
    counter["n"] = 0
    counter["peak"] = 0

    def on_recycle(n: int) -> None:
        channel.progress("fold", n / recycles, f"Recycle {n}/{recycles}")

    counter["on_recycle"] = on_recycle
    channel.progress("fold", 0.0, f"{len(sequence)} nt · single-sequence · {state['device'].upper()}")
    t0 = time.perf_counter()
    try:
        features, output = _forward(state, sequence, workdir)
    except RuntimeError as exc:
        text = str(exc)
        if state["device"] == "mps" and ("out of memory" in text.lower() or "MPS backend" in text):
            raise WorkerFailure(
                f"The Apple GPU ran out of memory for {len(sequence)} nt.",
                hint="Close other apps and try again; RNAs of 300+ nt need 10+ GB.",
            ) from exc
        raise
    finally:
        counter["on_recycle"] = None
    predict_s = time.perf_counter() - t0

    channel.progress("confidence", 0.5, "Reading pLDDT")
    plddt = output["plddt"][0].float().cpu().numpy().reshape(-1)
    xyz = output["cord_tns_pred"][-1].squeeze(0).float().cpu().numpy()
    ss_prob = torch.sigmoid(output["ss"][0, 0]).float().cpu().numpy()

    channel.progress("write", 0.3, "Writing PDB, secondary structure and distance maps")
    t1 = time.perf_counter()
    pdb_path = out_dir / "unrelaxed_model.pdb"
    model = state["model"]
    model.structure_module.converter.export_pdb_file(
        features["seq"], xyz, path=str(pdb_path), chain_id=None, confidence=plddt
    )
    plddt_100 = [round(float(v) * 100.0, 2) for v in plddt]
    fix_bfactors(pdb_path, plddt_100)
    save_ss2ct(ss_prob, features["seq"], str(out_dir / "ss.ct"), threshold=0.5)
    np.savez_compressed(
        out_dir / "results.npz",
        dist_n=torch.softmax(output["n"].squeeze(0), dim=0).float().cpu().numpy(),
        dist_p=torch.softmax(output["p"].squeeze(0), dim=0).float().cpu().numpy(),
        dist_c=torch.softmax(output["c4_"].squeeze(0), dim=0).float().cpu().numpy(),
        ss_prob_map=ss_prob,
        plddt=plddt,
    )
    write_s = time.perf_counter() - t1
    info = {
        "input": str(workdir / "input.fasta"),
        "length": len(sequence),
        "mode": "single-sequence",
        "device": state["device"],
        "fast": not ARGS.official,
        "model_load_s": 0.0,
        "predict_s": round(predict_s, 2),
        "mean_plddt": round(float(plddt.mean()), 4),
        "torch": torch.__version__,
        "runner": "Dimitri Studio warm worker",
    }
    (out_dir / "run_info.json").write_text(json.dumps(info, indent=1), encoding="utf-8")
    peak = counter["peak"] or (
        int(torch.mps.driver_allocated_memory()) if state["device"] == "mps" else 0
    )
    return {
        "pdb_path": str(pdb_path),
        "ct_path": str(out_dir / "ss.ct"),
        "per_residue_plddt": plddt_100,
        "mean_plddt": round(float(plddt.mean()) * 100.0, 2),
        "device": state["device"],
        "length": len(sequence),
        "timings": {"predict_s": round(predict_s, 3), "write_s": round(write_s, 3)},
        "peak_memory_gb": round(peak / 1024**3, 2) if peak else None,
        "run_info": info,
    }


def fix_bfactors(pdb_path: Path, plddt_100: list[float]) -> None:
    """Write each residue's own pLDDT into its B-factor column (cols 61–66)."""
    lines = pdb_path.read_text(encoding="utf-8").splitlines()
    out = []
    for line in lines:
        if line.startswith(("ATOM", "HETATM")) and len(line) >= 66:
            try:
                index = int(line[22:26]) - 1
            except ValueError:
                out.append(line)
                continue
            if 0 <= index < len(plddt_100):
                line = f"{line[:60]}{plddt_100[index]:6.2f}{line[66:]}"
        out.append(line)
    pdb_path.write_text("\n".join(out) + "\n", encoding="utf-8")


if __name__ == "__main__":
    raise SystemExit(serve(load, predict, after_job=_release))
