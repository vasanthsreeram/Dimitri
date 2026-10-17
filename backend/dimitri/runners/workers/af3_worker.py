"""Warm AlphaFold 3 worker: alphafold3-mac with mac-af3's runtime.

Usage (the backend starts it, in alphafold3-mac's own .venv):
    python af3_worker.py --af3 <alphafold3-mac> --mac-af3 <mac-af3> --weights <dir>

mac-af3 (github.com/vasanthsreeram/mac-af3) supplies the runtime: its
configuration hooks (``mac_af3_patches``: batched compiled sampler, exact
diffusion cache, 64-token buckets), weight streaming (``streaming``) and
activation-memory patches (``lean``), applied to an unmodified alphafold3-mac
checkout. This file only drives them: it loads the model once, picks the
configuration for this Mac's memory, and runs alphafold3-mac's
InferenceRunner per job with progress callbacks. No mac-af3 code is copied
here; the modules are imported from the user's own checkout.

Weights are the user's own af3.bin.zst (and, on 16 GB Macs, mac-af3's local
shards of it). They are read in place and never copied.
"""

from __future__ import annotations

import argparse
import gc
import json
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from protocol import WorkerFailure, memory_budget_bytes, serve  # noqa: E402


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--af3", required=True, help="alphafold3-mac checkout")
    parser.add_argument("--mac-af3", required=True, help="mac-af3 checkout")
    parser.add_argument("--weights", required=True, help="directory holding af3.bin.zst")
    parser.add_argument("--tier", default=os.environ.get("DIMITRI_DEVICE_TIER", "standard"))
    return parser.parse_args()


ARGS = parse_args()
AF3 = Path(ARGS.af3).expanduser().resolve()
MAC_AF3 = Path(ARGS.mac_af3).expanduser().resolve()
WEIGHTS = Path(ARGS.weights).expanduser()

# Above this many tokens the 24–36 GB tier turns on mac-af3's exact
# activation-memory patches (per-block evaluation and chunked triangle ops).
# mac-af3's fit: peak ≈ 2.24 GB + 34 KB·N², about 16 GB at N = 640.
LEAN_ABOVE_TOKENS = {"compact": 0, "standard": 640, "large": 1024}


def runtime_config(tier: str, cache_gb: float) -> dict:
    """mac-af3 configuration keys for this Mac (see mac-af3's configs/)."""
    base = {
        "precision": "float32",  # bf16 does not lower the peak (mac-af3 C1)
        "fast_sampler": True,
        "sampler": "af3",
        "bucket_step": 64,
        "mlx_cache_limit_gb": cache_gb,
    }
    if tier == "compact":
        # 16 GB: mac-af3's L_LAYER_FULL — layer streaming plus lean activations.
        base.update(
            weight_streaming="layer",
            prefetch=2,
            release_ccd=True,
            eval_per_block=True,
            confidence_eval_per_sample=True,
            grid_attn_chunk=16,
            tri_mul_chunk=32,
            opm_chunk=64,
            transition_chunk=64,
        )
    else:
        # Keep the 3.3 GB chemical-components dictionary between jobs: reloading
        # it costs about 3 s per featurisation on a warm worker.
        base.update(weight_streaming="none", release_ccd=False)
    return base


