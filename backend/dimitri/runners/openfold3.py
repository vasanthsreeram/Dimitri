"""OpenFold3 on Apple Silicon through latent-spacecraft/openfold-3-mlx.

The runner uses the documented predict entry point:

    python openfold3/run_openfold.py predict \
      --query_json <json> --runner_yaml examples/example_runner_yamls/mlx_runner.yml \
      --output_dir <dir> --num_diffusion_samples <n>
"""

from __future__ import annotations

import json
import shlex
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
PROTEIN_ALPHABET = set("ACDEFGHIKLMNPQRSTVWYXBZUO")
RNA_ALPHABET = set("ACGU")
DNA_ALPHABET = set("ACGT")
RUNNER_YAML = "examples/example_runner_yamls/mlx_runner.yml"


class OpenFold3Runner(Runner):
    manifest = RunnerManifest(
        id="openfold3",
        name="OpenFold3 (MLX)",
        short_name="OpenFold3",
        version="0.3.1",
        description=(
            "The AlQuraishi lab's open reproduction of AlphaFold 3, accelerated with "
            "MLX on Apple Silicon. Protein, RNA and DNA chains; confidence metrics "
            "and PAE where the model reports them."
        ),
        entity_types=("protein", "rna", "dna"),
        source_url="https://github.com/latent-spacecraft/openfold-3-mlx",
        runtime="OpenFold3-MLX kernels on PyTorch MPS",
        device="mps",
        fallback=None,
        citation="OpenFold3-preview, AlQuraishi Lab (2025)",
        license="Apache-2.0",
        weight_note=(
            "Parameters download from OpenFold's public bucket during setup "
            "(several GB). The MLX runner also enables MSA and template search."
        ),
        requires_weights=True,
        setup_hint="Clones OpenFold3-MLX, installs PyTorch and MLX, then downloads parameters.",
        stages=(
            StageSpec("load", "Loading model"),
            StageSpec("features", "Preparing features"),
            StageSpec("fold", "Folding"),
            StageSpec("confidence", "Confidence"),
            StageSpec("write", "Writing outputs"),
        ),
    )

    def __init__(self, settings: Settings) -> None:
        self.repo = Path(settings.openfold3_repo).expanduser()
        self.cache = Path(settings.openfold3_cache).expanduser()

    @property
    def python(self) -> Path:
        return self.repo / ".venv" / "bin" / "python"

    def parameter_root(self) -> Path | None:
        root_file = self.cache / "ckpt_root"
        if root_file.exists():
            try:
                return Path(root_file.read_text().strip()).expanduser()
            except OSError:
                return None
        return self.cache if self.cache.exists() else None

    def parameters_present(self) -> bool:
        root = self.parameter_root()
        if not root or not root.exists():
            return False
        for pattern in ("*.pt", "*.pth", "*.ckpt", "*/*.pt"):
            for path in root.glob(pattern):
                if path.is_file() and path.stat().st_size > 10_000_000:
                    return True
        return (root / "ckpt_root").exists() and any(root.glob("*/*.pt"))

    def status(self, settings: Settings) -> RunnerStatusModel:
        checkout = (self.repo / "openfold3" / "run_openfold.py").exists()
        env_ready = self.python.exists()
        installed = checkout and env_ready
        weights = self.parameters_present()
        if not checkout:
            detail = f"Not installed. Expected checkout at {self.repo}."
        elif not env_ready:
            detail = "Checkout found, but the Python environment is missing."
        elif not weights:
            detail = "Installed. Parameters missing; run setup to download them."
        else:
            detail = "Ready."
        return RunnerStatusModel(
            id=self.manifest.id,
            installed=installed,
            ready=installed and weights,
            weights_present=weights,
            detail=detail,
            paths={
                "repo": str(self.repo),
                "weights": str(self.parameter_root() or self.cache),
            },
        )

    def install(
        self, settings: Settings, progress: ProgressFn, control: JobControl
    ) -> InstallResult:
        progress("setup", 0.05, "Installing OpenFold3-MLX")
        self.repo.parent.mkdir(parents=True, exist_ok=True)
        log = LogBuffer()
        run_command(
            ["bash", str(SETUP_DIR / "openfold3.sh"), str(self.repo), str(self.cache)],
            cwd=self.repo.parent,
            env=None,
            control=control,
            on_line=log.add,
            label="OpenFold3 setup",
        )
        progress("setup", 1.0, "Setup complete")
        if not self.parameters_present():
            return InstallResult(
                message="OpenFold3-MLX is installed but parameters were not found.",
                hint=f"Re-run setup, or download parameters into {self.cache}.",
            )
        return InstallResult(message="OpenFold3-MLX is installed and ready.")

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
                status.detail, hint="Open Library, select OpenFold3 and choose Install."
            )
        if not status.weights_present:
            raise RunnerNotReady(
                "OpenFold3 parameters are missing.",
                hint="Open Library and run OpenFold3 setup to download them.",
            )
        sequence = request.sequence
        alphabet = {
            "protein": PROTEIN_ALPHABET,
            "rna": RNA_ALPHABET,
            "dna": DNA_ALPHABET,
        }[request.entity_type]
        bad = set(sequence) - alphabet
        if bad:
            raise RunnerError(
                f"Invalid {request.entity_type} characters: {''.join(sorted(bad))}"
            )

        query = {
            "seeds": [request.seed],
            "queries": {
                "query": {
                    "chains": [
                        {
                            "molecule_type": request.entity_type,
                            "chain_ids": ["A"],
                            "sequence": sequence,
                        }
                    ]
                }
            },
        }
        query_path = workdir / "query.json"
        query_path.write_text(json.dumps(query, indent=2), encoding="utf-8")
        out_dir = workdir / "openfold3-out"
        out_dir.mkdir(parents=True, exist_ok=True)
        env = {
            "PATH": f"{self.repo / '.venv' / 'bin'}:/opt/homebrew/bin:/usr/bin:/bin",
            "HOME": str(Path.home()),
            "OPENFOLD_CACHE": str(self.cache),
            "PYTHONUNBUFFERED": "1",
            "TMPDIR": str(workdir / "tmp"),
        }
        (workdir / "tmp").mkdir(exist_ok=True)
        args = [
            str(self.python),
            "openfold3/run_openfold.py",
            "predict",
            "--query_json",
            str(query_path),
            "--runner_yaml",
            RUNNER_YAML,
            "--output_dir",
            str(out_dir),
            "--num_diffusion_samples",
            str(request.samples),
        ]
        progress("load", 0.2, "Loading OpenFold3")

        def on_line(line: str) -> None:
            text = line.lower()
            if "diffusion" in text or "sample" in text:
                progress("fold", 0.6, line.strip()[-120:])
            elif "msa" in text or "template" in text:
                progress("features", 0.6, line.strip()[-120:])
            elif "plddt" in text or "confidence" in text:
                progress("confidence", 0.8, line.strip()[-120:])
            elif "model" in text or "parameter" in text:
                progress("load", 0.6, line.strip()[-120:])

        run_command(
            args,
            cwd=self.repo,
            env=env,
            control=control,
            on_line=on_line,
            label="OpenFold3",
        )
        progress("write", 0.7, "Reading predictions")
        return self._collect_outputs(out_dir, request)

    def _collect_outputs(self, out_dir: Path, request) -> RunResult:
        confidences = sorted(out_dir.rglob("*_confidences*.json"))
        best_conf: dict = {}
        best_conf_path: Path | None = None
        best_plddt = -1.0
        for path in confidences:
            data = self._read_json(path)
            score = self._confidence_score(data)
            if score > best_plddt:
                best_plddt = score
                best_conf = data
                best_conf_path = path

        cif_candidates = sorted(out_dir.rglob("*.cif"))
        if not cif_candidates:
            raise RunnerError("OpenFold3 finished but wrote no CIF structure.")
        chosen = cif_candidates[0]
        if best_conf_path is not None:
            stem = best_conf_path.name.split("_confidences")[0]
            for path in cif_candidates:
                if path.name.startswith(stem):
                    chosen = path
                    break

        cif_text = chosen.read_text(encoding="utf-8", errors="replace")
        full_conf: dict = {}
        if best_conf_path is not None:
            full_path = best_conf_path.with_name(
                best_conf_path.name.replace(
                    "_confidences_aggregated.json", "_confidences.json"
                )
            )
            if full_path.exists() and full_path != best_conf_path:
                full_conf = self._read_json(full_path)
        # The CIF B-factors are per atom; averaging them per residue gives the
        # chart its residue series. The full confidence file is per atom too.
        plddt_values = self._residue_plddt_from_cif(cif_text)
        if not plddt_values:
            plddt_values = [
                float(v)
                for v in full_conf.get("plddt", [])
                if isinstance(v, (int, float))
            ]
        if not plddt_values:
            plddt_values = self._plddt_list(best_conf)

        mean_plddt = self._mean(best_conf.get("avg_plddt"), best_conf.get("mean_plddt"))
        if mean_plddt is None and plddt_values:
            mean_plddt = sum(plddt_values) / len(plddt_values)
        return RunResult(
            cif_text=cif_text,
            metrics={
                "plddt": round(mean_plddt, 2) if mean_plddt is not None else None,
                "ptm": self._metric(best_conf, "ptm"),
                "iptm": self._metric(best_conf, "iptm"),
            },
            per_residue_plddt=[round(v, 2) for v in plddt_values],
            pae=None,
            pae_note=None,
            note=(
                "OpenFold3 metrics are read from its aggregated confidence JSON. "
                "The MLX kernel set runs on PyTorch's MPS device. OpenFold3 does "
                "not write a token-level PAE matrix, so the PAE panel is empty."
            ),
            device="mps",
            extra={
                "seed": request.seed,
                "samples": request.samples,
                "source_file": chosen.name,
                "has_pde": bool(full_conf.get("pde")),
            },
        )

    @staticmethod
    def _read_json(path: Path) -> dict:
        try:
            return json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return {}

    @staticmethod
    def _confidence_score(data: dict) -> float:
        value = data.get("avg_plddt", data.get("mean_plddt"))
        try:
            return float(value)
        except (TypeError, ValueError):
            return -1.0

    @staticmethod
    def _metric(data: dict, key: str) -> float | None:
        value = data.get(key)
        try:
            return float(value) if value is not None else None
        except (TypeError, ValueError):
            return None

    @staticmethod
    def _mean(*values) -> float | None:
        for value in values:
            try:
                return float(value)
            except (TypeError, ValueError):
                continue
        return None

    @staticmethod
    def _plddt_list(data: dict) -> list[float]:
        for key in ("plddt", "token_plddt", "atom_plddts", "per_residue_plddt"):
            value = data.get(key)
            if isinstance(value, list) and value and isinstance(value[0], (int, float)):
                return [float(v) for v in value]
        return []

    @staticmethod
    def _residue_plddt_from_cif(cif_text: str) -> list[float]:
        """Average the CIF B-factors (pLDDT) per residue, in file order."""
        lines = cif_text.splitlines()
        headers: list[str] = []
        data_start = -1
        for index, line in enumerate(lines):
            stripped = line.strip()
            if stripped.startswith("_atom_site."):
                headers.append(stripped.split(".", 1)[1].strip())
            elif headers:
                if not stripped or stripped.startswith("#"):
                    continue
                if stripped.startswith("_"):
                    break
                data_start = index
                break
        if not headers or data_start < 0:
            return []

        def column(*names: str) -> int | None:
            for name in names:
                if name in headers:
                    return headers.index(name)
            return None

        res_col = column("auth_seq_id", "label_seq_id")
        b_col = column("B_iso_or_equiv")
        chain_col = column("auth_asym_id", "label_asym_id")
        if res_col is None or b_col is None:
            return []
        ordered: list[str] = []
        sums: dict[str, float] = {}
        counts: dict[str, int] = {}
        tokens: list[str] = []
        for line in lines[data_start:]:
            stripped = line.strip()
            if not stripped:
                continue
            if stripped.startswith(("#", "_", "data_")):
                break
            tokens.extend(shlex.split(line, posix=True))
            while len(tokens) >= len(headers):
                row = tokens[: len(headers)]
                del tokens[: len(headers)]
                try:
                    chain = row[chain_col] if chain_col is not None else ""
                    key = f"{chain}:{row[res_col]}"
                    value = float(row[b_col])
                except (IndexError, ValueError):
                    continue
                if key not in sums:
                    ordered.append(key)
                    sums[key] = 0.0
                    counts[key] = 0
                sums[key] += value
                counts[key] += 1
        return [round(sums[key] / counts[key], 2) for key in ordered if counts[key]]
