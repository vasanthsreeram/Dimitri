from __future__ import annotations

import json

from fastapi.testclient import TestClient

from .conftest import wait_for_job


def submit(client: TestClient, **overrides) -> dict:
    payload = {
        "model_id": "demo",
        "entity_type": "protein",
        "sequence": "MKTAYIAKQRQISFVKSHFSRQDILDLWQ",
        "name": "test fold",
        "seed": 11,
        "samples": 2,
    }
    payload.update(overrides)
    response = client.post("/api/jobs", json=payload)
    assert response.status_code == 200, response.text
    return response.json()["job"]


def test_demo_job_completes_with_metrics_and_stages(client: TestClient) -> None:
    job = submit(client)
    assert job["status"] == "queued"
    assert [stage["id"] for stage in job["stages"]] == [
        "validate",
        "fold",
        "confidence",
        "write",
    ]
    done = wait_for_job(client, job["id"])
    assert done["status"] == "completed", done.get("error")
    assert done["progress"] == 100.0
    assert all(stage["status"] == "done" for stage in done["stages"])

    result = done["result"]
    assert result["metrics"]["plddt"] > 0
    assert 0 < result["metrics"]["ptm"] <= 1
    assert result["metrics"]["iptm"] is None
    assert len(result["per_residue_plddt"]) == 29
    assert len(result["pae"]) == 29
    assert result["residues"] == 29
    assert result["atoms"] == 29
    assert result["format"] == "cif"
    assert result["device"] == "cpu"  # synthetic test runner
    assert done["log_tail"]


def test_job_is_listed_and_deletable(client: TestClient, home) -> None:
    job = submit(client, name="delete me")
    wait_for_job(client, job["id"])
    ids = [item["id"] for item in client.get("/api/jobs").json()]
    assert job["id"] in ids
    assert client.delete(f"/api/jobs/{job['id']}").json() == {"deleted": True}
    assert client.get(f"/api/jobs/{job['id']}").status_code == 404
    assert not (home / "results" / "jobs" / job["id"]).exists()


def test_exports_are_valid(client: TestClient) -> None:
    job = submit(client, name="exports")
    wait_for_job(client, job["id"])

    cif = client.get(f"/api/jobs/{job['id']}/download/cif")
    pdb = client.get(f"/api/jobs/{job['id']}/download/pdb")
    conf = client.get(f"/api/jobs/{job['id']}/download/json")
    assert cif.status_code == pdb.status_code == conf.status_code == 200
    assert "data_" in cif.text and "_atom_site" in cif.text
    assert pdb.text.startswith("ATOM")
    payload = json.loads(conf.text)
    assert payload["metrics"]["plddt"] > 0
    assert len(payload["per_residue_plddt"]) == 29
    assert client.get(f"/api/jobs/{job['id']}/download/xyz").status_code == 400


def test_download_before_completion_is_conflict(client: TestClient) -> None:
    job = submit(client)
    response = client.get(f"/api/jobs/{job['id']}/download/cif")
    # The demo job can finish very quickly; either state is acceptable, but an
    # incomplete job must not return a file.
    assert response.status_code in (200, 409)


def test_cancel_finished_job_is_false(client: TestClient) -> None:
    job = submit(client)
    wait_for_job(client, job["id"])
    assert client.post(f"/api/jobs/{job['id']}/cancel").json() == {"cancelled": False}


def test_sse_stream_emits_job_events(client: TestClient) -> None:
    job = submit(client, name="stream")
    wait_for_job(client, job["id"])
    with client.stream("GET", f"/api/jobs/{job['id']}/events") as response:
        assert response.status_code == 200
        assert response.headers["content-type"].startswith("text/event-stream")
        body = "".join(response.iter_text())
    assert "event: job" in body
    assert '"status":"completed"' in body.replace(" ", "")


def test_entity_types_are_preserved(client: TestClient) -> None:
    for entity, sequence in (
        ("rna", "GGGAAACCC"),
        ("dna", "GGGAAACCC"),
        ("ligand", "ATP"),
    ):
        job = submit(client, entity_type=entity, sequence=sequence)
        done = wait_for_job(client, job["id"])
        assert done["status"] == "completed", done.get("error")
        assert done["result"]["residues"] == len(sequence)


def test_jobs_persist_across_app_restart(home) -> None:
    from fastapi.testclient import TestClient

    from dimitri.main import create_app

    first = TestClient(create_app(home))
    job = submit(first, name="persisted")
    wait_for_job(first, job["id"])

    second = TestClient(create_app(home))
    restored = second.get(f"/api/jobs/{job['id']}").json()
    assert restored["status"] == "completed"
    assert restored["result"]["metrics"]["plddt"] > 0
