from __future__ import annotations

from fastapi.testclient import TestClient


def test_health(client: TestClient) -> None:
    body = client.get("/api/health").json()
    assert body["status"] == "ok"
    assert body["version"]


def test_runners_are_registered_and_demo_is_hidden(client: TestClient) -> None:
    runners = client.get("/api/runners").json()
    ids = {runner["id"] for runner in runners}
    assert ids == {"alphafold3-mac", "rhofold", "openfold3"}
    for runner in runners:
        assert runner["stages"], "every runner must declare its stages"
        assert runner["source_url"].startswith("https://github.com/")


def test_status_reports_storage_and_lm_studio(client: TestClient) -> None:
    body = client.get("/api/status").json()
    assert body["status"] == "ok"
    assert body["lm_studio"]["base_url"].startswith("http://localhost:1234")
    assert {item["path"] for item in body["storage"]}
    assert len(body["runners"]) == 3


def test_settings_round_trip_and_paths(client: TestClient, home) -> None:
    original = client.get("/api/settings").json()
    assert original["home"] == str(home)
    models_dir = home / "custom-models"
    response = client.put(
        "/api/settings",
        json={"models_dir": str(models_dir), "lms_base_url": "http://localhost:1234/v1"},
    )
    assert response.status_code == 200
    assert response.json()["models_dir"] == str(models_dir)
    assert models_dir.exists()
    assert client.get("/api/settings").json()["models_dir"] == str(models_dir)


def test_settings_rejects_bad_lms_url(client: TestClient) -> None:
    response = client.put("/api/settings", json={"lms_base_url": "localhost:1234"})
    assert response.status_code == 400


def test_settings_rejects_relative_paths(client: TestClient) -> None:
    response = client.put("/api/settings", json={"models_dir": "relative/models"})
    assert response.status_code == 400
    response = client.put("/api/settings", json={"home": ""})
    assert response.status_code == 400


def test_lm_studio_status_handles_no_server(client: TestClient) -> None:
    body = client.get("/api/status").json()["lm_studio"]
    assert body["reachable"] is False
    assert body["detail"]


def test_catalog_is_sourced_from_bio_rodeo(client: TestClient) -> None:
    body = client.get("/api/models").json()
    entries = {entry["id"]: entry for entry in body["entries"]}
    assert {"alphafold3-mac", "rhofold", "openfold3"} <= set(entries)
    assert body["sources"]["bio_rodeo"]["api"] is None
    af3 = entries["alphafold3-mac"]
    assert af3["source"] == "bio.rodeo"
    assert af3["provider"] == "Google DeepMind"
    assert af3["source_url"].endswith("/models/alphafold-3")
    assert af3["openness"] is not None
    assert af3["installable"] is True
    assert entries["alphafold2"]["installable"] is False


def test_installing_catalog_only_entry_is_rejected(client: TestClient) -> None:
    response = client.post("/api/models/alphafold2/install")
    assert response.status_code == 404
    assert "catalog-only" in response.json()["detail"]


def test_unknown_runner_and_job_return_404(client: TestClient) -> None:
    assert client.get("/api/runners/nope").status_code == 404
    assert client.get("/api/jobs/nope").status_code == 404
    assert client.delete("/api/jobs/nope").status_code == 404


def test_unknown_model_is_rejected(client: TestClient) -> None:
    response = client.post(
        "/api/jobs",
        json={
            "model_id": "nope",
            "entity_type": "protein",
            "sequence": "MKTAYIAK",
        },
    )
    assert response.status_code == 400


def test_model_rejects_unsupported_entity(client: TestClient) -> None:
    response = client.post(
        "/api/jobs",
        json={
            "model_id": "rhofold",
            "entity_type": "protein",
            "sequence": "MKTAYIAK",
        },
    )
    assert response.status_code == 400
    assert "does not accept protein" in response.json()["detail"]


def test_sequence_is_normalized(client: TestClient) -> None:
    response = client.post(
        "/api/jobs",
        json={
            "model_id": "demo",
            "entity_type": "protein",
            "sequence": "mkt ayi\nak",
            "name": "normalize",
            "samples": 1,
        },
    )
    assert response.status_code == 200
    assert response.json()["job"]["sequence"] == "MKTAYIAK"