def load(channel):
    for path, what in (
        (AF3 / "src" / "alphafold3_mlx", "alphafold3-mac"),
        (MAC_AF3 / "core" / "scripts" / "mac_af3_patches.py", "mac-af3"),
    ):
        if not path.exists():
            raise WorkerFailure(
                f"{what} is not installed ({path} is missing).",
                hint="Open Library and choose Install for AlphaFold 3.",
                not_ready=True,
            )
    if not (WEIGHTS / "af3.bin.zst").exists():
        raise WorkerFailure(
            f"AlphaFold 3 weights not found in {WEIGHTS}.",
            hint="AlphaFold 3 runs on your own copy of the official weights (af3.bin.zst). "
            f"Put it in {WEIGHTS}; Dimitri never downloads it.",
            not_ready=True,
        )
    for path in (
        AF3 / "src",
        MAC_AF3 / "core" / "scripts",
        MAC_AF3 / "tracks" / "weight-streaming" / "src",
    ):
        sys.path.insert(0, str(path))

    channel.progress(None, 0.1, "Importing MLX and AlphaFold 3")
    started = time.perf_counter()
    import mlx.core as mx
    from alphafold3_mlx import ModelConfig
    from alphafold3_mlx.core import DiffusionConfig, GlobalConfig

    import lean
    import mac_af3_patches
    import streaming

    import_s = time.perf_counter() - started

    info_fn = getattr(mx, "device_info", None) or mx.metal.device_info
    device = info_fn()
    recommended = int(device.get("max_recommended_working_set_size", 0))
    budget = memory_budget_bytes()
    if budget:
        mx.set_memory_limit(budget)
    cache_gb = float(os.environ.get("DIMITRI_MLX_CACHE_GB", "1.0"))
    tier = ARGS.tier if ARGS.tier in LEAN_ABOVE_TOKENS else "standard"
    cfg = runtime_config(tier, cache_gb)
    if cfg["weight_streaming"] != "none":
        shard_dir = streaming.default_shard_dir(WEIGHTS)
        if not (shard_dir / "manifest.json").exists():
            # Without mac-af3's shards, fall back to resident weights.
            cfg.update(weight_streaming="none")
            channel.log("mac-af3 shards not found; loading all weights resident")

    channel.progress(None, 0.4, "Loading AlphaFold 3 weights")
    t0 = time.perf_counter()
    mac_af3_patches.apply_pre_build(cfg)
    streaming.install()
    config = ModelConfig(
        diffusion=DiffusionConfig(num_samples=5, num_steps=20),
        global_config=GlobalConfig(precision=cfg["precision"], use_compile=True),
    )
    try:
        model = streaming.build_model(config, cfg, WEIGHTS)
    except FileNotFoundError as exc:
        raise WorkerFailure(str(exc), hint="Run AlphaFold 3 setup again.", not_ready=True) from exc
    mac_af3_patches.apply_post_build(model, cfg)
    mx.set_cache_limit(int(cache_gb * 1024**3))
    gc.collect()
    mx.clear_cache()
    load_s = time.perf_counter() - t0

    state = {
        "mx": mx,
        "model": model,
        "cfg": cfg,
        "tier": tier,
        "lean": lean,
        "lean_defaults": dict(lean.LEAN),
        "patches": mac_af3_patches,
        "streaming": streaming,
    }
    info = {
        "device": "mlx",
        "mlx": mx.__version__,
        "tier": tier,
        "weight_streaming": cfg["weight_streaming"],
        "import_s": round(import_s, 2),
        "weights_load_s": round(load_s, 2),
        "load_s": round(import_s + load_s, 2),
        "recommended_working_set_gb": round(recommended / 1024**3, 2) if recommended else None,
        "gpu_budget_gb": round(budget / 1024**3, 1) if budget else None,
        "mlx_cache_limit_gb": cache_gb,
    }
    return state, info


def entity(entity_type: str, sequence: str) -> dict:
    """One chain, single-sequence: empty MSAs and no templates skip the data pipeline."""
    if entity_type == "protein":
        return {
            "protein": {
                "id": "A",
                "sequence": sequence,
                "unpairedMsa": "",
                "pairedMsa": "",
                "templates": [],
            }
        }
    if entity_type == "rna":
        return {"rna": {"id": "A", "sequence": sequence, "unpairedMsa": ""}}
    if entity_type == "dna":
        return {"dna": {"id": "A", "sequence": sequence}}
    smiles_markers = set("()[]=#@+-/\\%.")
    if set(sequence) & smiles_markers or any(c.islower() for c in sequence):
        return {"ligand": {"id": "L", "smiles": sequence}}
    return {"ligand": {"id": "L", "ccdCodes": [sequence]}}


