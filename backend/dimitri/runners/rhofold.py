"""RhoFold+ (RNA) on Apple Silicon via PyTorch MPS.

Wraps a checkout of ml4bio/RhoFold with Dimitri's vendored speed patch. The
checkpoint is public on Hugging Face; no gated weights are involved.
"""

from __future__ import annotations

import json
from pathlib import Path

from ..config import Settings
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
    run_command,
)

SETUP_DIR = Path(__file__).resolve().parent / "setup"
VENDOR_DIR = Path(__file__).resolve().parent / "vendor" / "rhofold"
CHECKPOINT_NAMES = ("rhofold_pretrained_params.pt", "RhoFold_pretrained.pt")


class RhoFoldRunner(Runner):
    manifest = RunnerManifest(
        id="rhofold",
        name="RhoFold+ (MPS)",
        short_name="RhoFold",
        version="1.0.0",
        description=(
            "RNA 3D structure prediction from the Shen lab, running on the Apple "
            "GPU through PyTorch MPS. Single-sequence mode by default; reports "
            "per-residue pLDDT. RhoFold does not report pTM, ipTM or PAE."
        ),
        entity_types=("rna",),
        source_url="https://github.com/ml4bio/RhoFold",
        runtime="PyTorch MPS",
        device="mps",
        fallback="CPU (last resort)",
        citation="Shen et al., Nature Methods 21, 2287-2299 (2024)",
        license="Apache-2.0",
        weight_note=(
            "The RhoFold+ checkpoint is public on Hugging Face (cuhkaih/rhofold, "
            "about 508 MB). Setup downloads it for you."
        ),
        weight_dir_key=None,
        requires_weights=True,
        setup_hint="Installs upstream RhoFold, the MPS speed patch, and the public checkpoint.",
        stages=(
            StageSpec("load", "Loading model"),
            StageSpec("fold", "Folding RNA"),
            StageSpec("confidence", "Confidence"),
            StageSpec("write", "Writing outputs"),
        ),
    )

    def __init__(self, settings: Settings) -> None:
        self.repo = Path(settings.rhofold_repo).expanduser()

    @property
    def python(self) -> Path:
        return self.repo / ".venv" / "bin" / "python"

    def checkpoint(self) -> Path | None:
        for name in CHECKPOINT_NAMES:
            path = self.repo / "pretrained" / name
            if path.exists() and path.stat().st_size > 1_000_000:
                return path
        return None

    def status(self, settings: Settings) -> RunnerStatusModel:
        installed = (self.repo / "inference.py").exists() and (self.repo / "rhofold").exists()
        env_ready = self.python.exists()
        weights = self.checkpoint()
        if not installed:
            detail = f"Not installed. Expected checkout at {self.repo}."
        elif not env_ready:
            detail = "Checkout found, but the Python environment is missing."
        elif weights is None:
            detail = "Installed. Checkpoint missing; run setup again to download it."
        else:
            detail = f"Ready. Checkpoint: {weights.name}."
        return RunnerStatusModel(
            id=self.manifest.id,
            installed=installed and env_ready,
            ready=installed and env_ready and weights is not None,
            weights_present=weights is not None,
            detail=detail,
            paths={"repo": str(self.repo), "weights": str(self.repo / "pretrained")},
        )

    def install(
        self, settings: Settings, progress: ProgressFn, control: JobControl
    ) -> InstallResult:
        progress("setup", 0.05, "Cloning RhoFold and installing dependencies")
        self.repo.parent.mkdir(parents=True, exist_ok=True)
        log = LogBuffer()
        script = SETUP_DIR / "rhofold.sh"
        run_command(
            ["bash", str(script), str(self.repo), str(VENDOR_DIR / "rhofold-mac-fast.patch")],
            cwd=self.repo.parent,
            env=None,
            control=control,
            on_line=log.add,
            label="RhoFold setup",
        )
        progress("setup", 1.0, "Setup complete")
        if self.checkpoint() is None:
            return InstallResult(
                message="RhoFold is installed but the checkpoint is missing.",
                hint=f"Re-run setup, or place the checkpoint in {self.repo / 'pretrained'}.",
            )
        return InstallResult(message="RhoFold+ is installed and ready.")

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
                status.detail, hint="Open Library, select RhoFold and choose Install."
            )
        weights = self.checkpoint()
        if weights is None:
            raise RunnerNotReady(
                "The RhoFold+ checkpoint is missing.",
                hint="Open Library and run RhoFold setup to download it.",
            )
        sequence = request.sequence
        bad = set(sequence) - set("ACGU")
        if bad:
            raise RunnerError(
                f"RhoFold accepts RNA bases A, C, G and U only. Found: {''.join(sorted(bad))}"
            )

        fasta = workdir / "input.fasta"
        fasta.write_text(f">query\n{sequence}\n", encoding="utf-8")
        out_dir = workdir / "rhofold-out"
        out_dir.mkdir(parents=True, exist_ok=True)
        script = VENDOR_DIR / "run_rhofold.py"
        env = {
            "PATH": f"{self.repo / '.venv' / 'bin'}:/opt/homebrew/bin:/usr/bin:/bin",
            "HOME": str(Path.home()),
            "RHOFOLD_FAST": "1",
            "PYTHONUNBUFFERED": "1",
            "TMPDIR": str(workdir / "tmp"),
        }
        (workdir / "tmp").mkdir(exist_ok=True)
        stage = {"id": "load"}

        def on_line(line: str) -> None:
            text = line.lower()
            if "constructing" in text or "loading" in text:
                stage["id"] = "load"
                progress("load", 0.6, line.strip()[-120:])
            elif "forward" in text or "inference" in text or "fold" in text:
                stage["id"] = "fold"
                progress("fold", 0.5, line.strip()[-120:])
            elif "plddt" in text:
                progress("confidence", 0.8, line.strip()[-120:])

        progress("load", 0.2, "Loading RhoFold")
        run_command(
            [
                str(self.python),
                str(script),
                "--repo",
                str(self.repo),
                "--weights",
                str(weights),
                "--fasta",
                str(fasta),
                "--output-dir",
                str(out_dir),
            ],
            cwd=self.repo,
            env=env,
            control=control,
            on_line=on_line,
            label="RhoFold",
        )
        metrics_path = out_dir / "rhofold_metrics.json"
        if not metrics_path.exists():
            raise RunnerError("RhoFold finished without writing metrics.")
        payload = json.loads(metrics_path.read_text(encoding="utf-8"))
        pdb_path = Path(payload.get("pdb", out_dir / "rhofold_model.pdb"))
        if not pdb_path.exists():
            raise RunnerError("RhoFold finished without writing a PDB.")
        progress("write", 1.0, "Exports ready")
        device = str(payload.get("device") or "mps")
        note = (
            "RhoFold+ reports pLDDT only; pTM and ipTM are not defined for this "
            "model. Single-sequence mode, no MSA database search."
        )
        if device != "mps":
            note += " Ran on CPU because MPS was unavailable."
        return RunResult(
            pdb_text=pdb_path.read_text(encoding="utf-8", errors="replace"),
            metrics={
                "plddt": payload.get("plddt"),
                "ptm": None,
                "iptm": None,
            },
            per_residue_plddt=[float(v) for v in payload.get("per_residue_plddt", [])],
            pae=None,
            pae_note="RhoFold+ does not produce a PAE matrix.",
            note=note,
            device=device,
            extra={
                "device": device,
                "seconds": payload.get("seconds"),
                "seed": request.seed,
            },
        )
