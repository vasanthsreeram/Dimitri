"""Warm worker pool, exercised through the synthetic demo worker process."""

from __future__ import annotations

import time
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from dimitri.models import PredictionRequest
from dimitri.runners.base import JobControl, RunnerError
from dimitri.runners.demo import DemoWorkerRunner
from dimitri.workers import WorkerPool

from .conftest import wait_for_job


def submit(client: TestClient, sequence: str = "MKTAYIAKQR", **overrides) -> dict:
    payload = {"model_id": "demo-warm", "entity_type": "protein", "sequence": sequence}
    payload.update(overrides)
    response = client.post("/api/jobs", json=payload)
    assert response.status_code == 200, response.text
    return response.json()["job"]


def test_second_job_reuses_the_warm_worker(client: TestClient) -> None:
    first = wait_for_job(client, submit(client)["id"])
    second = wait_for_job(client, submit(client)["id"])
    assert first["status"] == second["status"] == "completed", first.get("error")
    assert first["result"]["warm"] is False
    assert second["result"]["warm"] is True
    assert first["result"]["extra"]["worker_pid"] == second["result"]["extra"]["worker_pid"]
    assert first["result"]["extra"]["loaded_at"] == second["result"]["extra"]["loaded_at"]
    workers = client.get("/api/workers").json()
    assert [w["runner_id"] for w in workers] == ["demo-warm"]
    assert workers[0]["state"] == "ready" and workers[0]["jobs_served"] == 2


def test_cold_mode_starts_a_process_per_job(client: TestClient) -> None:
    assert client.put("/api/settings", json={"warm_workers": False}).status_code == 200
    first = wait_for_job(client, submit(client)["id"])
    second = wait_for_job(client, submit(client)["id"])
    assert first["result"]["extra"]["worker_pid"] != second["result"]["extra"]["worker_pid"]
    assert second["result"]["warm"] is False
    assert client.get("/api/workers").json() == []


def test_worker_error_fails_the_job_but_keeps_the_model_loaded(client: TestClient) -> None:
    bad = wait_for_job(client, submit(client, sequence="MKZ")["id"])
    assert bad["status"] == "failed"
    assert "rejects Z" in bad["error"]
    assert bad["hint"] == "Remove Z from the sequence."
    good = wait_for_job(client, submit(client)["id"])
    assert good["status"] == "completed"
    assert good["result"]["warm"] is True


def test_cancel_kills_the_worker_and_the_next_job_starts_fresh(client: TestClient) -> None:
    runner = DemoWorkerRunner({"DEMO_WORKER_STEP_S": "2"})
    client.app.state.dimitri.registry.register(runner)
    job = submit(client)
    deadline = time.time() + 10
    while time.time() < deadline:
        current = client.get(f"/api/jobs/{job['id']}").json()
        if current["current_stage"] in ("validate", "fold"):
            break
        time.sleep(0.05)
    assert client.post(f"/api/jobs/{job['id']}/cancel").json() == {"cancelled": True}
    cancelled = wait_for_job(client, job["id"])
    assert cancelled["status"] == "cancelled"
    assert client.get("/api/workers").json() == []

    client.app.state.dimitri.registry.register(DemoWorkerRunner())
    after = wait_for_job(client, submit(client)["id"])
    assert after["status"] == "completed" and after["result"]["warm"] is False


def test_load_failure_reports_the_workers_hint(client: TestClient) -> None:
    client.app.state.dimitri.registry.register(DemoWorkerRunner({"DEMO_WORKER_FAIL_LOAD": "1"}))
    failed = wait_for_job(client, submit(client)["id"])
    assert failed["status"] == "failed"
    assert "Synthetic weights are missing" in failed["error"]
    assert failed["hint"] == "Run setup."


def test_idle_workers_are_stopped(tmp_path: Path) -> None:
    pool = WorkerPool(tmp_path, keep_warm_s=0.3, max_resident=2, reap_interval=0.1)
    runner = DemoWorkerRunner()
    runner.pool = pool
    from dimitri.config import Settings

    settings = Settings(home=str(tmp_path / "h"))
    work = tmp_path / "job" / "work"
    work.mkdir(parents=True)
    result = runner.run(
        PredictionRequest(model_id="demo-warm", sequence="MKT"),
        work,
        settings,
        lambda *a: None,
        JobControl(),
    )
    assert result.warm is False and pool.is_warm("demo-warm")
    time.sleep(1.0)
    assert not pool.is_warm("demo-warm")
    assert pool.statuses() == []
    pool.shutdown()


def test_pool_evicts_the_least_recently_used_model(tmp_path: Path) -> None:
    pool = WorkerPool(tmp_path, keep_warm_s=None, max_resident=1)
    first = DemoWorkerRunner().worker_spec(None)  # type: ignore[arg-type]
    second = type(first)(
        runner_id="other",
        argv=first.argv,
        cwd=first.cwd,
        env=first.env,
        ready_timeout=first.ready_timeout,
    )
    pool.acquire(first)
    pool.acquire(second)
    assert [status.runner_id for status in pool.statuses()] == ["other"]
    pool.shutdown()
    with pytest.raises(RunnerError):
        pool.acquire(first)
