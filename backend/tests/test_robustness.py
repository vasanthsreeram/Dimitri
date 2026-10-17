from __future__ import annotations

import threading
import time
from pathlib import Path

import httpx
from fastapi.testclient import TestClient

from dimitri.models import Job
from dimitri.store import JobStore

from .conftest import wait_for_job


def slow_demo(client: TestClient, delay: float = 0.15) -> None:
    """Make the hidden demo runner slow enough to observe a running job."""
    state = client.app.state.dimitri
    runner = state.registry.get("demo")
    original = runner.run

    def slow_run(request, workdir, settings, progress, control):
        for step in range(6):
            progress("fold", (step + 1) / 6, f"step {step}")
            time.sleep(delay)
        return original(request, workdir, settings, progress, control)

    runner.run = slow_run  # type: ignore[method-assign]


def submit(client: TestClient) -> dict:
    response = client.post(
        "/api/jobs",
        json={
            "model_id": "demo",
            "entity_type": "protein",
            "sequence": "MKTAYIAKQRQISFVKSHFSRQDILDLWQ",
            "name": "slow",
            "samples": 1,
        },
    )
    assert response.status_code == 200
    return response.json()["job"]


def wait_until_running(client: TestClient, job_id: str, timeout: float = 5.0) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if client.get(f"/api/jobs/{job_id}").json()["status"] == "running":
            return
        time.sleep(0.05)
    raise AssertionError("job never reached running")


def test_settings_update_during_a_job_keeps_it_alive(client: TestClient) -> None:
    slow_demo(client)
    job = submit(client)
    wait_until_running(client, job["id"])

    response = client.put("/api/settings", json={"bio_rodeo_cache_hours": 12})
    assert response.status_code == 200
    assert client.get(f"/api/jobs/{job['id']}").json()["status"] == "running"

    done = wait_for_job(client, job["id"])
    assert done["status"] == "completed", done.get("error")
    assert done["result"]["residues"] == 29


def test_storage_path_change_is_rejected_while_busy(client: TestClient, home) -> None:
    slow_demo(client)
    job = submit(client)
    wait_until_running(client, job["id"])
    response = client.put(
        "/api/settings", json={"models_dir": str(home / "other-models")}
    )
    assert response.status_code == 409
    assert wait_for_job(client, job["id"])["status"] == "completed"


def test_delete_running_job_is_rejected(client: TestClient) -> None:
    slow_demo(client)
    job = submit(client)
    wait_until_running(client, job["id"])
    assert client.delete(f"/api/jobs/{job['id']}").status_code == 409
    assert wait_for_job(client, job["id"])["status"] == "completed"


def test_lm_studio_malformed_payload_is_unreachable(monkeypatch) -> None:
    from dimitri import main

    def fake_get(url: str, timeout: float):
        return httpx.Response(
            200, json=[], request=httpx.Request("GET", url)
        )

    monkeypatch.setattr(main.httpx, "get", fake_get)
    status = main.lm_studio_status("http://localhost:1234/v1")
    assert status.reachable is False
    assert "unexpected" in status.detail.lower() or "No LM Studio" in status.detail


def test_settings_cache_hours_must_be_an_integer(client: TestClient) -> None:
    assert (
        client.put("/api/settings", json={"bio_rodeo_cache_hours": "abc"}).status_code
        == 400
    )
    assert (
        client.put("/api/settings", json={"bio_rodeo_cache_hours": 0}).status_code
        == 400
    )
    assert (
        client.put("/api/settings", json={"lms_base_url": "httpfoo"}).status_code == 400
    )


def test_jobstore_concurrent_updates(tmp_path: Path) -> None:
    from dimitri.config import Settings

    settings = Settings(home=str(tmp_path / "home"))
    settings.ensure_dirs()
    store = JobStore(settings)
    job = store.create(
        kind="predict",
        name="concurrent",
        model_id="demo",
        entity_type="protein",
        sequence="MK",
        seed=1,
        samples=1,
        stages=[],
    )
    errors: list[Exception] = []

    def worker(offset: int) -> None:
        try:
            for index in range(40):
                store.update(job.id, progress=float((offset + index) % 100))
        except Exception as exc:  # noqa: BLE001 - the test records failures
            errors.append(exc)

    threads = [threading.Thread(target=worker, args=(i,)) for i in range(6)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()

    assert not errors
    restored = Job.model_validate_json(
        (store.job_dir(job.id) / "job.json").read_text(encoding="utf-8")
    )
    assert restored.id == job.id


def test_run_command_kills_the_process_group_on_cancel(tmp_path: Path) -> None:
    from dimitri.runners.base import JobControl, RunnerError, run_command

    control = JobControl()
    errors: list[Exception] = []

    def target() -> None:
        try:
            run_command(
                ["bash", "-c", "sleep 30 & wait"],
                cwd=tmp_path,
                env=None,
                control=control,
                on_line=lambda line: None,
                label="sleep",
            )
        except Exception as exc:  # noqa: BLE001 - recorded for the assertion
            errors.append(exc)

    thread = threading.Thread(target=target)
    thread.start()
    time.sleep(0.3)
    control.cancel()
    thread.join(timeout=6)
    assert not thread.is_alive(), "run_command stayed blocked after cancellation"
    assert any(isinstance(error, RunnerError) and "cancelled" in str(error) for error in errors)
