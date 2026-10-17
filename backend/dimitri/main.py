"""FastAPI application for Dimitri Studio."""

from __future__ import annotations

import asyncio
import json
import platform
import re
import sys
import threading
import time
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any, AsyncIterator

import httpx
from fastapi import FastAPI, HTTPException, Query, Request
from fastapi.responses import FileResponse, JSONResponse, Response, StreamingResponse

from .catalog import CatalogService
from .config import APP_VERSION, DEFAULT_PORT, Settings
from .device import DeviceProfile, detect
from .export import StructureError, superpose
from .jobs import JobManager
from .models import (
    CatalogResponse,
    CompareResponse,
    CreateJobResponse,
    CreateJobsRequest,
    CreateJobsResponse,
    DeviceInfo,
    DiskUsage,
    ImportRequest,
    Job,
    JobSummary,
    LmStudioStatus,
    PaeResponse,
    PredictionRequest,
    RunnerManifestModel,
    RunnerStatusModel,
    StatusResponse,
    WorkerStatus,
)
from .runners import RunnerRegistry
from .sizes import DiskSizer
from .store import JobStore
from .workers import WorkerPool

PATH_KEYS = (
    "home",
    "models_dir",
    "results_dir",
    "cache_dir",
    "af3_repo",
    "af3_weights_dir",
    "mac_af3_repo",
    "rhofold_repo",
    "openfold3_repo",
    "openfold3_cache",
)


def _safe_stem(name: str) -> str:
    cleaned = re.sub(r"[^A-Za-z0-9._-]+", "_", name).strip("._-")
    return cleaned[:80] or "dimitri_job"


def lm_studio_status(base_url: str, timeout: float = 0.8) -> LmStudioStatus:
    url = base_url.rstrip("/") + "/models"
    try:
        response = httpx.get(url, timeout=timeout)
        response.raise_for_status()
        payload = response.json()
        data = payload.get("data") if isinstance(payload, dict) else None
        if not isinstance(data, list):
            raise ValueError("unexpected /models payload")
        models = [
            item.get("id", "")
            for item in data
            if isinstance(item, dict) and item.get("id")
        ]
        return LmStudioStatus(
            reachable=True,
            base_url=base_url,
            models=models[:20],
            detail=f"LM Studio server reachable ({len(models)} model(s)).",
        )
    except (httpx.HTTPError, ValueError, TypeError) as exc:
        return LmStudioStatus(
            reachable=False,
            base_url=base_url,
            detail=f"No LM Studio server at {base_url}: {type(exc).__name__}.",
        )


class LmStudioProbe:
    """LM Studio status refreshed in the background, never inside a request."""

    def __init__(self, base_url: str, interval: float = 20.0) -> None:
        self.base_url = base_url
        self.interval = interval
        self.value = LmStudioStatus(
            reachable=False, base_url=base_url, detail="Checking for LM Studio…"
        )
        self._wake = threading.Event()
        self._thread = threading.Thread(target=self._loop, daemon=True)
        self._thread.start()

    def refresh(self, base_url: str | None = None, wait: bool = False) -> LmStudioStatus:
        if base_url:
            self.base_url = base_url
        if wait:
            self.value = lm_studio_status(self.base_url)
            return self.value
        self._wake.set()
        return self.value

    def _loop(self) -> None:
        while True:
            self.value = lm_studio_status(self.base_url)
            self._wake.wait(self.interval)
            self._wake.clear()


