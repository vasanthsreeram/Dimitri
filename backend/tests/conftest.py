from __future__ import annotations

import time
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from dimitri.main import create_app


@pytest.fixture()
def home(tmp_path: Path) -> Path:
    return tmp_path / "dimitri-home"


@pytest.fixture()
def client(home: Path) -> TestClient:
    return TestClient(create_app(home))


def wait_for_job(client: TestClient, job_id: str, timeout: float = 20.0) -> dict:
    deadline = time.time() + timeout
    while time.time() < deadline:
        job = client.get(f"/api/jobs/{job_id}").json()
        if job["status"] in ("completed", "failed", "cancelled"):
            return job
        time.sleep(0.1)
    raise AssertionError(f"job {job_id} did not finish in {timeout}s")
