"""AlphaFold 3 on Apple Silicon through omrikais/alphafold3-mac.

Upstream is a separate checkout because its install is interactive and large.
We only ever invoke its documented CLI:

    PYTHONPATH=src python3 run_alphafold_mlx.py --input <json> --output_dir <dir>

Weights are gated by a DeepMind request form and are never downloaded by
Dimitri.
"""

from __future__ import annotations

import json
import re
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

WEIGHT_FORM_URL = "https://forms.gle/svvpY4u2jsHEwWYS6"
PROTEIN_ALPHABET = set("ACDEFGHIKLMNPQRSTVWYXBZUO")
RNA_ALPHABET = set("ACGU")
DNA_ALPHABET = set("ACGT")
SMILES_MARKERS = set("()[]=#@+-/\\%.0123456789")
SETUP_DIR = Path(__file__).resolve().parent / "setup"


class AlphaFold3MacRunner(Runner):
    manifest = RunnerManifest(
        id="alphafold3-mac",
        name="AlphaFold 3 (MLX)",
        short_name="AlphaFold 3",
        version="3.0.1",
        description=(
            "Google DeepMind's all-atom structure predictor, running natively on "
            "Apple Silicon through the alphafold3-mac MLX port. Proteins, RNA, DNA "
            "and ligands; pTM, ipTM, pLDDT and PAE."
        ),
        entity_types=("protein", "rna", "dna", "ligand"),
        source_url="https://github.com/omrikais/alphafold3-mac",
        citation="Abramson et al., Nature 630, 493-500 (2024)",
        license="Apache-2.0 (code); model parameters under DeepMind's terms",
        weight_note=(
            "AlphaFold 3 weights are not redistributable. Request them with "
            "DeepMind's form, then place af3.bin.zst in the weights directory. "
            "Request decisions normally take a few business days."
        ),
        weight_request_url=WEIGHT_FORM_URL,
        weight_dir_key="af3_weights_dir",
        setup_hint=(
            "Clone alphafold3-mac, then run its scripts/install.sh in Terminal. "
            "The installer is interactive and builds native extensions."
        ),
        stages=(
            StageSpec("load", "Loading model"),
            StageSpec("msa", "MSA and templates"),
            StageSpec("features", "Preparing features"),
            StageSpec("recycling", "Recycling (Evoformer)"),
            StageSpec("diffusion", "Diffusion denoising"),
            StageSpec("confidence", "Computing confidence"),
            StageSpec("write", "Writing outputs"),
        ),
    )

    def __init__(self, settings: Settings) -> None:
        self.repo = Path(settings.af3_repo).expanduser()
        self.weights_dir = Path(settings.af3_weights_dir).expanduser()

    def _python(self) -> Path:
        return self.repo / ".venv" / "bin" / "python"

    def weights_file(self) -> Path | None:
        if not self.weights_dir.exists():
            return None
        patterns = ("af3.bin.zst", "af3.bin", "af3.*.bin.zst", "af3.bin.zst.*")
        for pattern in patterns:
            for path in sorted(self.weights_dir.glob(pattern)):
                if path.is_file() and path.stat().st_size > 1_000_000:
                    return path
        return None

    def status(self, settings: Settings) -> RunnerStatusModel:
        installed = (self.repo / "run_alphafold_mlx.py").exists() and self._python().exists()
        weights = self.weights_file()
        if not installed and not self.repo.exists():
            detail = f"Not installed. Expected checkout at {self.repo}."
        elif not installed:
            detail = f"Checkout found at {self.repo}, but its Python environment is missing."
        elif weights is None:
            detail = (
                "Installed. Weights missing: request af3.bin.zst from DeepMind and "
                f"place it in {self.weights_dir}."
            )
        else:
            detail = f"Ready. Weights: {weights.name}."
        return RunnerStatusModel(
            id=self.manifest.id,
            installed=installed,
            ready=installed and weights is not None,
            weights_present=weights is not None,
            detail=detail,
            paths={"repo": str(self.repo), "weights_dir": str(self.weights_dir)},
        )

    def install(
        self, settings: Settings, progress: ProgressFn, control: JobControl
    ) -> InstallResult:
        progress("clone", 0.05, f"Preparing {self.repo}")
        self.repo.parent.mkdir(parents=True, exist_ok=True)
        log = LogBuffer()
        run_command(
            ["bash", str(SETUP_DIR / "alphafold3-mac.sh"), str(self.repo)],
            cwd=self.repo.parent,
            env=None,
            control=control,
            on_line=log.add,
            label="alphafold3-mac setup",
        )
        self.weights_dir.mkdir(parents=True, exist_ok=True)
        weights = self.weights_file()
        progress("weights", 1.0, "Checking weights")
        if weights is None:
            return InstallResult(
                message="alphafold3-mac is installed. Weights still need a request.",
                hint=(
                    f"Request af3.bin.zst at {WEIGHT_FORM_URL}, then place it in "
                    f"{self.weights_dir}. Dimitri never downloads these weights."
                ),
            )
        return InstallResult(message="alphafold3-mac is installed and ready.")

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
                status.detail,
                hint="Open Library, select AlphaFold 3 and choose Install."
            )
        if not status.weights_present:
            raise RunnerNotReady(
                f"AlphaFold 3 weights not found in {self.weights_dir}.",
                hint=(
                    f"Request af3.bin.zst at {WEIGHT_FORM_URL} and place it in "
                    f"{self.weights_dir}."
                ),
            )
        sequence = request.sequence
        self._validate(request.entity_type, sequence)
        input_path = workdir / "input.json"
        input_path.write_text(
            json.dumps(self._input_payload(request), indent=2), encoding="utf-8"
        )
        out_dir = workdir / "af3-out"
        out_dir.mkdir(parents=True, exist_ok=True)

        env = {
            "PATH": f"{self.repo / '.venv' / 'bin'}:/opt/homebrew/bin:/usr/bin:/bin",
            "PYTHONPATH": "src",
            "HOME": str(Path.home()),
            "TMPDIR": str(workdir / "tmp"),
        }
        (workdir / "tmp").mkdir(exist_ok=True)
        args = [
            str(self._python()),
            "run_alphafold_mlx.py",
            "--input",
            str(input_path),
            "--output_dir",
            str(out_dir),
            "--model_dir",
            str(self.weights_dir),
            "--num_samples",
            str(request.samples),
            "--seed",
            str(request.seed),
            "--verbose",
        ]
        progress("load", 0.2, f"Loading {status.detail}")
        log = LogBuffer()
        state = {"stage": "load"}

        def on_line(line: str) -> None:
            log.add(line)
            stage = self._stage_for(line)
            if stage and stage != state["stage"]:
                state["stage"] = stage
                progress(stage, 0.15, line.strip()[-120:])
            elif stage:
                progress(stage, min(0.95, 0.3), line.strip()[-120:])

        run_command(
            args,
            cwd=self.repo,
            env=env,
            control=control,
            on_line=on_line,
            label="AlphaFold 3",
        )
        progress("write", 0.6, "Reading predictions")
        result = self._collect_outputs(out_dir, request)
        progress("write", 1.0, "Exports ready")
        return result

    def _validate(self, entity_type: str, sequence: str) -> None:
        if entity_type == "protein":
            bad = set(sequence) - PROTEIN_ALPHABET
            if bad:
                raise RunnerError(f"Invalid protein residues: {''.join(sorted(bad))}")
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
        sequence = request.sequence
        if request.entity_type == "protein":
            entity = {"protein": {"id": "A", "sequence": sequence}}
        elif request.entity_type == "rna":
            entity = {"rna": {"id": "A", "sequence": sequence, "unpairedMsa": ""}}
        elif request.entity_type == "dna":
            entity = {"dna": {"id": "A", "sequence": sequence, "unpairedMsa": ""}}
        else:
            if set(sequence) & SMILES_MARKERS or any(c.islower() for c in sequence):
                entity = {"ligand": {"id": "L", "smiles": sequence}}
            else:
                entity = {"ligand": {"id": "L", "ccdCodes": [sequence]}}
        return {
            "name": request.name,
            "modelSeeds": [request.seed],
            "sequences": [entity],
            "dialect": "alphafold3",
            "version": 4,
        }

    @staticmethod
    def _stage_for(line: str) -> str | None:
        text = line.lower()
        if "diffusion" in text:
            return "diffusion"
        if "recycl" in text or "evoformer" in text or "trunk" in text:
            return "recycling"
        if "msa" in text or "template" in text:
            return "msa"
        if "feature" in text:
            return "features"
        if "confidence" in text or "plddt" in text:
            return "confidence"
        if "writ" in text or "saving" in text or "output" in text:
            return "write"
        if "load" in text or "weight" in text:
            return "load"
        return None

    def _collect_outputs(self, out_dir: Path, request) -> RunResult:
        cifs = sorted(out_dir.rglob("*_model.cif"))
        if not cifs:
            cifs = sorted(out_dir.rglob("*.cif"))
        if not cifs:
            raise RunnerError(
                "AlphaFold 3 finished but wrote no CIF structure. Check the job log."
            )
        root_cif = next((p for p in cifs if p.parent == out_dir), cifs[0])
        cif_text = root_cif.read_text(encoding="utf-8", errors="replace")

        summaries = sorted(out_dir.glob("*_summary_confidences.json"))
        confidences = sorted(out_dir.glob("*_confidences.json"))
        summary = self._read_json(summaries[0]) if summaries else {}
        confidence = self._read_json(confidences[0]) if confidences else {}

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
                "ptm": float(ptm) if ptm is not None else None,
                "iptm": float(iptm) if iptm is not None else None,
            },
            per_residue_plddt=[round(v, 2) for v in plddt_values],
            pae=pae,
            pae_note="Predicted aligned error in Ångström (token grid)." if pae else None,
            note=(
                "Confidence values come from AlphaFold 3. ipTM is reported for "
                "complexes and is null for a single chain."
            ),
            extra={
                "seed": request.seed,
                "samples": request.samples,
                "ranking_score": summary.get("ranking_score"),
                "source_file": root_cif.name,
            },
        )

    @staticmethod
    def _read_json(path: Path) -> dict:
        try:
            return json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return {}
