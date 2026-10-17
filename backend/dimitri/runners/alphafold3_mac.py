"""AlphaFold 3 on Apple Silicon: alphafold3-mac run through mac-af3.

mac-af3 (github.com/vasanthsreeram/mac-af3, private) is the runtime. It runs
frozen, official AlphaFold 3 weights in omrikais/alphafold3-mac (MLX) and adds,
without editing that checkout: a batched, compiled diffusion sampler with an
exact denoiser cache, fine 64-token buckets, weight streaming, and exact
activation-memory patches for 16 GB Macs. Dimitri installs both checkouts
(``setup/alphafold3-mac.sh``) and drives them from a warm worker
(``workers/af3_worker.py``) that keeps the model loaded between jobs.

Weights: mac-af3 runs on the user's own copy of the official parameters
(``af3.bin.zst``, SHA-256 pinned by mac-af3) in ``~/.alphafold3/weights/model``
and builds local shards from it. Dimitri never downloads, copies or commits
them; the AlphaFold 3 model parameter terms apply.

Inputs run in single-sequence mode: no MSA search and no templates, so the
whole prediction stays on this Mac. Accuracy is lower than with MSAs,
especially for proteins, and results say so.
"""

from __future__ import annotations

import json
import re
import threading
from pathlib import Path

from ..config import Settings
from ..device import detect
from ..models import InstallResult, RunResult, RunnerStatusModel
from .base import (
    JobControl,
    LogBuffer,
    ProgressFn,
    Runner,
    RunnerError,
    RunnerManifest,
    RunnerNotReady,
    StageSpec,
    base_env,
    git_head,
    run_command,
)

WEIGHTS_TERMS_URL = (
    "https://github.com/google-deepmind/alphafold3/blob/main/WEIGHTS_TERMS_OF_USE.md"
)
WEIGHTS_SHA256 = "74d0258616917cd122f5eab6d076afe4a8930e96823851e65e4f777dfb1f33ff"
PINNED_COMMIT = "3d1ce7b"
# The 20 standard amino acids plus X (unknown). alphafold3-mac silently turns
# B, J, O, U and Z into UNK, so Dimitri rejects them instead.
PROTEIN_ALPHABET = set("ACDEFGHIKLMNPQRSTVWYX")
RNA_ALPHABET = set("ACGU")
DNA_ALPHABET = set("ACGT")
SMILES_MARKERS = set("()[]=#@+-/\\%.")
SETUP_DIR = Path(__file__).resolve().parent / "setup"
WORKER = Path(__file__).resolve().parent / "workers" / "af3_worker.py"
SINGLE_SEQUENCE_NOTE = (
    "Single-sequence mode: no MSA search and no templates, so everything stays on "
    "this Mac. AlphaFold 3 is less accurate without an MSA, especially for proteins; "
    "treat low-confidence regions with care."
)


