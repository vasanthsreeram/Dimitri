"""RhoFold+ (RNA) on Apple Silicon through rhofold-mac.

rhofold-mac (github.com/vasanthsreeram/rhofold-mac) is the installed
dependency: Dimitri clones it and runs its own ``./setup.sh`` (pinned PyTorch
in .venv, upstream ml4bio/RhoFold at a fixed commit with rhofold-mac's speed
patch, checksummed weights from Hugging Face) and ``./doctor.sh``. Nothing
from it is vendored here. Its MLX path stays off.

Predictions run in a warm worker (``workers/rhofold_worker.py``) that imports
rhofold-mac's code in its own environment, keeps the model on the Apple GPU
between jobs and writes the same files as ``./run.sh``. If the worker cannot
start, the runner falls back to rhofold-mac's ``./run.sh`` for that job.
"""

from __future__ import annotations

import json
import re
import time
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

REPO_URL = "https://github.com/vasanthsreeram/rhofold-mac.git"
WORKER = Path(__file__).resolve().parent / "workers" / "rhofold_worker.py"
WEIGHTS_RELATIVE = Path("RhoFold") / "pretrained" / "RhoFold_pretrained.pt"
RNA_BASES = set("AUGC")
NOTE = (
    "RhoFold+ reports pLDDT only; pTM, ipTM and PAE are not defined for this model. "
    "Single-sequence mode (no MSA search) and no Amber relaxation, as in rhofold-mac."
)