class AppState:
    def __init__(self, home: Path | None = None) -> None:
        self.settings = Settings.load(home)
        self.settings.ensure_dirs()
        self.device: DeviceProfile = detect()
        self.sizer = DiskSizer()
        self.pool = WorkerPool(
            self.settings.home_path / "logs" / "workers",
            keep_warm_s=self.settings.keep_warm_seconds(self.device.keep_warm_minutes),
            max_resident=self.device.max_resident_models,
        )
        self.runners_version = 0
        self.pool.subscribe(self._runners_changed)
        self.lm_studio = LmStudioProbe(self.settings.lms_base_url)
        self.rebuild(full=True)

    def _runners_changed(self) -> None:
        self.runners_version += 1

    def rebuild(self, full: bool = True) -> None:
        """Rebuild runtime objects.

        A full rebuild recreates the store and worker and is only safe when no
        job is active. Settings changes during a running job use a partial
        rebuild so the worker and its job records stay intact. Warm model
        workers survive either way; a worker whose launch spec changed is
        restarted the next time it is used.
        """
        self.registry = RunnerRegistry(self.settings, self.pool)
        self.catalog = CatalogService(self.settings, self.registry, sizer=self.sizer)
        self.pool.configure(
            keep_warm_s=self.settings.keep_warm_seconds(self.device.keep_warm_minutes),
            max_resident=self.device.max_resident_models,
        )
        if full:
            self.store = JobStore(self.settings)
            self.manager = JobManager(self.settings, self.store, self.registry)
        else:
            self.store.settings = self.settings
            self.manager.settings = self.settings
            self.manager.registry = self.registry
        self._runners_changed()

    def storage(self) -> list[DiskUsage]:
        paths = (
            self.settings.models_path,
            self.settings.results_path,
            self.settings.cache_path,
        )
        return [
            DiskUsage(path=str(path), bytes=self.sizer.size([path]), exists=path.exists())
            for path in paths
        ]

    def device_info(self) -> DeviceInfo:
        info = self.device.info()
        minutes = self.settings.keep_warm_minutes
        if not self.settings.warm_workers:
            info.keep_warm_minutes = 0
        elif minutes is not None:
            info.keep_warm_minutes = minutes
        return info


def _job_event(job: Job) -> dict[str, Any]:
    """Live update for one job: its summary plus stages and the last log lines."""
    return {
        "summary": job.summary().model_dump(),
        "stages": [stage.model_dump() for stage in job.stages],
        "log": job.log_tail[-3:],
    }


def _sse(event: str, payload: Any) -> str:
    return f"event: {event}\ndata: {json.dumps(payload, separators=(',', ':'))}\n\n"