class AlphaFold3MacRunner(Runner):
    manifest = RunnerManifest(
        id="alphafold3-mac",
        name="AlphaFold 3 (mac-af3)",
        short_name="AlphaFold 3",
        version=f"alphafold3-mac {PINNED_COMMIT} + mac-af3",
        description=(
            "Google DeepMind's all-atom structure predictor with frozen official "
            "weights, run in MLX on the Apple GPU through mac-af3: a compiled diffusion "
            "sampler, 64-token buckets, and weight streaming for 16 GB Macs. Proteins, "
            "RNA, DNA and ligands; pTM, pLDDT and PAE."
        ),
        entity_types=("protein", "rna", "dna", "ligand"),
        source_url="https://github.com/vasanthsreeram/mac-af3",
        runtime="MLX (Metal) · mac-af3",
        device="mlx",
        fallback=None,
        citation="Abramson et al., Nature 630, 493-500 (2024)",
        license="alphafold3-mac CC-BY-NC-SA 4.0; weights under the AlphaFold 3 model parameter terms",
        weight_note=(
            "AlphaFold 3 needs your own copy of the official weights (af3.bin.zst). "
            "They are not included and Dimitri cannot download them. Put the file in "
            "the weights folder; mac-af3 checks it against its pinned SHA-256 and "
            "builds a local streaming cache from it. Use is governed by the AlphaFold 3 "
            "model parameter terms."
        ),
        weight_request_url=None,
        weight_dir_key="af3_weights_dir",
        setup_hint=(
            "Clones mac-af3 (private; uses your GitHub access) and alphafold3-mac at "
            f"{PINNED_COMMIT}, builds its environment, checks your weights and builds "
            "mac-af3's weight shards. Needs the Xcode Command Line Tools."
        ),
        warm_capable=True,
        stages=(
            StageSpec("load", "Loading model"),
            StageSpec("features", "Preparing features"),
            StageSpec("recycling", "Trunk (Pairformer recycles)"),
            StageSpec("diffusion", "Diffusion sampling"),
            StageSpec("confidence", "Confidence"),
            StageSpec("write", "Writing outputs"),
        ),
    )

    def __init__(self, settings: Settings) -> None:
        self.repo = Path(settings.af3_repo).expanduser()
        self.mac_af3 = Path(settings.mac_af3_repo).expanduser()
        self.weights_dir = Path(settings.af3_weights_dir).expanduser()
        self.cache_dir = Path(settings.cache_dir).expanduser()

    # ---------------------------------------------------------------- paths
    @property
    def python(self) -> Path:
        return self.repo / ".venv" / "bin" / "python"

    def weights_file(self) -> Path | None:
        path = self.weights_dir / "af3.bin.zst"
        try:
            return path if path.stat().st_size > 100_000_000 else None
        except OSError:
            return None

    def weights_check(self, path: Path) -> bool | None:
        """True/False once the SHA-256 is known; None while it is unchecked.

        Hashing 1 GB takes about a second, so the result is cached against the
        file's size and modification time and computed off the request path.
        """
        cache = self.cache_dir / "af3-weights-check.json"
        stat = path.stat()
        key = {"path": str(path), "size": stat.st_size, "mtime": stat.st_mtime}
        try:
            saved = json.loads(cache.read_text(encoding="utf-8"))
            if {k: saved.get(k) for k in key} == key:
                return bool(saved.get("ok"))
        except (OSError, json.JSONDecodeError):
            pass
        _hash_in_background(path, key, cache)
        return None

    def mac_af3_installed(self) -> bool:
        return (self.mac_af3 / "core" / "scripts" / "mac_af3_patches.py").exists() and (
            self.mac_af3 / "tracks" / "weight-streaming" / "src" / "streaming.py"
        ).exists()

    def status(self, settings: Settings) -> RunnerStatusModel:
        af3_ready = self.python.exists() and (self.repo / "src" / "alphafold3_mlx").is_dir()
        mac_af3 = self.mac_af3_installed()
        weights = self.weights_file()
        verified = self.weights_check(weights) if weights else None
        commit = git_head(self.repo) if af3_ready else None
        if not af3_ready and not mac_af3:
            detail = "Not installed. Install sets up mac-af3 and alphafold3-mac."
        elif not mac_af3:
            detail = f"mac-af3 is missing at {self.mac_af3}. Run Install (needs access to the private repository)."
        elif not af3_ready:
            detail = f"alphafold3-mac is not set up at {self.repo}. Run Install."
        elif weights is None:
            detail = (
                "Installed. Needs your own AlphaFold 3 weights: put af3.bin.zst in "
                f"{self.weights_dir}. Dimitri cannot download them."
            )
        elif verified is False:
            detail = (
                "af3.bin.zst does not match the weights mac-af3 was built for "
                "(SHA-256 mismatch). Replace the file."
            )
        else:
            detail = "Ready. MLX on the Apple GPU through mac-af3."
            if commit and not commit.startswith(PINNED_COMMIT[:7]):
                detail += f" Note: alphafold3-mac is at {commit}; mac-af3 pins {PINNED_COMMIT}."
        installed = af3_ready and mac_af3
        return RunnerStatusModel(
            id=self.manifest.id,
            installed=installed,
            ready=installed and weights is not None and verified is not False,
            weights_present=weights is not None,
            detail=detail,
            paths={
                "repo": str(self.repo),
                "mac_af3": str(self.mac_af3),
                "weights_dir": str(self.weights_dir),
            },
            warm=bool(self.pool and self.pool.is_warm(self.manifest.id)),
            version=f"alphafold3-mac {commit}" if commit else None,
        )

    # --------------------------------------------------------------- install
    def install(
        self, settings: Settings, progress: ProgressFn, control: JobControl
    ) -> InstallResult:
        log = LogBuffer()
        step = re.compile(r"\[af3-setup\] \[(\d+)/(\d+)\] (.*)")

        def handler(line: str) -> None:
            log.add(line)
            match = step.search(line)
            if match:
                index, total = int(match.group(1)), int(match.group(2))
                progress("setup", (index - 1) / total, match.group(3)[:160])

        progress("setup", 0.02, "Preparing AlphaFold 3 (mac-af3)")
        self.repo.parent.mkdir(parents=True, exist_ok=True)
        env = base_env(extra={"PYTHONPYCACHEPREFIX": str(self.cache_dir / "pycache")})
        try:
            run_command(
                [
                    "bash",
                    str(SETUP_DIR / "alphafold3-mac.sh"),
                    str(self.repo),
                    str(self.mac_af3),
                    str(self.weights_dir),
                ],
                cwd=self.repo.parent,
                env=env,
                control=control,
                on_line=handler,
                label="AlphaFold 3 setup",
            )
        except RunnerError as exc:
            if str(exc) == "cancelled":
                raise
            reason = next(
                (l.split("ERROR:", 1)[1].strip() for l in reversed(log.text()) if "ERROR:" in l),
                None,
            )
            raise RunnerError(f"AlphaFold 3 setup failed: {reason}" if reason else str(exc)) from exc
        if self.pool is not None:
            self.pool.stop(self.manifest.id)
        progress("setup", 1.0, "Setup finished")
        if self.weights_file() is None:
            return InstallResult(
                message="mac-af3 and alphafold3-mac are installed. AlphaFold 3 still needs your weights.",
                hint=(
                    f"Put your own af3.bin.zst in {self.weights_dir}, then run setup again "
                    "to check it and build mac-af3's shards. Dimitri never downloads "
                    f"AlphaFold 3 weights (terms: {WEIGHTS_TERMS_URL})."
                ),
            )
        return InstallResult(message="AlphaFold 3 is installed through mac-af3 and ready.")

    # ------------------------------------------------------------------- run
    def worker_spec(self, settings: Settings):
        from ..workers import WorkerSpec

        profile = detect()
        env = base_env(
            self.python.parent,
            extra={
                **profile.worker_env(),
                "PYTHONPYCACHEPREFIX": str(self.cache_dir / "pycache"),
            },
        )
        return WorkerSpec(
            runner_id=self.manifest.id,
            argv=(
                str(self.python),
                str(WORKER),
                "--af3",
                str(self.repo),
                "--mac-af3",
                str(self.mac_af3),
                "--weights",
                str(self.weights_dir),
                "--tier",
                profile.tier,
            ),
            cwd=str(self.repo),
            env=tuple(sorted(env.items())),
            ready_timeout=900.0,
        )

    def run(
        self,
        request,
        workdir: Path,
        settings: Settings,
        progress: ProgressFn,
        control: JobControl,
    ) -> RunResult:
        status = self.status(settings)
        if not status.installed:
            raise RunnerNotReady(
                status.detail, hint="Open Library, select AlphaFold 3 and choose Install."
            )
        if not status.weights_present:
            raise RunnerNotReady(
                f"AlphaFold 3 weights not found in {self.weights_dir}.",
                hint=(
                    "AlphaFold 3 runs on your own copy of the official weights "
                    f"(af3.bin.zst). Put it in {self.weights_dir}; Dimitri never "
                    "downloads them."
                ),
            )
        if not status.ready:
            raise RunnerNotReady(status.detail)
        if self.pool is None:
            raise RunnerError("AlphaFold 3 needs the backend's worker pool.")
        self._validate(request.entity_type, request.sequence)
        steps = self.diffusion_steps(request.entity_type)

        def on_event(event: dict) -> None:
            progress(event.get("stage") or "load", float(event.get("fraction") or 0.0), event.get("message"))

        progress("load", 0.05, "Waiting for the AlphaFold 3 worker")
        payload = {
            "type": "predict",
            "job": workdir.parent.name,
            "workdir": str(workdir),
            "request": {
                "name": request.name,
                "entity_type": request.entity_type,
                "sequence": request.sequence,
                "seed": request.seed,
                "samples": request.samples,
                "diffusion_steps": steps,
            },
        }
        result, info = self.pool.run(self.worker_spec(settings), payload, on_event, control)
        progress("write", 0.7, "Reading predictions")
        out = self._collect_outputs(Path(result["out_dir"]), request, chains=result.get("chains"))
        timings = {k: float(v) for k, v in (result.get("timings") or {}).items()}
        if not info["warm"] and info.get("load_s") is not None:
            timings["model_load_s"] = float(info["load_s"])
        out.warm = bool(info["warm"])
        out.timings = timings
        out.peak_memory_gb = result.get("peak_memory_gb")
        out.extra.update(
            {
                "tokens": result.get("tokens"),
                "diffusion_steps": steps,
                "runtime": result.get("config"),
                "single_sequence": True,
            }
        )
        out.note = (out.note or "") + " " + SINGLE_SEQUENCE_NOTE
        progress("write", 1.0, "Exports ready")
        return out

    @staticmethod
    def diffusion_steps(entity_type: str) -> int:
        """mac-af3's lab notebook: 20 steps are within the noise band for protein
        monomers and protein-DNA; for RNA and ligands 20 is inconclusive, so those
        keep AlphaFold 3's reference 200."""
        return 20 if entity_type in ("protein", "dna") else 200

    def _validate(self, entity_type: str, sequence: str) -> None:
        if entity_type == "protein":
            bad = set(sequence) - PROTEIN_ALPHABET
            if bad:
                raise RunnerError(
                    f"Invalid protein residues: {''.join(sorted(bad))}. AlphaFold 3 takes "
                    "the 20 standard amino acids (X for unknown)."
                )
        elif entity_type == "rna":
            bad = set(sequence) - RNA_ALPHABET
            if bad:
                raise RunnerError(f"Invalid RNA bases: {''.join(sorted(bad))}")
        elif entity_type == "dna":
            bad = set(sequence) - DNA_ALPHABET
            if bad:
                raise RunnerError(f"Invalid DNA bases: {''.join(sorted(bad))}")
        elif entity_type == "ligand":
            if not re.fullmatch(r"[A-Za-z0-9@+\-\[\]()=#/\\%.]{1,2000}", sequence):
                raise RunnerError("Ligand must be a CCD code or a SMILES string")

    def _input_payload(self, request) -> dict:
        """The alphafold3-mac input the worker writes (single-sequence mode)."""
        sequence = request.sequence
        if request.entity_type == "protein":
            entity = {
                "protein": {
                    "id": "A",
                    "sequence": sequence,
                    "unpairedMsa": "",
                    "pairedMsa": "",
                    "templates": [],
                }
            }
        elif request.entity_type == "rna":
            entity = {"rna": {"id": "A", "sequence": sequence, "unpairedMsa": ""}}
        elif request.entity_type == "dna":
            entity = {"dna": {"id": "A", "sequence": sequence}}
        elif set(sequence) & SMILES_MARKERS or any(c.islower() for c in sequence):
            entity = {"ligand": {"id": "L", "smiles": sequence}}
        else:
            entity = {"ligand": {"id": "L", "ccdCodes": [sequence]}}
        return {
            "name": request.name,
            "modelSeeds": [request.seed],
            "sequences": [entity],
            "dialect": "alphafold3",
            "version": 2,
        }

    def _collect_outputs(self, out_dir: Path, request, chains: int | None = None) -> RunResult:
        # Current alphafold3-mac writes: confidence_scores.json plus
        # structure_rank_<n>.cif. Keep the DeepMind-style fallback for older
        # checkouts.
        mlx_files = sorted(out_dir.rglob("confidence_scores.json"))
        if mlx_files:
            payload = self._read_json(mlx_files[0])
            samples = payload.get("samples")
            if isinstance(samples, dict) and samples:
                best = min(
                    samples.values(),
                    key=lambda item: item.get("rank", 999)
                    if isinstance(item, dict)
                    else 999,
                )
                rank = int(best.get("rank", 1) or 1)
                candidates = sorted(out_dir.rglob("structure_rank_*.cif"))
                cif_path = out_dir / f"structure_rank_{rank}.cif"
                if not cif_path.exists():
                    cif_path = next(
                        (
                            path
                            for path in candidates
                            if path.name == f"structure_rank_{rank}.cif"
                        ),
                        candidates[0] if candidates else None,
                    )
                if cif_path is None or not cif_path.exists():
                    raise RunnerError(
                        "AlphaFold 3 finished but wrote no CIF structure."
                    )
                plddt_values = [
                    float(value)
                    for value in best.get("plddt", [])
                    if isinstance(value, (int, float))
                ]
                pae = best.get("pae")
                if not isinstance(pae, list):
                    pae = None
                mean_plddt = best.get("mean_plddt")
                if mean_plddt is None and plddt_values:
                    mean_plddt = sum(plddt_values) / len(plddt_values)
                return RunResult(
                    cif_text=cif_path.read_text(encoding="utf-8", errors="replace"),
                    metrics={
                        "plddt": round(float(mean_plddt), 2)
                        if mean_plddt is not None
                        else None,
                        "ptm": self._number(best.get("ptm")),
                        # ipTM is only defined between chains; alphafold3-mac
                        # writes 0 for a monomer, which would read as a score.
                        "iptm": self._number(best.get("iptm")) if (chains or 2) > 1 else None,
                    },
                    per_residue_plddt=[round(value, 2) for value in plddt_values],
                    pae=pae,
                    pae_note=(
                        "Predicted aligned error in Ångström (residue grid)."
                        if pae
                        else None
                    ),
                    note=(
                        "Confidence values come from AlphaFold 3 (MLX). ipTM is "
                        "reported for complexes and is null for a single chain."
                    ),
                    device="mlx",
                    extra={
                        "seed": request.seed,
                        "samples": request.samples,
                        "rank": rank,
                        "ranking_metric": payload.get("ranking_metric"),
                        "source_file": cif_path.name,
                    },
                )

        cifs = sorted(out_dir.rglob("*_model.cif"))
        if not cifs:
            cifs = sorted(out_dir.rglob("*.cif"))
        if not cifs:
            raise RunnerError(
                "AlphaFold 3 finished but wrote no CIF structure. Check the job log."
            )
        ranked = [
            path
            for path in cifs
            if "seed-" not in path.name and "sample-" not in path.name
        ]
        root_cif = ranked[0] if ranked else cifs[0]
        cif_text = root_cif.read_text(encoding="utf-8", errors="replace")

        summaries = sorted(out_dir.rglob("*_summary_confidences.json"))
        confidences = sorted(out_dir.rglob("*_confidences.json"))
        ranked_summaries = [
            path
            for path in summaries
            if "seed-" not in path.name and "sample-" not in path.name
        ]
        ranked_confidences = [
            path
            for path in confidences
            if "seed-" not in path.name and "sample-" not in path.name
        ]
        summary = self._read_json((ranked_summaries or summaries)[0]) if summaries else {}
        confidence = (
            self._read_json((ranked_confidences or confidences)[0])
            if confidences
            else {}
        )

        plddt_values: list[float] = []
        if isinstance(confidence.get("plddt"), list):
            plddt_values = [float(v) for v in confidence["plddt"]]
        atom_plddts = confidence.get("atom_plddts")
        mean_plddt = (
            sum(float(v) for v in atom_plddts) / len(atom_plddts)
            if atom_plddts
            else (sum(plddt_values) / len(plddt_values) if plddt_values else None)
        )
        pae = confidence.get("pae")
        if not isinstance(pae, list):
            pae = None

        ptm = summary.get("ptm")
        iptm = summary.get("iptm")
        return RunResult(
            cif_text=cif_text,
            metrics={
                "plddt": round(mean_plddt, 2) if mean_plddt is not None else None,
                "ptm": self._number(ptm),
                "iptm": self._number(iptm),
            },
            per_residue_plddt=[round(v, 2) for v in plddt_values],
            pae=pae,
            pae_note="Predicted aligned error in Ångström (token grid)." if pae else None,
            note=(
                "Confidence values come from AlphaFold 3. ipTM is reported for "
                "complexes and is null for a single chain."
            ),
            device="mlx",
            extra={
                "seed": request.seed,
                "samples": request.samples,
                "ranking_score": summary.get("ranking_score"),
                "source_file": root_cif.name,
            },
        )

    @staticmethod
    def _number(value) -> float | None:
        try:
            return float(value) if value is not None else None
        except (TypeError, ValueError):
            return None

    @staticmethod
    def _read_json(path: Path) -> dict:
        try:
            return json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return {}


_hashing: set[str] = set()


def _hash_in_background(path: Path, key: dict, cache: Path) -> None:
    """SHA-256 the weights once on a thread and remember the answer."""
    if str(path) in _hashing:
        return
    _hashing.add(str(path))

    def work() -> None:
        import hashlib

        try:
            digest = hashlib.sha256()
            with path.open("rb") as handle:
                for chunk in iter(lambda: handle.read(1 << 24), b""):
                    digest.update(chunk)
            cache.parent.mkdir(parents=True, exist_ok=True)
            cache.write_text(
                json.dumps({**key, "ok": digest.hexdigest() == WEIGHTS_SHA256}),
                encoding="utf-8",
            )
        except OSError:
            pass
        finally:
            _hashing.discard(str(path))

    threading.Thread(target=work, daemon=True).start()

