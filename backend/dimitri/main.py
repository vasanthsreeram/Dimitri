"""FastAPI application for Dimitri Studio."""

from __future__ import annotations

import asyncio
import platform
import re
import sys
from pathlib import Path
from typing import Any, AsyncIterator

import httpx
from fastapi import FastAPI, HTTPException, Query, Request
from fastapi.responses import FileResponse, JSONResponse, StreamingResponse

from .catalog import CatalogService
from .config import APP_VERSION, DEFAULT_PORT, Settings
from .jobs import JobManager
from .models import (
    CatalogResponse,
    CreateJobResponse,
    DiskUsage,
    Job,
    LmStudioStatus,
    PredictionRequest,
    RunnerManifestModel,
    RunnerStatusModel,
    StatusResponse,
)
from .runners import RunnerRegistry
from .store import JobStore


def _dir_size(path: Path) -> int:
    total = 0
    if not path.exists():
        return 0
    for child in path.rglob("*"):
        try:
            if child.is_file():
                total += child.stat().st_size
        except OSError:
            continue
    return total


def _safe_stem(name: str) -> str:
    cleaned = re.sub(r"[^A-Za-z0-9._-]+", "_", name).strip("._-")
    return cleaned[:80] or "dimitri_job"


def lm_studio_status(base_url: str, timeout: float = 0.8) -> LmStudioStatus:
    url = base_url.rstrip("/") + "/models"
    try:
        response = httpx.get(url, timeout=timeout)
        response.raise_for_status()
        payload = response.json()
        models = [
            item.get("id", "")
            for item in payload.get("data", [])
            if isinstance(item, dict) and item.get("id")
        ]
        return LmStudioStatus(
            reachable=True,
            base_url=base_url,
            models=models[:20],
            detail=f"LM Studio server reachable ({len(models)} model(s)).",
        )
    except (httpx.HTTPError, ValueError) as exc:
        return LmStudioStatus(
            reachable=False,
            base_url=base_url,
            detail=f"No LM Studio server at {base_url}: {type(exc).__name__}.",
        )


class AppState:
    def __init__(self, home: Path | None = None) -> None:
        self.settings = Settings.load(home)
        self.settings.ensure_dirs()
        self.rebuild()

    def rebuild(self) -> None:
        self.registry = RunnerRegistry(self.settings)
        self.store = JobStore(self.settings)
        self.catalog = CatalogService(self.settings, self.registry)
        self.manager = JobManager(self.settings, self.store, self.registry)

    def storage(self) -> list[DiskUsage]:
        paths = {
            "models": self.settings.models_path,
            "results": self.settings.results_path,
            "cache": self.settings.cache_path,
        }
        return [
            DiskUsage(path=str(path), bytes=_dir_size(path), exists=path.exists())
            for path in paths.values()
        ]


def create_app(home: Path | None = None) -> FastAPI:
    state = AppState(home)
    app = FastAPI(title="Dimitri Studio backend", version=APP_VERSION)
    app.state.dimitri = state

    @app.get("/api/health")
    def health() -> dict[str, Any]:
        return {
            "status": "ok",
            "version": APP_VERSION,
            "python": sys.version.split()[0],
            "platform": platform.platform(),
        }

    @app.get("/api/status", response_model=StatusResponse)
    def status() -> StatusResponse:
        entries, sources = state.catalog.entries()
        return StatusResponse(
            status="ok",
            version=APP_VERSION,
            python=sys.version.split()[0],
            platform=platform.platform(),
            backend_url=f"http://127.0.0.1:{DEFAULT_PORT}",
            storage=state.storage(),
            lm_studio=lm_studio_status(state.settings.lms_base_url),
            runners=[RunnerStatusModel(**s.model_dump()) for s in state.registry.statuses()],
            active_jobs=len([j for j in state.store.list() if j.status in ("queued", "running")]),
            bio_rodeo=sources.get("bio_rodeo", {}),
        )

    @app.get("/api/settings")
    def get_settings() -> dict[str, Any]:
        return state.settings.to_dict()

    @app.put("/api/settings")
    def put_settings(patch: dict[str, Any]) -> dict[str, Any]:
        if "lms_base_url" in patch and not str(patch["lms_base_url"]).startswith("http"):
            raise HTTPException(400, "lms_base_url must start with http:// or https://")
        path_keys = (
            "home",
            "models_dir",
            "results_dir",
            "cache_dir",
            "af3_repo",
            "af3_weights_dir",
            "rhofold_repo",
            "openfold3_repo",
            "openfold3_cache",
        )
        for key in path_keys:
            value = patch.get(key)
            if value is None:
                continue
            if not isinstance(value, str) or not value.startswith(("/", "~")):
                raise HTTPException(400, f"{key} must be an absolute path")
        state.settings.update(patch)
        state.settings.ensure_dirs()
        state.rebuild()
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

    @app.get("/api/jobs", response_model=list[Job])
    def list_jobs(limit: int = Query(default=100, ge=1, le=500)) -> list[Job]:
        return state.store.list(limit=limit)

    @app.post("/api/jobs", response_model=CreateJobResponse)
    def create_job(request: PredictionRequest) -> CreateJobResponse:
        try:
            job = state.manager.submit_prediction(request)
        except (ValueError, KeyError) as exc:
            raise HTTPException(400, str(exc)) from exc
        return CreateJobResponse(job=job)

    @app.get("/api/jobs/{job_id}", response_model=Job)
    def get_job(job_id: str) -> Job:
        job = state.store.get(job_id)
        if job is None:
            raise HTTPException(404, "Job not found")
        return job

    @app.delete("/api/jobs/{job_id}")
    def delete_job(job_id: str) -> dict[str, bool]:
        if not state.store.delete(job_id):
            raise HTTPException(404, "Job not found")
        return {"deleted": True}

    @app.post("/api/jobs/{job_id}/cancel")
    def cancel_job(job_id: str) -> dict[str, bool]:
        if state.store.get(job_id) is None:
            raise HTTPException(404, "Job not found")
        return {"cancelled": state.manager.cancel(job_id)}

    @app.get("/api/jobs/{job_id}/events")
    async def job_events(job_id: str, request: Request) -> StreamingResponse:
        if state.store.get(job_id) is None:
            raise HTTPException(404, "Job not found")

        async def stream() -> AsyncIterator[str]:
            last = ""
            idle = 0.0
            yield ": connected\n\n"
            while True:
                if await request.is_disconnected():
                    return
                job = state.store.get(job_id)
                if job is None:
                    return
                payload = job.model_dump_json()
                if payload != last:
                    last = payload
                    idle = 0.0
                    yield f"event: job\ndata: {payload}\n\n"
                else:
                    idle += 0.25
                    if idle >= 10:
                        idle = 0.0
                        yield ": heartbeat\n\n"
                if job.status in ("completed", "failed", "cancelled"):
                    return
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


app = create_app()


def run() -> None:
    import uvicorn

    uvicorn.run(app, host="127.0.0.1", port=DEFAULT_PORT, log_level="info")


if __name__ == "__main__":
    run()
