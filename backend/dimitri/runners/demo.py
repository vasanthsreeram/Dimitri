"""Synthetic runner used by the test suite.

It fabricates a plausible-looking structure so the whole job pipeline (stages,
SSE, exports, charts) can be exercised without model weights. It is deliberately
marked ``visible=False`` and is never offered in the user-facing catalog.
"""

from __future__ import annotations

import math
import random
from pathlib import Path

from ..config import Settings
from ..models import InstallResult, RunResult, RunnerStatusModel
from .base import (
    JobControl,
    ProgressFn,
    Runner,
    RunnerManifest,
    StageSpec,
)

_RESIDUES = {
    "protein": "ALA",
    "rna": "A",
    "dna": "DA",
    "ligand": "LIG",
}


class DemoRunner(Runner):
    manifest = RunnerManifest(
        id="demo",
        name="Dimitri Demo",
        short_name="Demo",
        version="0.1.0",
        description=(
            "Synthetic structure generator for tests and interface development. "
            "It does not predict anything."
        ),
        entity_types=("protein", "rna", "dna", "ligand"),
        source_url="https://github.com/vasanthsreeram/Dimitri",
        # Synthetic tests only. It never touches a model runtime or a GPU.
        runtime="Synthetic (tests only)",
        device="cpu",
        fallback=None,
        stages=(
            StageSpec("validate", "Validating input"),
            StageSpec("fold", "Folding"),
            StageSpec("confidence", "Confidence"),
            StageSpec("write", "Writing outputs"),
        ),
        requires_weights=False,
        visible=False,
    )

    def status(self, settings: Settings) -> RunnerStatusModel:
        return RunnerStatusModel(
            id=self.manifest.id,
            installed=True,
            ready=True,
            weights_present=True,
            detail="Synthetic test runner",
        )

    def install(
        self, settings: Settings, progress: ProgressFn, control: JobControl
    ) -> InstallResult:
        return InstallResult(message="Nothing to install")

    def run(
        self,
        request,
        workdir: Path,
        settings: Settings,
        progress: ProgressFn,
        control: JobControl,
    ) -> RunResult:
        sequence = "".join(request.sequence.split())
        n = len(sequence)
        rng = random.Random(request.seed)
        progress("validate", 1.0, f"{n} residues")
        if control.cancelled:
            return RunResult(note="cancelled")

        coords, plddt = self._backbone(request.entity_type, n, request.seed)
        progress("fold", 0.5, "Building backbone")
        progress("fold", 1.0, "Relaxing clashes")

        mean_plddt = round(sum(plddt) / max(1, len(plddt)), 2)
        ptm = round(min(0.95, 0.15 + 0.8 * mean_plddt / 100), 3)
        pae = self._pae(n, rng)
        progress("confidence", 1.0, f"mean pLDDT {mean_plddt}")

        pdb = self._pdb(request.entity_type, n, coords, plddt)
        progress("write", 1.0, "structure.pdb")
        return RunResult(
            pdb_text=pdb,
            metrics={"plddt": mean_plddt, "ptm": ptm, "iptm": None},
            per_residue_plddt=[round(v, 2) for v in plddt],
            pae=pae,
            pae_note="Synthetic PAE from the demo runner.",
            note="Synthetic structure from the Dimitri demo runner. Not a prediction.",
            device="cpu",
            extra={"seed": request.seed, "samples": request.samples},
        )

    @staticmethod
    def _backbone(entity_type: str, n: int, seed: int):
        rng = random.Random(seed * 7919 + n)
        coords: list[tuple[float, float, float]] = []
        if entity_type == "ligand":
            for i in range(n):
                coords.append((i * 1.4, 0.6 if i % 2 else -0.6, 0.2 * math.sin(i)))
        else:
            rise = 1.5 if entity_type == "protein" else 2.8
            for i in range(n):
                angle = math.radians(100 * i)
                coords.append(
                    (2.3 * math.cos(angle), 2.3 * math.sin(angle), rise * i - rise * n / 2)
                )
        plddt: list[float] = []
        for i in range(n):
            base = 96 - 42 * (i / max(1, n - 1))
            wobble = 6 * math.sin(i / 7.0) + rng.uniform(-3, 3)
            if n > 40 and n // 3 < i < n // 3 + 6:
                base -= 22
            plddt.append(max(18.0, min(99.0, base + wobble)))
        return coords, plddt

    @staticmethod
    def _pae(n: int, rng: random.Random) -> list[list[float]]:
        stride = max(1, math.ceil(n / 300))
        idx = list(range(0, n, stride))
        matrix: list[list[float]] = []
        for i in idx:
            row: list[float] = []
            for j in idx:
                value = 1.4 + abs(i - j) * 0.22 + rng.uniform(0, 2.2)
                row.append(round(min(30.0, value), 2))
            matrix.append(row)
        return matrix

    @staticmethod
    def _pdb(
        entity_type: str,
        n: int,
        coords: list[tuple[float, float, float]],
        plddt: list[float],
    ) -> str:
        atom_name = "CA" if entity_type == "protein" else (
            "P" if entity_type in ("rna", "dna") else "C1"
        )
        element = "C" if atom_name.startswith("C") else "P"
        name_field = f" {atom_name:<3}"
        resname = _RESIDUES.get(entity_type, "UNK")
        lines: list[str] = []
        serial = 1
        for i, ((x, y, z), b) in enumerate(zip(coords, plddt), start=1):
            resname_i = resname
            if entity_type == "rna":
                resname_i = "AUCG"[(i - 1) % 4]
            elif entity_type == "dna":
                resname_i = "DA" if i % 2 else "DT"
            # Standard PDB columns: name 13-16, altLoc 17, resName 18-20,
            # chain 22, resSeq 23-26, iCode 27, x/y/z 31-54.
            lines.append(
                f"ATOM  {serial:5d} {name_field} {resname_i:>3} A{i:4d}    "
                f"{x:8.3f}{y:8.3f}{z:8.3f}{1.00:6.2f}{b:6.2f}"
                f"          {element:>2}"
            )
            serial += 1
        lines.append("END")
        return "\n".join(lines) + "\n"
