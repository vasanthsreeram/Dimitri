"""Job persistence and result artifacts."""

from __future__ import annotations

import json
import math
import os
import shutil
import tempfile
import threading
import time
import uuid
from collections import deque
from pathlib import Path

import gemmi

from .config import Settings
from .export import (
    StructureError,
    bfactors_are_confidence,
    detect_format,
    ensure_exports,
    plddt_scale,
    read_structure,
    residue_bfactors,
    stats_for,
    to_mmcif,
    to_pdb,
)
from .models import Job, JobResult, JobSummary, Metrics, RunResult, Stage

NATIVE_FILES = {"pdb": "structure.pdb", "cif": "structure.cif"}


class JobStore:
    """Jobs in memory, mirrored to one directory per job.

    Every change bumps a version counter so live streams can send only what
    changed since a client last looked.
    """

    def __init__(self, settings: Settings) -> None:
        self.settings = settings
        self._lock = threading.RLock()
        self._jobs: dict[str, Job] = {}
        self._versions: dict[str, int] = {}
        self._deleted: deque[tuple[int, str]] = deque(maxlen=500)
        self._persisted_at: dict[str, float] = {}
        self.version = 0
        self.settings.results_path.mkdir(parents=True, exist_ok=True)
        self._load_existing()

    # ------------------------------------------------------------------ paths
    def job_dir(self, job_id: str) -> Path:
        return self.settings.results_path / "jobs" / job_id

    def work_dir(self, job_id: str) -> Path:
        path = self.job_dir(job_id) / "work"
        path.mkdir(parents=True, exist_ok=True)
        return path

    # ------------------------------------------------------------------- CRUD
    def create(
        self,
        *,
        kind: str,
        name: str,
        model_id: str,
        entity_type: str,
        sequence: str,
        seed: int,
        samples: int,
        stages: list,
    ) -> Job:
        job = Job(
            id=uuid.uuid4().hex[:12],
            kind=kind,  # type: ignore[arg-type]
            name=name,
            model_id=model_id,
            entity_type=entity_type,  # type: ignore[arg-type]
            sequence=sequence,
            seed=seed,
            samples=samples,
            stages=stages,
            created_at=time.time(),
        )
        self.save(job)
        return job.model_copy(deep=True)

    def save(self, job: Job) -> None:
        with self._lock:
            self._jobs[job.id] = job
            self._bump(job.id)
            self._persist(job.model_copy(deep=True))

    def _bump(self, job_id: str) -> None:
        self.version += 1
        self._versions[job_id] = self.version

    def _persist(self, snapshot: Job) -> None:
        directory = self.job_dir(snapshot.id)
        directory.mkdir(parents=True, exist_ok=True)
        handle = tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=directory,
            prefix=".job-",
            suffix=".json.tmp",
            delete=False,
        )
        try:
            with handle:
                handle.write(snapshot.model_dump_json(indent=2))
            os.replace(handle.name, directory / "job.json")
        finally:
            if os.path.exists(handle.name):
                os.unlink(handle.name)

    def update(self, job_id: str, *, persist: bool = True, **fields) -> Job | None:
        """Change fields of a job. Progress ticks pass ``persist=False``: they
        are streamed live but only written to disk on the next real change."""
        with self._lock:
            job = self._jobs.get(job_id)
            if job is None:
                return None
            for key, value in fields.items():
                setattr(job, key, value)
            self._bump(job_id)
            snapshot = job.model_copy(deep=True)
            if persist:
                self._persist(snapshot)
            return snapshot

    def progress(
        self,
        job_id: str,
        stage_id: str,
        fraction: float,
        message: str | None,
        *,
        persist_every: float = 2.0,
    ) -> bool:
        """Advance a running job's stages in place.

        Stages before ``stage_id`` are marked done; progress never moves
        backwards. Ticks are streamed straight away but written to disk at
        most every ``persist_every`` seconds or when the stage changes.
        """
        with self._lock:
            job = self._jobs.get(job_id)
            if job is None:
                return False
            stages = job.stages
            index = next((i for i, stage in enumerate(stages) if stage.id == stage_id), None)
            current = next(
                (i for i, stage in enumerate(stages) if stage.id == job.current_stage), 0
            )
            changed_stage = False
            if index is not None and index >= current:
                fraction = max(0.0, min(1.0, fraction))
                for i, stage in enumerate(stages):
                    if i < index:
                        stage.status = "done"
                        stage.progress = 1.0
                    elif i == index:
                        stage.status = "running"
                        stage.progress = fraction if i > current else max(stage.progress, fraction)
                        if message:
                            stage.message = message[:200]
                changed_stage = stage_id != job.current_stage
                job.current_stage = stage_id
                total = max(1, len(stages))
                job.progress = max(job.progress, round(((index + fraction) / total) * 100, 1))
            elif message and 0 <= current < len(stages):
                stages[current].message = message[:200]
            if message:
                job.log_tail.append(message[:200])
                if len(job.log_tail) > 80:
                    del job.log_tail[: len(job.log_tail) - 80]
            self._bump(job_id)
            now = time.time()
            if changed_stage or now - self._persisted_at.get(job_id, 0.0) > persist_every:
                self._persisted_at[job_id] = now
                self._persist(job.model_copy(deep=True))
            return True

    def get(self, job_id: str) -> Job | None:
        with self._lock:
            job = self._jobs.get(job_id)
            return job.model_copy(deep=True) if job else None

    def count_active(self) -> int:
        with self._lock:
            return len(
                [job for job in self._jobs.values() if job.status in ("queued", "running")]
            )

    def list(self, limit: int = 100) -> list[Job]:
        with self._lock:
            jobs = [job.model_copy(deep=True) for job in self._jobs.values()]
        jobs.sort(key=lambda job: job.created_at, reverse=True)
        return jobs[:limit]

    def summaries(self, limit: int = 500, kind: str | None = None) -> list[JobSummary]:
        with self._lock:
            jobs = [job for job in self._jobs.values() if kind is None or job.kind == kind]
            jobs.sort(key=lambda job: job.created_at, reverse=True)
            return [job.summary() for job in jobs[:limit]]

    def job_version(self, job_id: str) -> int | None:
        with self._lock:
            return self._versions.get(job_id) if job_id in self._jobs else None

    def changes_since(self, version: int) -> tuple[int, list[Job], list[str]]:
        """Jobs changed and ids deleted after ``version``."""
        with self._lock:
            changed = [
                self._jobs[job_id].model_copy(deep=True)
                for job_id, seen in self._versions.items()
                if seen > version and job_id in self._jobs
            ]
            deleted = [job_id for seen, job_id in self._deleted if seen > version]
            return self.version, changed, deleted

    def delete(self, job_id: str) -> bool:
        with self._lock:
            removed = self._jobs.pop(job_id, None)
            if removed is not None:
                self._versions.pop(job_id, None)
                self.version += 1
                self._deleted.append((self.version, job_id))
        if removed is None:
            return False
        shutil.rmtree(self.job_dir(job_id), ignore_errors=True)
        return True

    # -------------------------------------------------------------- artifacts
    def write_result(
        self,
        job_id: str,
        run_result: RunResult,
        *,
        model_name: str,
        duration_s: float,
    ) -> JobResult:
        directory = self.job_dir(job_id)
        directory.mkdir(parents=True, exist_ok=True)
        native = "cif" if run_result.cif_text is not None else "pdb"
        pdb_text, cif_text, stats = ensure_exports(run_result.pdb_text, run_result.cif_text)
        (directory / "structure.pdb").write_text(pdb_text, encoding="utf-8")
        (directory / "structure.cif").write_text(cif_text, encoding="utf-8")

        plddt = list(run_result.per_residue_plddt)
        if not plddt:
            try:
                plddt = plddt_scale(
                    residue_bfactors(read_structure(run_result.cif_text or pdb_text))
                )
            except StructureError:
                plddt = []
        metrics = dict(run_result.metrics)
        if metrics.get("plddt") is None and plddt:
            metrics["plddt"] = round(sum(plddt) / len(plddt), 2)
        if metrics.get("plddt") is not None:
            metrics["plddt"] = round(float(metrics["plddt"]), 2)

        pae = run_result.pae
        result = JobResult(
            model_id="",
            model_name=model_name,
            metrics=Metrics(
                plddt=metrics.get("plddt"),
                ptm=metrics.get("ptm"),
                iptm=metrics.get("iptm"),
            ),
            per_residue_plddt=plddt,
            pae=None,
            pae_size=len(pae) if pae else 0,
            pae_note=run_result.pae_note,
            residues=stats.residues,
            atoms=stats.atoms,
            chains=stats.chains,
            models=stats.models,
            polymer_types=list(stats.polymer_types),
            format=native,  # type: ignore[arg-type]
            has_confidence=bool(plddt) or metrics.get("plddt") is not None,
            device=run_result.device,
            duration_s=round(duration_s, 1),
            warm=run_result.warm,
            timings=run_result.timings,
            peak_memory_gb=run_result.peak_memory_gb,
            note=run_result.note,
            extra=run_result.extra,
        )
        with self._lock:
            job = self._jobs.get(job_id)
            if job is not None:
                result.model_id = job.model_id
        export = result.model_copy(update={"pae": pae})
        (directory / "result.json").write_text(
            export.model_dump_json(indent=2), encoding="utf-8"
        )
        (directory / "confidence.json").write_text(
            json.dumps(
                {
                    "metrics": result.metrics.model_dump(),
                    "per_residue_plddt": result.per_residue_plddt,
                    "pae": pae,
                    "note": result.note,
                },
            ),
            encoding="utf-8",
        )
        return result

    def structure(self, job_id: str) -> tuple[str, str] | None:
        """The native structure text and its format ('pdb' or 'mmcif')."""
        job = self.get(job_id)
        if job is None or job.result is None:
            return None
        directory = self.job_dir(job_id)
        path = directory / NATIVE_FILES.get(job.result.format, "structure.cif")
        if not path.exists():
            path = directory / "structure.cif"
        if not path.exists():
            return None
        text = path.read_text(encoding="utf-8", errors="replace")
        return text, detect_format(text)

    def pae(self, job_id: str, max_cells: int = 256) -> tuple[int, int, list[list[float]]] | None:
        """PAE downsampled by block averaging to at most ``max_cells`` per axis."""
        path = self.job_dir(job_id) / "confidence.json"
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return None
        matrix = payload.get("pae")
        if not isinstance(matrix, list) or not matrix:
            return None
        size = len(matrix)
        stride = max(1, math.ceil(size / max(8, max_cells)))
        if stride == 1:
            return size, 1, [[round(float(v), 2) for v in row] for row in matrix]
        reduced: list[list[float]] = []
        for i in range(0, size, stride):
            rows = matrix[i : i + stride]
            out_row: list[float] = []
            for j in range(0, size, stride):
                block = [float(v) for row in rows for v in row[j : j + stride]]
                out_row.append(round(sum(block) / len(block), 2) if block else 0.0)
            reduced.append(out_row)
        return size, stride, reduced

    # ----------------------------------------------------------------- import
    def import_structure(self, filename: str, text: str, name: str | None = None) -> Job:
        """Store a dropped PDB/mmCIF file as a completed, comparable result."""
        fmt = detect_format(text)
        structure = read_structure(text, fmt)
        stats = stats_for(structure)
        entity_type, sequence = _first_polymer_sequence(structure)
        confidence = bfactors_are_confidence(structure, text)
        plddt = plddt_scale(residue_bfactors(structure)) if confidence else []
        native = "pdb" if fmt == "pdb" else "cif"
        title = (name or Path(filename).stem or "Imported structure").strip()[:120]

        job = Job(
            id=uuid.uuid4().hex[:12],
            kind="import",
            name=title,
            model_id="import",
            entity_type=entity_type,  # type: ignore[arg-type]
            sequence=sequence,
            seed=0,
            samples=1,
            status="completed",
            progress=100.0,
            current_stage="import",
            stages=[Stage(id="import", name="Imported", status="done", progress=1.0)],
            created_at=time.time(),
            started_at=time.time(),
            finished_at=time.time(),
        )
        directory = self.job_dir(job.id)
        directory.mkdir(parents=True, exist_ok=True)
        if native == "pdb":
            (directory / "structure.pdb").write_text(text, encoding="utf-8")
            (directory / "structure.cif").write_text(to_mmcif(structure), encoding="utf-8")
        else:
            (directory / "structure.cif").write_text(text, encoding="utf-8")
            (directory / "structure.pdb").write_text(to_pdb(structure), encoding="utf-8")
        mean = round(sum(plddt) / len(plddt), 2) if plddt else None
        note = (
            "Imported file. B-factors look like pLDDT (0–100), so they are shown as confidence."
            if confidence
            else "Imported file. Its B-factors are not prediction confidence (experimental "
            "structure or none recorded), so no pLDDT is shown."
        )
        job.result = JobResult(
            model_id="import",
            model_name="Imported structure",
            metrics=Metrics(plddt=mean),
            per_residue_plddt=plddt,
            residues=stats.residues,
            atoms=stats.atoms,
            chains=stats.chains,
            models=stats.models,
            polymer_types=list(stats.polymer_types),
            format=native,  # type: ignore[arg-type]
            has_confidence=confidence,
            note=note,
            extra={"source_file": filename},
        )
        (directory / "result.json").write_text(job.result.model_dump_json(indent=2), encoding="utf-8")
        (directory / "confidence.json").write_text(
            json.dumps({"metrics": job.result.metrics.model_dump(), "per_residue_plddt": plddt, "pae": None}),
            encoding="utf-8",
        )
        self.save(job)
        return job.model_copy(deep=True)

    def _load_existing(self) -> None:
        jobs_root = self.settings.results_path / "jobs"
        if not jobs_root.exists():
            return
        for path in jobs_root.glob("*/job.json"):
            try:
                job = Job.model_validate_json(path.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                continue
            changed = False
            if job.status in ("running", "queued"):
                job.status = "failed"
                job.finished_at = time.time()
                job.error = "Backend restarted before this job finished."
                for stage in job.stages:
                    if stage.status == "running":
                        stage.status = "failed"
                        stage.progress = 0.0
                changed = True
            if job.result is not None and job.result.pae:
                # Older records embedded the PAE matrix; it lives in confidence.json.
                job.result.pae_size = len(job.result.pae)
                job.result.pae = None
                changed = True
            with self._lock:
                self._jobs[job.id] = job
                self._bump(job.id)
                if changed:
                    self._persist(job)


_ONE_LETTER_NUCLEIC = {"A": "A", "C": "C", "G": "G", "U": "U", "DA": "A", "DC": "C", "DG": "G", "DT": "T"}


def _first_polymer_sequence(structure: gemmi.Structure) -> tuple[str, str]:
    """Entity type and one-letter sequence of the first polymer chain."""
    for chain in structure[0]:
        polymer = chain.get_polymer()
        if len(polymer) == 0:
            continue
        kind = polymer.check_polymer_type()
        if kind in (gemmi.PolymerType.Rna, gemmi.PolymerType.Dna):
            entity = "rna" if kind == gemmi.PolymerType.Rna else "dna"
            sequence = "".join(_ONE_LETTER_NUCLEIC.get(res.name, "N") for res in polymer)
            return entity, sequence
        sequence = gemmi.one_letter_code([res.name for res in polymer]).upper()
        return "protein", sequence
    return "ligand", ""
