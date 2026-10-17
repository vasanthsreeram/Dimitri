"""Single-worker job queue with live stage updates."""

from __future__ import annotations

import queue
import threading
import time
import traceback
from pathlib import Path

from .config import Settings
from .models import (
    Job,
    PredictionRequest,
    Stage,
)
from .runners import JobControl, RunnerError, RunnerNotReady, RunnerRegistry
from .store import JobStore


class JobManager:
    def __init__(
        self,
        settings: Settings,
        store: JobStore,
        registry: RunnerRegistry,
    ) -> None:
        self.settings = settings
        self.store = store
        self.registry = registry
        self._queue: queue.Queue[Job] = queue.Queue()
        self._controls: dict[str, JobControl] = {}
        self._lock = threading.Lock()
        self._thread = threading.Thread(target=self._worker, daemon=True)
        self._thread.start()

    # ------------------------------------------------------------------ submit
    def submit_prediction(self, request: PredictionRequest) -> Job:
        try:
            runner = self.registry.get(request.model_id)
        except KeyError as exc:
            raise ValueError(f"Unknown model: {request.model_id}") from exc
        if request.entity_type not in runner.manifest.entity_types:
            raise ValueError(
                f"{runner.manifest.name} does not accept {request.entity_type} input"
            )
        stages = [
            Stage(id=spec.id, name=spec.name) for spec in runner.manifest.stages
        ]
        job = self.store.create(
            kind="predict",
            name=request.name,
            model_id=request.model_id,
            entity_type=request.entity_type,
            sequence=request.sequence,
            seed=request.seed,
            samples=request.samples,
            stages=stages,
        )
        self._queue.put(job)
        return job

    def submit_install(self, runner_id: str, name: str) -> Job:
        runner = self.registry.get(runner_id)
        job = self.store.create(
            kind="install",
            name=f"Install {name}",
            model_id=runner_id,
            entity_type="protein",
            sequence="",
            seed=0,
            samples=0,
            stages=[Stage(id="setup", name="Installing and checking weights")],
        )
        self._queue.put(job)
        return job

    def cancel(self, job_id: str) -> bool:
        with self._lock:
            control = self._controls.get(job_id)
        if control is None:
            job = self.store.get(job_id)
            if job and job.status in ("queued", "running"):
                # Queued but not started: a control is created when it starts.
                self.store.update(
                    job_id,
                    status="cancelled",
                    finished_at=time.time(),
                    error=None,
                    hint="Cancelled before it started.",
                )
                return True
            return False
        control.cancel()
        return True

    # ------------------------------------------------------------------ worker
    def _worker(self) -> None:
        while True:
            job = self._queue.get()
            if job is None:
                return
            latest = self.store.get(job.id)
            if latest is None or latest.status == "cancelled":
                continue
            control = JobControl()
            with self._lock:
                self._controls[job.id] = control
            try:
                self._execute(job, control)
            except Exception:  # never let the worker die
                self.store.update(
                    job.id,
                    status="failed",
                    finished_at=time.time(),
                    error="Internal error: " + traceback.format_exc(limit=2)[-800:],
                )
            finally:
                with self._lock:
                    self._controls.pop(job.id, None)
                self._queue.task_done()

    def _execute(self, job: Job, control: JobControl) -> None:
        runner = self.registry.get(job.model_id)
        started = time.time()
        self.store.update(
            job.id,
            status="running",
            started_at=started,
            current_stage=job.stages[0].id if job.stages else None,
        )
        total = max(1, len(job.stages))
        last_save = {"t": 0.0}

        def progress(stage_id: str, fraction: float, message: str | None) -> None:
            if control.cancelled:
                raise RunnerError("cancelled")
            current = self.store.get(job.id)
            if current is None:
                return
            stages = current.stages
            index = next(
                (i for i, stage in enumerate(stages) if stage.id == stage_id), None
            )
            if index is None:
                return
            for i, stage in enumerate(stages):
                if i < index:
                    stage.status = "done"
                    stage.progress = 1.0
                elif i == index:
                    stage.status = "running"
                    stage.progress = max(0.0, min(1.0, fraction))
                    if message:
                        stage.message = message[:200]
            overall = round(((index + fraction) / total) * 100, 1)
            log = list(current.log_tail)
            if message:
                log.append(message[:200])
                log = log[-80:]
            now = time.time()
            if now - last_save["t"] > 0.2 or fraction >= 1.0:
                last_save["t"] = now
                self.store.update(
                    job.id,
                    stages=stages,
                    progress=overall,
                    current_stage=stage_id,
                    log_tail=log,
                )

        try:
            if job.kind == "install":
                result = runner.install(self.settings, progress, control)
                if control.cancelled:
                    raise RunnerError("cancelled")
                current = self.store.get(job.id) or job
                stages = current.stages
                stages[0].status = "done"
                stages[0].progress = 1.0
                stages[0].message = result.message
                self.store.update(
                    job.id,
                    status="completed",
                    stages=stages,
                    progress=100.0,
                    finished_at=time.time(),
                    hint=result.hint,
                )
                return

            request = PredictionRequest(
                model_id=job.model_id,
                entity_type=job.entity_type,
                sequence=job.sequence,
                name=job.name,
                seed=job.seed,
                samples=job.samples,
            )
            workdir = self.store.work_dir(job.id)
            run_result = runner.run(
                request, workdir, self.settings, progress, control
            )
            if control.cancelled:
                raise RunnerError("cancelled")
            result = self.store.write_result(
                job.id,
                run_result,
                model_name=runner.manifest.name,
                duration_s=time.time() - started,
            )
            current = self.store.get(job.id) or job
            stages = current.stages
            for stage in stages:
                if stage.status != "skipped":
                    stage.status = "done"
                    stage.progress = 1.0
            self.store.update(
                job.id,
                status="completed",
                stages=stages,
                progress=100.0,
                current_stage=stages[-1].id if stages else None,
                finished_at=time.time(),
                result=result,
            )
        except RunnerNotReady as exc:
            self._fail(job.id, str(exc), getattr(exc, "hint", None))
        except RunnerError as exc:
            if str(exc) == "cancelled" or control.cancelled:
                self._cancel(job.id)
            else:
                self._fail(job.id, str(exc), None)
        except Exception as exc:  # keep the reason visible in the UI
            self._fail(
                job.id,
                f"{type(exc).__name__}: {exc}",
                None,
                detail=traceback.format_exc(limit=4)[-1200:],
            )

    def _cancel(self, job_id: str) -> None:
        self.store.update(
            job_id,
            status="cancelled",
            finished_at=time.time(),
            current_stage=None,
            error=None,
            hint="Cancelled.",
        )

    def _fail(
        self,
        job_id: str,
        message: str,
        hint: str | None,
        *,
        detail: str | None = None,
    ) -> None:
        current = self.store.get(job_id)
        stages = current.stages if current else []
        for stage in stages:
            if stage.status == "running":
                stage.status = "failed"
                stage.message = message[:200]
        error = message if not detail else f"{message}\n{detail}"
        self.store.update(
            job_id,
            status="failed",
            stages=stages,
            finished_at=time.time(),
            error=error[:2000],
            hint=hint,
        )