def create_app(home: Path | None = None) -> FastAPI:
    state = AppState(home)

    @asynccontextmanager
    async def lifespan(_: FastAPI):
        yield
        # Stop warm model workers so no Python process outlives the backend.
        await asyncio.to_thread(state.pool.shutdown)

    app = FastAPI(title="Dimitri Studio backend", version=APP_VERSION, lifespan=lifespan)
    app.state.dimitri = state

    @app.get("/api/health")
    def health() -> dict[str, Any]:
        return {
            "status": "ok",
            "app": "dimitri-studio",
            "version": APP_VERSION,
            "python": sys.version.split()[0],
            "platform": platform.platform(),
        }

    @app.get("/api/status", response_model=StatusResponse)
    def status(request: Request, refresh: bool = Query(default=False)) -> StatusResponse:
        sources = state.catalog.sources()
        lm = state.lm_studio.refresh(state.settings.lms_base_url, wait=refresh)
        return StatusResponse(
            status="ok",
            version=APP_VERSION,
            python=sys.version.split()[0],
            platform=platform.platform(),
            backend_url=str(request.base_url).rstrip("/"),
            storage=state.storage(),
            lm_studio=lm,
            runners=state.registry.statuses(),
            active_jobs=state.store.count_active(),
            bio_rodeo=sources.get("bio_rodeo", {}),
            device=state.device_info(),
            workers=state.pool.statuses(with_memory=True),
        )

    @app.get("/api/device", response_model=DeviceInfo)
    def device() -> DeviceInfo:
        return state.device_info()

    @app.get("/api/workers", response_model=list[WorkerStatus])
    def workers() -> list[WorkerStatus]:
        return state.pool.statuses(with_memory=True)

    @app.get("/api/settings")
    def get_settings() -> dict[str, Any]:
        return state.settings.to_dict()

    @app.put("/api/settings")
    def put_settings(patch: dict[str, Any]) -> dict[str, Any]:
        allowed = set(state.settings.to_dict())
        patch = {key: value for key, value in patch.items() if key in allowed}
        for key in PATH_KEYS:
            value = patch.get(key)
            if value is None:
                patch.pop(key, None)
                continue
            if not isinstance(value, str) or not value.startswith(("/", "~")):
                raise HTTPException(400, f"{key} must be an absolute path")

        if "lms_base_url" in patch:
            value = patch["lms_base_url"]
            try:
                parsed = httpx.URL(str(value))
            except Exception as exc:
                raise HTTPException(400, "lms_base_url is not a valid URL") from exc
            if parsed.scheme not in ("http", "https") or not parsed.host:
                raise HTTPException(400, "lms_base_url must be an http(s) URL")

        if "bio_rodeo_cache_hours" in patch:
            value = patch["bio_rodeo_cache_hours"]
            if isinstance(value, bool) or not isinstance(value, int) or not 1 <= value <= 8760:
                raise HTTPException(400, "bio_rodeo_cache_hours must be an integer from 1 to 8760")

        if "keep_warm_minutes" in patch:
            value = patch["keep_warm_minutes"]
            if value is not None and (
                isinstance(value, bool) or not isinstance(value, int) or not -1 <= value <= 1440
            ):
                raise HTTPException(
                    400, "keep_warm_minutes must be null, -1 (until quit) or 0–1440"
                )

        if "warm_workers" in patch and not isinstance(patch["warm_workers"], bool):
            raise HTTPException(400, "warm_workers must be true or false")

        current = state.settings.to_dict()
        if "home" in patch and patch["home"] != current["home"]:
            old_home = Path(current["home"]).expanduser()
            new_home = Path(patch["home"]).expanduser()
            for key in PATH_KEYS:
                if key == "home" or key in patch:
                    continue
                old_path = Path(current[key]).expanduser()
                try:
                    relative = old_path.relative_to(old_home)
                except ValueError:
                    continue
                patch[key] = str(new_home / relative)

        storage_keys = {"home", "models_dir", "results_dir", "cache_dir"}
        active = state.store.count_active()
        if active and any(
            key in patch and patch[key] != current[key] for key in storage_keys
        ):
            raise HTTPException(
                409, "Stop running jobs before changing storage paths"
            )

        try:
            candidate = Settings(**{**current, **patch})
            candidate.ensure_dirs()
        except OSError as exc:
            raise HTTPException(400, f"Could not create the storage paths: {exc}") from exc

        candidate.save()
        state.settings = candidate
        state.sizer.invalidate()
        state.lm_studio.refresh(candidate.lms_base_url)
        state.rebuild(full=active == 0)
        return state.settings.to_dict()

    @app.get("/api/runners", response_model=list[RunnerManifestModel])
    def runners() -> list[RunnerManifestModel]:
        return state.registry.manifests()

    @app.get("/api/runners/status", response_model=list[RunnerStatusModel])
    def runner_statuses() -> list[RunnerStatusModel]:
        return state.registry.statuses()

    @app.get("/api/runners/{runner_id}", response_model=RunnerManifestModel)
    def runner(runner_id: str) -> RunnerManifestModel:
        try:
            return state.registry.manifest(runner_id)
        except KeyError as exc:
            raise HTTPException(404, f"Unknown runner: {runner_id}") from exc

    @app.post("/api/runners/{runner_id}/warm")
    def warm_runner(runner_id: str) -> dict[str, bool]:
        """Load a model in the background so the next job starts at once."""
        try:
            runner_obj = state.registry.get(runner_id)
        except KeyError as exc:
            raise HTTPException(404, f"Unknown runner: {runner_id}") from exc
        return {"started": runner_obj.prewarm(state.settings)}

    @app.post("/api/runners/{runner_id}/release")
    def release_runner(runner_id: str) -> dict[str, bool]:
        """Unload a warm model to free its memory."""
        return {"stopped": state.pool.stop(runner_id)}

    @app.get("/api/models", response_model=CatalogResponse)
    def models() -> CatalogResponse:
        entries, sources = state.catalog.entries()
        return CatalogResponse(entries=entries, sources=sources)

    @app.post("/api/models/{entry_id}/install", response_model=CreateJobResponse)
    def install(entry_id: str) -> CreateJobResponse:
        entries, _ = state.catalog.entries()
        entry = next((e for e in entries if e.id == entry_id), None)
        runner_id = entry.runner_id if entry else None
        if runner_id is None:
            try:
                state.registry.get(entry_id)
                runner_id = entry_id
            except KeyError as exc:
                raise HTTPException(
                    404, f"{entry_id} has no Dimitri runner; it is catalog-only."
                ) from exc
        name = entry.name if entry else runner_id
        try:
            job = state.manager.submit_install(runner_id, name)
        except KeyError as exc:
            raise HTTPException(404, f"No runner registered for {runner_id}") from exc
        state.sizer.invalidate()
        return CreateJobResponse(job=job)

    @app.post("/api/catalog/refresh")
    def refresh_catalog(query: str | None = Query(default=None)) -> dict[str, Any]:
        slugs = None
        if query:
            slugs = state.catalog.adapter.search_slugs(query)
        payload = state.catalog.refresh(slugs)
        return {
            "ok": True,
            "entries": len(payload.get("entries", [])),
            "fetched_at": payload.get("fetched_at"),
            "source": payload.get("source"),
        }

    # ------------------------------------------------------------------ jobs
    @app.get("/api/jobs", response_model=list[JobSummary])
    def list_jobs(
        limit: int = Query(default=500, ge=1, le=2000),
        kind: str | None = Query(default=None),
    ) -> list[JobSummary]:
        return state.store.summaries(limit=limit, kind=kind)

    @app.post("/api/jobs", response_model=CreateJobResponse)
    def create_job(request: PredictionRequest) -> CreateJobResponse:
        try:
            job = state.manager.submit_prediction(request)
        except (ValueError, KeyError) as exc:
            raise HTTPException(400, str(exc)) from exc
        return CreateJobResponse(job=job)

    @app.post("/api/jobs/batch", response_model=CreateJobsResponse)
    def create_jobs(request: CreateJobsRequest) -> CreateJobsResponse:
        """The same input on several models, queued one after another."""
        try:
            jobs = state.manager.submit_many(request)
        except (ValueError, KeyError) as exc:
            raise HTTPException(400, str(exc)) from exc
        return CreateJobsResponse(jobs=jobs)

    @app.post("/api/imports", response_model=CreateJobResponse)
    def import_structure(request: ImportRequest) -> CreateJobResponse:
        try:
            job = state.store.import_structure(request.filename, request.text, request.name)
        except StructureError as exc:
            raise HTTPException(400, f"Could not read {request.filename}: {exc}") from exc
        return CreateJobResponse(job=job)

    @app.get("/api/jobs/{job_id}", response_model=Job)
    def get_job(job_id: str) -> Job:
        job = state.store.get(job_id)
        if job is None:
            raise HTTPException(404, "Job not found")
        return job

    @app.delete("/api/jobs/{job_id}")
    def delete_job(job_id: str) -> dict[str, bool]:
        job = state.store.get(job_id)
        if job is None:
            raise HTTPException(404, "Job not found")
        if job.status in ("queued", "running"):
            raise HTTPException(409, "Cancel the job before deleting it")
        if not state.store.delete(job_id):
            raise HTTPException(404, "Job not found")
        state.sizer.invalidate(state.settings.results_path)
        return {"deleted": True}

    @app.post("/api/jobs/{job_id}/cancel")
    def cancel_job(job_id: str) -> dict[str, bool]:
        if state.store.get(job_id) is None:
            raise HTTPException(404, "Job not found")
        return {"cancelled": state.manager.cancel(job_id)}

    @app.get("/api/jobs/{job_id}/structure")
    def structure(job_id: str) -> Response:
        """The structure exactly as the model wrote it (PDB or mmCIF)."""
        found = state.store.structure(job_id)
        if found is None:
            raise HTTPException(404, "No structure for this job")
        text, fmt = found
        return Response(
            content=text,
            media_type="chemical/x-mmcif" if fmt == "mmcif" else "chemical/x-pdb",
            headers={"X-Structure-Format": fmt, "Cache-Control": "max-age=86400"},
        )

    @app.get("/api/jobs/{job_id}/pae", response_model=PaeResponse)
    def pae(job_id: str, max_cells: int = Query(default=256, alias="max", ge=8, le=4096)) -> PaeResponse:
        job = state.store.get(job_id)
        if job is None:
            raise HTTPException(404, "Job not found")
        found = state.store.pae(job_id, max_cells=max_cells)
        if found is None:
            raise HTTPException(404, "This job has no PAE matrix")
        size, stride, matrix = found
        note = job.result.pae_note if job.result else None
        return PaeResponse(size=size, stride=stride, matrix=matrix, note=note)

    @app.get("/api/jobs/{job_id}/compare/{other_id}", response_model=CompareResponse)
    def compare(job_id: str, other_id: str) -> CompareResponse:
        """Superpose ``other`` onto ``job`` (same input), with RMSD and per-residue distance."""
        first = state.store.structure(job_id)
        second = state.store.structure(other_id)
        if first is None or second is None:
            raise HTTPException(404, "Both jobs need a completed structure")
        try:
            result = superpose(first[0], first[1], second[0], second[1])
        except (StructureError, RuntimeError, ValueError) as exc:
            raise HTTPException(400, f"Could not superpose these structures: {exc}") from exc
        return CompareResponse(
            reference_id=job_id,
            other_id=other_id,
            rmsd=result.rmsd,
            aligned=result.aligned,
            atoms=result.atoms,
            per_residue_distance=result.per_residue_distance,
            moved_text=result.moved_text,
            moved_format=result.moved_format,
        )

    @app.get("/api/jobs/{job_id}/events")
    async def job_events(job_id: str, request: Request) -> StreamingResponse:
        """Full job records for one job until it finishes (kept for scripts)."""
        if state.store.get(job_id) is None:
            raise HTTPException(404, "Job not found")

        async def stream() -> AsyncIterator[str]:
            seen = -1
            idle = 0.0
            yield ": connected\n\n"
            while True:
                if await request.is_disconnected():
                    return
                version = state.store.job_version(job_id)
                if version is None:
                    return
                if version != seen:
                    seen = version
                    idle = 0.0
                    job = state.store.get(job_id)
                    if job is None:
                        return
                    yield f"event: job\ndata: {job.model_dump_json()}\n\n"
                    if job.status in ("completed", "failed", "cancelled"):
                        return
                else:
                    idle += 0.25
                    if idle >= 10:
                        idle = 0.0
                        yield ": heartbeat\n\n"
                await asyncio.sleep(0.25)

        return StreamingResponse(
            stream(),
            media_type="text/event-stream",
            headers={
                "Cache-Control": "no-cache",
                "Connection": "keep-alive",
                "X-Accel-Buffering": "no",
            },
        )

    @app.get("/api/events")
    async def events(
        request: Request,
        duration: float | None = Query(default=None, gt=0, le=86_400),
    ) -> StreamingResponse:
        """One stream for the whole app: a snapshot of every job, then only
        what changes (job progress, new and deleted jobs, model status).

        ``duration`` closes the stream after that many seconds; clients simply
        reconnect and get a fresh snapshot."""
        ends_at = time.monotonic() + duration if duration else None

        async def stream() -> AsyncIterator[str]:
            version, _, _ = state.store.changes_since(1 << 62)
            runners_seen = state.runners_version
            yield _sse(
                "snapshot",
                {
                    "jobs": [summary.model_dump() for summary in state.store.summaries()],
                    "version": version,
                },
            )
            last_beat = time.monotonic()
            while True:
                if await request.is_disconnected():
                    return
                if ends_at is not None and time.monotonic() > ends_at:
                    return
                new_version, changed, deleted = state.store.changes_since(version)
                if new_version != version:
                    version = new_version
                    for job in changed:
                        yield _sse("job", _job_event(job))
                    for job_id in deleted:
                        yield _sse("deleted", {"id": job_id})
                    last_beat = time.monotonic()
                if state.runners_version != runners_seen:
                    runners_seen = state.runners_version
                    yield _sse(
                        "runners",
                        {
                            "runners": [s.model_dump() for s in state.registry.statuses()],
                            "workers": [w.model_dump() for w in state.pool.statuses()],
                        },
                    )
                    last_beat = time.monotonic()
                if time.monotonic() - last_beat > 15:
                    last_beat = time.monotonic()
                    yield ": heartbeat\n\n"
                await asyncio.sleep(0.15)

        return StreamingResponse(
            stream(),
            media_type="text/event-stream",
            headers={
                "Cache-Control": "no-cache",
                "Connection": "keep-alive",
                "X-Accel-Buffering": "no",
            },
        )

    @app.get("/api/jobs/{job_id}/download/{fmt}")
    def download(job_id: str, fmt: str) -> FileResponse:
        job = state.store.get(job_id)
        if job is None:
            raise HTTPException(404, "Job not found")
        if job.status != "completed":
            raise HTTPException(409, "Job has no results yet")
        mapping = {
            "cif": "structure.cif",
            "pdb": "structure.pdb",
            "json": "result.json",
        }
        if fmt not in mapping:
            raise HTTPException(400, "Format must be cif, pdb or json")
        path = state.store.job_dir(job_id) / mapping[fmt]
        if not path.exists():
            raise HTTPException(404, "Result file missing")
        stem = _safe_stem(job.name)
        filename = {
            "cif": f"{stem}.cif",
            "pdb": f"{stem}.pdb",
            "json": f"{stem}_confidence.json",
        }[fmt]
        return FileResponse(path, filename=filename)

    @app.exception_handler(ValueError)
    async def value_error_handler(_: Request, exc: ValueError) -> JSONResponse:
        return JSONResponse(status_code=400, content={"detail": str(exc)})

    return app