class RhoFoldRunner(Runner):
    manifest = RunnerManifest(
        id="rhofold",
        name="RhoFold+ (rhofold-mac)",
        short_name="RhoFold+",
        version="rhofold-mac",
        description=(
            "RNA 3D structure prediction (Shen et al., Nature Methods 2024) through "
            "rhofold-mac: the official RhoFold+ model on the Apple GPU with PyTorch "
            "MPS. Single-sequence mode; per-residue pLDDT and secondary structure. "
            "RhoFold+ does not report pTM, ipTM or PAE."
        ),
        entity_types=("rna",),
        source_url="https://github.com/vasanthsreeram/rhofold-mac",
        runtime="PyTorch MPS (rhofold-mac)",
        device="mps",
        fallback="CPU (last resort)",
        citation="Shen et al., Nature Methods 21, 2287-2298 (2024)",
        license="Apache-2.0",
        weight_note=(
            "Setup runs rhofold-mac's ./setup.sh, which downloads the public RhoFold+ "
            "weights (about 508 MB) from huggingface.co/cuhkaih/rhofold and checks "
            "their SHA-256."
        ),
        weight_dir_key=None,
        requires_weights=True,
        setup_hint="Clones rhofold-mac and runs its ./setup.sh and ./doctor.sh (PyTorch MPS only).",
        warm_capable=True,
        stages=(
            StageSpec("load", "Loading model"),
            StageSpec("fold", "Folding RNA (10 recycles)"),
            StageSpec("confidence", "Confidence"),
            StageSpec("write", "Writing outputs"),
        ),
    )

    def __init__(self, settings: Settings) -> None:
        self.repo = Path(settings.rhofold_repo).expanduser()

    # ---------------------------------------------------------------- paths
    @property
    def python(self) -> Path:
        return self.repo / ".venv" / "bin" / "python"

    @property
    def weights(self) -> Path:
        return self.repo / WEIGHTS_RELATIVE

    def weights_present(self) -> bool:
        # setup.sh downloads to a .part file and only moves it into place after
        # the SHA-256 check, so a file at this path has been verified once.
        try:
            return self.weights.stat().st_size > 1_000_000
        except OSError:
            return False

    def status(self, settings: Settings) -> RunnerStatusModel:
        checkout = (self.repo / "run.sh").exists() and (self.repo / "setup.sh").exists()
        env_ready = self.python.exists()
        upstream = (self.repo / "RhoFold" / "rhofold").is_dir()
        weights = self.weights_present()
        if not checkout:
            if (self.repo / "inference.py").exists():
                detail = (
                    f"{self.repo} is a plain ml4bio/RhoFold checkout. Dimitri now uses "
                    "rhofold-mac; choose Install to set it up."
                )
            else:
                detail = f"Not installed. Install sets up rhofold-mac in {self.repo}."
        elif not env_ready or not upstream:
            detail = "rhofold-mac is cloned but its ./setup.sh has not finished."
        elif not weights:
            detail = "Installed. Weights missing; run setup again to download them."
        else:
            detail = "Ready. PyTorch MPS through rhofold-mac."
        installed = checkout and env_ready and upstream
        warm = bool(self.pool and self.pool.is_warm(self.manifest.id))
        commit = git_head(self.repo) if checkout else None
        return RunnerStatusModel(
            id=self.manifest.id,
            installed=installed,
            ready=installed and weights,
            weights_present=weights,
            detail=detail,
            paths={"repo": str(self.repo), "weights": str(self.weights.parent)},
            warm=warm,
            version=f"rhofold-mac {commit}" if commit else None,
        )

    # --------------------------------------------------------------- install
    def install(
        self, settings: Settings, progress: ProgressFn, control: JobControl
    ) -> InstallResult:
        log = LogBuffer()
        self.repo.parent.mkdir(parents=True, exist_ok=True)
        env = base_env()
        if not (self.repo / ".git").exists():
            if self.repo.exists() and any(self.repo.iterdir()):
                raise RunnerError(
                    f"{self.repo} exists but is not a rhofold-mac checkout. Move it aside "
                    "or choose another RhoFold path in Settings."
                )
            progress("setup", 0.02, "Cloning rhofold-mac")
            run_command(
                ["git", "clone", "--quiet", REPO_URL, str(self.repo)],
                cwd=self.repo.parent,
                env=env,
                control=control,
                on_line=log.add,
                label="git clone rhofold-mac",
            )
        else:
            progress("setup", 0.02, "Updating rhofold-mac")
            try:
                run_command(
                    ["git", "-C", str(self.repo), "pull", "--ff-only", "--quiet"],
                    cwd=self.repo,
                    env=env,
                    control=control,
                    on_line=log.add,
                    label="git pull rhofold-mac",
                )
            except RunnerError as exc:
                if str(exc) == "cancelled":
                    raise
                log.add(f"Could not update rhofold-mac, using the current checkout: {exc}")

        steps = {
            "creating .venv": (0.08, "Creating the Python environment"),
            "installing pinned": (0.15, "Installing pinned PyTorch and dependencies"),
            "cloning upstream": (0.45, "Cloning upstream RhoFold"),
            "mac patch": (0.55, "Applying rhofold-mac's speed patch"),
            "applying rhofold-mac": (0.55, "Applying rhofold-mac's speed patch"),
            "downloading rhofold+ weights": (0.6, "Downloading RhoFold+ weights (508 MB)"),
            "weights present": (0.9, "Weights present and verified"),
            "rhofold-mac doctor": (0.94, "Running ./doctor.sh"),
        }
        percent = re.compile(r"(\d{1,3}(?:\.\d)?)%")

        def on_line(line: str) -> None:
            log.add(line)
            text = line.strip().lower()
            for key, (fraction, message) in steps.items():
                if key in text:
                    progress("setup", fraction, message)
                    return
            match = percent.search(line)
            if match and "#" in line:
                done = min(100.0, float(match.group(1))) / 100.0
                progress("setup", 0.6 + 0.3 * done, f"Downloading weights · {done:.0%}")

        progress("setup", 0.05, "Running rhofold-mac ./setup.sh")
        try:
            run_command(
                ["bash", str(self.repo / "setup.sh")],
                cwd=self.repo,
                env=env,
                control=control,
                on_line=on_line,
                label="rhofold-mac setup.sh",
            )
        except RunnerError as exc:
            if str(exc) == "cancelled":
                raise
            raise RunnerError(_setup_failure(str(exc), log.text())) from exc
        if self.pool is not None:
            self.pool.stop(self.manifest.id)  # pick up the new environment
        progress("setup", 1.0, "rhofold-mac is set up and doctor.sh says All good")
        return InstallResult(message="RhoFold+ is installed through rhofold-mac and ready.")

    # ------------------------------------------------------------------- run
    def worker_spec(self, settings: Settings):
        from ..workers import WorkerSpec

        profile = detect()
        env = base_env(self.python.parent, extra=profile.worker_env())
        env["PYTORCH_ENABLE_MPS_FALLBACK"] = "1"
        return WorkerSpec(
            runner_id=self.manifest.id,
            argv=(str(self.python), str(WORKER), "--rhofold-mac", str(self.repo)),
            cwd=str(self.repo),
            env=tuple(sorted(env.items())),
            ready_timeout=600.0,
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
                status.detail, hint="Open Library, select RhoFold+ and choose Install."
            )
        if not status.weights_present:
            raise RunnerNotReady(
                "The RhoFold+ weights are missing.",
                hint="Open Library and run RhoFold+ setup again to download them.",
            )
        sequence = request.sequence
        bad = sorted(set(sequence) - RNA_BASES)
        if bad:
            hint = " DNA? Replace T with U." if "T" in bad else ""
            raise RunnerError(
                f"RhoFold+ accepts only A, U, G and C (RNA bases). Found: "
                f"{', '.join(bad)}.{hint}"
            )

        if settings.warm_workers and self.pool is not None:
            try:
                return self._run_warm(request, workdir, settings, progress, control)
            except RunnerNotReady:
                raise
            except RunnerError as exc:
                if str(exc) == "cancelled" or control.cancelled:
                    raise
                from ..workers import WorkerError

                if not isinstance(exc, WorkerError):
                    raise
                progress("load", 0.1, "Warm worker unavailable; running rhofold-mac ./run.sh")
                result = self._run_cold(request, workdir, progress, control)
                result.note = (result.note or "") + (
                    f" The warm worker failed ({str(exc).splitlines()[0][:160]}), so this "
                    "job ran through rhofold-mac's run.sh."
                )
                return result
        return self._run_cold(request, workdir, progress, control)

    def _run_warm(self, request, workdir, settings, progress, control) -> RunResult:
        assert self.pool is not None

        def on_event(event: dict) -> None:
            stage = event.get("stage") or "load"
            progress(stage, float(event.get("fraction") or 0.0), event.get("message"))

        progress("load", 0.05, "Waiting for the RhoFold+ worker")
        payload = {
            "type": "predict",
            "job": workdir.parent.name,
            "workdir": str(workdir),
            "request": {"sequence": request.sequence, "name": request.name, "seed": request.seed},
        }
        result, info = self.pool.run(self.worker_spec(settings), payload, on_event, control)
        progress("write", 0.8, "Reading outputs")
        pdb_path = Path(result["pdb_path"])
        if not pdb_path.exists():
            raise RunnerError("RhoFold+ finished without writing a PDB.")
        timings = {k: float(v) for k, v in (result.get("timings") or {}).items()}
        if not info["warm"] and info.get("load_s") is not None:
            timings["model_load_s"] = float(info["load_s"])
        device = str(result.get("device") or info.get("device") or "mps")
        return self._result(
            pdb_text=pdb_path.read_text(encoding="utf-8", errors="replace"),
            plddt=[float(v) for v in result.get("per_residue_plddt", [])],
            mean=result.get("mean_plddt"),
            device=device,
            ct_path=Path(result.get("ct_path", "")),
            request=request,
            warm=bool(info["warm"]),
            timings=timings,
            peak=result.get("peak_memory_gb"),
        )

    def _run_cold(self, request, workdir, progress, control) -> RunResult:
        """One fresh process through rhofold-mac's own ./run.sh."""
        fasta = workdir / "input.fasta"
        fasta.write_text(f">query\n{request.sequence}\n", encoding="utf-8")
        out_dir = workdir / "rhofold-out"
        out_dir.mkdir(parents=True, exist_ok=True)
        profile = detect()
        env = base_env(self.python.parent, extra=profile.worker_env())
        lines: list[str] = []

        def on_line(line: str) -> None:
            lines.append(line)
            text = line.strip()
            if text.startswith("RhoFold+ |"):
                progress("fold", 0.2, text[:160])
            elif text.startswith("Model load"):
                progress("confidence", 0.6, text[:160])
            elif text.startswith("Wrote"):
                progress("write", 0.5, "Writing outputs")
            elif text.startswith("Error:"):
                progress("fold", 0.0, text[:160])

        progress("load", 0.2, "Starting rhofold-mac ./run.sh (cold start)")
        started = time.perf_counter()
        try:
            run_command(
                ["bash", str(self.repo / "run.sh"), str(fasta), str(out_dir)],
                cwd=self.repo,
                env=env,
                control=control,
                on_line=on_line,
                label="rhofold-mac run.sh",
            )
        except RunnerError as exc:
            if str(exc) == "cancelled":
                raise
            message = next((l[7:].strip() for l in lines if l.startswith("Error:")), None)
            raise RunnerError(message or str(exc)) from exc
        wall = time.perf_counter() - started
        info = _read_json(out_dir / "run_info.json")
        pdb_path = out_dir / "unrelaxed_model.pdb"
        if not pdb_path.exists():
            raise RunnerError("rhofold-mac finished without writing unrelaxed_model.pdb.")
        plddt = _npz_plddt(out_dir / "results.npz")
        pdb_text = pdb_path.read_text(encoding="utf-8", errors="replace")
        if plddt:
            pdb_text = rewrite_bfactors(pdb_text, plddt)
            pdb_path.write_text(pdb_text, encoding="utf-8")
        timings = {"wall_s": round(wall, 2)}
        for key in ("model_load_s", "predict_s"):
            if isinstance(info.get(key), (int, float)):
                timings[key] = float(info[key])
        return self._result(
            pdb_text=pdb_text,
            plddt=plddt,
            mean=(info.get("mean_plddt") or 0) * 100 if info.get("mean_plddt") else None,
            device=str(info.get("device") or "mps"),
            ct_path=out_dir / "ss.ct",
            request=request,
            warm=False,
            timings=timings,
            peak=None,
        )

    def _result(
        self, *, pdb_text, plddt, mean, device, ct_path, request, warm, timings, peak
    ) -> RunResult:
        dot_bracket = read_ct_dot_bracket(ct_path) if ct_path and ct_path.exists() else None
        note = NOTE
        if device != "mps":
            note += " Ran on the CPU because the Apple GPU (MPS) was unavailable."
        if mean is None and plddt:
            mean = sum(plddt) / len(plddt)
        return RunResult(
            pdb_text=pdb_text,
            metrics={"plddt": round(float(mean), 2) if mean is not None else None, "ptm": None, "iptm": None},
            per_residue_plddt=[round(v, 2) for v in plddt],
            pae=None,
            pae_note="RhoFold+ does not produce a PAE matrix.",
            note=note,
            device=device,
            warm=warm,
            timings=timings,
            peak_memory_gb=peak,
            extra={
                "seed": request.seed,
                "dot_bracket": dot_bracket,
                "runtime": "rhofold-mac",
                "single_sequence": True,
            },
        )


