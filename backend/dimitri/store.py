"""Job persistence and result artifacts."""

from __future__ import annotations

import json
import os
import shutil
import threading
import time
import uuid
from pathlib import Path

from .config import Settings
from .export import ensure_exports
from .models import Job, JobResult, Metrics, RunResult


class JobStore:
    def __init__(self, settings: Settings) -> None:
        self.settings = settings
        self._lock = threading.RLock()
        self._jobs: dict[str, Job] = {}
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
        with self._lock:
            self._jobs[job.id] = job
        self.save(job)
        return job.model_copy(deep=True)

    def save(self, job: Job) -> None:
        with self._lock:
            self._jobs[job.id] = job
            snapshot = job.model_copy(deep=True)
        directory = self.job_dir(job.id)
        directory.mkdir(parents=True, exist_ok=True)
        target = directory / "job.json"
        tmp = target.with_suffix(".json.tmp")
        tmp.write_text(snapshot.model_dump_json(indent=2), encoding="utf-8")
        os.replace(tmp, target)

    def update(self, job_id: str, **fields) -> Job | None:
        with self._lock:
            job = self._jobs.get(job_id)
            if job is None:
                return None
            for key, value in fields.items():
                setattr(job, key, value)
            snapshot = job.model_copy(deep=True)
        self.save(snapshot)
        return snapshot

    def get(self, job_id: str) -> Job | None:
        with self._lock:
            job = self._jobs.get(job_id)
            return job.model_copy(deep=True) if job else None

    def list(self, limit: int = 100) -> list[Job]:
        with self._lock:
            jobs = [job.model_copy(deep=True) for job in self._jobs.values()]
        jobs.sort(key=lambda job: job.created_at, reverse=True)
        return jobs[:limit]

    def delete(self, job_id: str) -> bool:
        with self._lock:
            removed = self._jobs.pop(job_id, None)
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
        pdb_text, cif_text, stats = ensure_exports(
            run_result.pdb_text, run_result.cif_text
        )
        (directory / "structure.pdb").write_text(pdb_text, encoding="utf-8")
        (directory / "structure.cif").write_text(cif_text, encoding="utf-8")

        plddt = list(run_result.per_residue_plddt)
        metrics = dict(run_result.metrics)
        if metrics.get("plddt") is None and plddt:
            metrics["plddt"] = round(sum(plddt) / len(plddt), 2)
        if plddt and metrics.get("plddt") is not None:
            metrics["plddt"] = round(float(metrics["plddt"]), 2)

        result = JobResult(
            model_id="",
            model_name=model_name,
            metrics=Metrics(
                plddt=metrics.get("plddt"),
                ptm=metrics.get("ptm"),
                iptm=metrics.get("iptm"),
            ),
            per_residue_plddt=plddt,
            pae=run_result.pae,
            pae_note=run_result.pae_note,
            residues=stats.residues,
            atoms=stats.atoms,
            chains=stats.chains,
            format="cif",
            duration_s=round(duration_s, 1),
            note=run_result.note,
            extra=run_result.extra,
        )
        with self._lock:
            job = self._jobs.get(job_id)
            if job is not None:
                result.model_id = job.model_id
        (directory / "result.json").write_text(
            result.model_dump_json(indent=2), encoding="utf-8"
        )
        (directory / "confidence.json").write_text(
            json.dumps(
                {
                    "metrics": result.metrics.model_dump(),
                    "per_residue_plddt": result.per_residue_plddt,
                    "pae": result.pae,
                    "note": result.note,
                },
                indent=2,
            ),
            encoding="utf-8",
        )
        return result

    def _load_existing(self) -> None:
        jobs_root = self.settings.results_path / "jobs"
        if not jobs_root.exists():
            return
        for path in jobs_root.glob("*/job.json"):
            try:
                job = Job.model_validate_json(path.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                continue
            if job.status in ("running", "queued"):
                job.status = "failed"
                job.error = "Backend restarted before this job finished."
            with self._lock:
                self._jobs[job.id] = job