def _app_from_env() -> FastAPI:
    import os

    home = os.environ.get("DIMITRI_HOME")
    return create_app(Path(home).expanduser() if home else None)


class _LazyApp:
    """``uvicorn dimitri.main:app`` still works; the app is built on first use."""

    _instance: FastAPI | None = None

    def _get(self) -> FastAPI:
        if self._instance is None:
            self._instance = _app_from_env()
        return self._instance

    async def __call__(self, scope, receive, send):  # ASGI
        await self._get()(scope, receive, send)

    def __getattr__(self, name: str):
        return getattr(self._get(), name)


app = _LazyApp()


def run(port: int = DEFAULT_PORT, parent_pid: int | None = None) -> None:
    import uvicorn

    if parent_pid:
        _watch_parent(parent_pid)
    uvicorn.run(
        _app_from_env(),
        host="127.0.0.1",
        port=port,
        log_level="warning",
        access_log=False,
    )


def _watch_parent(parent_pid: int) -> None:
    """Exit when the app that started us is gone, even if it crashed."""
    import os
    import signal

    def watch() -> None:
        while True:
            time.sleep(1.0)
            try:
                os.kill(parent_pid, 0)
            except ProcessLookupError:
                os.kill(os.getpid(), signal.SIGTERM)
                return
            except PermissionError:
                continue

    threading.Thread(target=watch, daemon=True).start()


if __name__ == "__main__":
    run()