def predict(state, request, channel):
    mx = state["mx"]
    model = state["model"]
    cfg = state["cfg"]
    patches = state["patches"]
    streaming = state["streaming"]
    from alphafold3_mlx.pipeline.cli import CLIArguments
    from alphafold3_mlx.pipeline.input_handler import parse_input_json, validate_input
    from alphafold3_mlx.pipeline.output_handler import OutputBundle, create_output_directory
    from alphafold3_mlx.pipeline.ranking import auto_detect_complex
    from alphafold3_mlx.pipeline.runner import InferenceRunner

    job = request["request"]
    workdir = Path(request["workdir"])
    samples = int(job.get("samples", 5))
    steps = int(job.get("diffusion_steps", 20))
    seed = int(job.get("seed", 1))
    payload = {
        "name": job.get("name") or "dimitri",
        "modelSeeds": [seed],
        "dialect": "alphafold3",
        "version": 2,
        "sequences": [entity(job["entity_type"], job["sequence"])],
    }
    input_path = workdir / "input.json"
    input_path.write_text(json.dumps(payload, indent=2), encoding="utf-8")
    out_dir = workdir / "af3-out"

    channel.progress("features", 0.05, "Featurising (single sequence, no MSA search)")
    t0 = time.perf_counter()
    fold_input = parse_input_json(input_path)
    problems = validate_input(fold_input)
    if problems:
        raise WorkerFailure("AlphaFold 3 rejected the input: " + "; ".join(map(str, problems))[:400])
    cli = CLIArguments(
        input_path=input_path,
        output_dir=out_dir,
        model_dir=WEIGHTS,
        num_samples=samples,
        diffusion_steps=steps,
        seed=seed,
        precision=cfg["precision"],
    )
    model.config.diffusion.num_samples = samples
    model.config.diffusion.num_steps = steps
    runner = InferenceRunner(args=cli, input_json=fold_input)
    runner._on_recycling_iteration = lambda i, n: channel.progress(
        "recycling", (i + 1) / max(1, n), f"Recycle {i + 1}/{n}"
    )
    runner._on_diffusion_step = lambda s, n: channel.progress(
        "diffusion", (s + 1) / max(1, n), f"Diffusion step {s + 1}/{n} · {samples} samples"
    )
    runner._on_confidence = lambda phase: channel.progress(
        "confidence", 0.1 if phase == "start" else 1.0, "Scoring samples"
    )
    create_output_directory(out_dir)
    bundle = OutputBundle(output_dir=out_dir)
    bundle.initialize_structure_files(samples)
    batch = runner._prepare_features()
    featurise_s = time.perf_counter() - t0
    tokens = int(batch.token_features.mask.shape[-1])

    # Large inputs on 24–36 GB Macs switch on mac-af3's exact lean patches.
    lean = state["lean"]
    lean.LEAN.update(state["lean_defaults"])
    if state["tier"] != "compact" and tokens > LEAN_ABOVE_TOKENS[state["tier"]]:
        lean.configure({"eval_per_block": True, "grid_attn_chunk": 16, "tri_mul_chunk": 32})

    if cfg.get("release_ccd"):
        streaming.release_ccd()
    patches.ASYM["asym"] = mx.array(batch.token_features.asym_id).reshape(-1)
    gc.collect()
    mx.clear_cache()
    mx.reset_peak_memory()
    channel.progress("recycling", 0.0, f"{tokens} tokens · trunk on the GPU")
    t1 = time.perf_counter()
    result, stats = runner._run_inference(model, batch)
    inference_s = time.perf_counter() - t1
    channel.progress("write", 0.2, "Ranking samples and writing structures")
    t2 = time.perf_counter()
    ranking = runner._rank_samples(result, auto_detect_complex(fold_input.chain_ids), batch)
    runner._write_outputs(result, ranking, bundle, batch, stats)
    write_s = time.perf_counter() - t2
    return {
        "out_dir": str(out_dir),
        "tokens": tokens,
        "chains": len(fold_input.chain_ids),
        "device": "mlx",
        "peak_memory_gb": round(mx.get_peak_memory() / 1024**3, 2),
        "timings": {
            "featurise_s": round(featurise_s, 2),
            "trunk_s": round(float(stats.evoformer_duration_seconds), 2),
            "diffusion_s": round(float(stats.diffusion_duration_seconds), 2),
            "confidence_s": round(float(stats.confidence_duration_seconds), 2),
            "inference_s": round(inference_s, 2),
            "write_s": round(write_s, 2),
        },
        "config": {k: cfg[k] for k in ("weight_streaming", "bucket_step", "fast_sampler")},
        "diffusion_steps": steps,
    }


def after_job(state) -> None:
    gc.collect()
    state["mx"].clear_cache()


if __name__ == "__main__":
    raise SystemExit(serve(load, predict, after_job=after_job))