def rewrite_bfactors(pdb_text: str, plddt_100: list[float]) -> str:
    """Put each residue's own pLDDT (0–100) into its B-factor column.

    Upstream RhoFold's PDB writer uses the previous residue's confidence for
    each residue (an index off by one), so the file's B-factors are shifted.
    """
    out = []
    for line in pdb_text.splitlines():
        if line.startswith(("ATOM", "HETATM")) and len(line) >= 66:
            try:
                index = int(line[22:26]) - 1
            except ValueError:
                out.append(line)
                continue
            if 0 <= index < len(plddt_100):
                line = f"{line[:60]}{plddt_100[index]:6.2f}{line[66:]}"
        out.append(line)
    return "\n".join(out) + "\n"


def read_ct_dot_bracket(path: Path) -> str | None:
    """Dot-bracket string from a CT file; crossing pairs use [] then {}."""
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return None
    pairs: dict[int, int] = {}
    length = 0
    for line in lines[1:]:
        parts = line.split()
        if len(parts) < 5:
            continue
        try:
            i, j = int(parts[0]), int(parts[4])
        except ValueError:
            continue
        length = max(length, i)
        if j > 0:
            pairs[i] = j
    if not length:
        return None
    result = ["."] * length
    stacks: list[list[tuple[int, int]]] = [[], [], []]
    brackets = ("()", "[]", "{}")
    for i in range(1, length + 1):
        j = pairs.get(i, 0)
        if j <= i:
            continue
        for level, stack in enumerate(stacks):
            # Pairs are visited by increasing i, so an earlier pair (k, l)
            # crosses (i, j) exactly when k < i < l < j.
            if not any(k < i < l < j for k, l in stack):
                stack.append((i, j))
                result[i - 1] = brackets[level][0]
                result[j - 1] = brackets[level][1]
                break
    return "".join(result)


def _setup_failure(error: str, lines: list[str]) -> str:
    """Prefer rhofold-mac's own 'Error: ...' line over the exit code."""
    for line in reversed(lines):
        cleaned = re.sub(r"\x1b\[[0-9;]*m", "", line).strip()
        if cleaned.startswith("Error:"):
            return f"rhofold-mac setup failed: {cleaned[6:].strip()}"
    return error


def _read_json(path: Path) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}


def _npz_plddt(path: Path) -> list[float]:
    try:
        import numpy as np

        with np.load(path) as data:
            values = data["plddt"].reshape(-1)
        return [round(float(v) * 100.0, 2) for v in values]
    except Exception:
        return []
