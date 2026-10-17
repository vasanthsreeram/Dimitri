"""Structure files: viewer-ready mmCIF, imports, comparison and live events."""

from __future__ import annotations

import json
from pathlib import Path

from fastapi.testclient import TestClient

from dimitri.export import detect_format, pdb_to_cif, read_structure, superpose

from .conftest import wait_for_job

DATA = Path(__file__).resolve().parents[1] / "dimitri" / "data"
TRP_CAGE = (DATA / "1l2y.pdb").read_text()


def atom_site_column(cif: str, name: str) -> list[str]:
    """Values of one _atom_site column (simple whitespace-separated rows)."""
    headers = [line.split(".", 1)[1].strip() for line in cif.splitlines() if line.startswith("_atom_site.")]
    index = headers.index(name)
    rows = [line.split() for line in cif.splitlines() if line.startswith(("ATOM", "HETATM"))]
    return [row[index] for row in rows if len(row) == len(headers)]


def test_converted_cif_declares_polymer_entities() -> None:
    """Phase 1's Biopython CIF had label_entity_id '?' and no _entity_poly,
    so Mol* drew loose atoms. The gemmi CIF must say what the chain is."""
    cif = pdb_to_cif(TRP_CAGE)
    assert "_entity_poly.type" in cif and "polypeptide(L)" in cif
    assert "_struct_asym.id" in cif
    entity_ids = set(atom_site_column(cif, "label_entity_id"))
    assert entity_ids == {"1"}
    assert set(atom_site_column(cif, "label_asym_id")) == {"A"}
    assert "?" not in set(atom_site_column(cif, "label_seq_id"))


def test_format_detection() -> None:
    assert detect_format(TRP_CAGE) == "pdb"
    assert detect_format(pdb_to_cif(TRP_CAGE)) == "mmcif"
    assert detect_format("# comment\ndata_x\nloop_\n") == "mmcif"


def test_nmr_structure_is_not_mistaken_for_confidence(client: TestClient) -> None:
    response = client.post("/api/imports", json={"filename": "1l2y.pdb", "text": TRP_CAGE})
    assert response.status_code == 200, response.text
    job = response.json()["job"]
    assert job["kind"] == "import" and job["status"] == "completed"
    assert job["entity_type"] == "protein"
    assert job["sequence"] == "NLYIQWLKDGGPSSGRPPPS"
    result = job["result"]
    assert result["has_confidence"] is False
    assert result["per_residue_plddt"] == []
    assert result["residues"] == 20 and result["models"] == 38
    assert result["polymer_types"] == ["protein"]

    native = client.get(f"/api/jobs/{job['id']}/structure")
    assert native.headers["x-structure-format"] == "pdb"
    assert native.text == TRP_CAGE
    cif = client.get(f"/api/jobs/{job['id']}/download/cif").text
    assert "_entity_poly" in cif


def test_predicted_model_bfactors_are_read_as_plddt(client: TestClient) -> None:
    lines = [
        f"ATOM  {i:5d}  CA  ALA A{i:4d}    {3.8 * i:8.3f}   0.000   0.000  1.00{b:6.2f}           C"
        for i, b in enumerate([95.0, 82.0, 61.0, 40.0], start=1)
    ]
    text = "\n".join(lines) + "\nEND\n"
    job = client.post("/api/imports", json={"filename": "model.pdb", "text": text}).json()["job"]
    assert job["result"]["has_confidence"] is True
    assert job["result"]["per_residue_plddt"] == [95.0, 82.0, 61.0, 40.0]
    assert job["result"]["metrics"]["plddt"] == 69.5


def test_compare_superposes_structures_of_the_same_input(client: TestClient) -> None:
    a = client.post("/api/imports", json={"filename": "a.pdb", "text": TRP_CAGE}).json()["job"]
    b = client.post("/api/imports", json={"filename": "b.pdb", "text": TRP_CAGE}).json()["job"]
    summaries = {s["id"]: s for s in client.get("/api/jobs").json()}
    assert summaries[a["id"]]["sequence_key"] == summaries[b["id"]]["sequence_key"]
    comparison = client.get(f"/api/jobs/{a['id']}/compare/{b['id']}").json()
    assert comparison["rmsd"] == 0.0
    assert comparison["aligned"] == 20 and comparison["atoms"] == "CA"
    assert comparison["moved_format"] == "pdb"
    assert len(comparison["per_residue_distance"]) == 20


def test_superpose_moves_a_shifted_copy_back() -> None:
    structure = read_structure(TRP_CAGE)
    for chain in structure[0]:
        for residue in chain:
            for atom in residue:
                atom.pos.x += 7.5
    from dimitri.export import to_pdb

    result = superpose(TRP_CAGE, "pdb", to_pdb(structure), "pdb")
    assert result.rmsd < 0.01
    assert max(d for d in result.per_residue_distance if d is not None) < 0.01


def test_bad_import_is_rejected(client: TestClient) -> None:
    response = client.post("/api/imports", json={"filename": "x.pdb", "text": "hello"})
    assert response.status_code == 400


def test_job_list_is_light(client: TestClient) -> None:
    job = client.post(
        "/api/jobs",
        json={"model_id": "demo", "entity_type": "rna", "sequence": "GGGAAACCC"},
    ).json()["job"]
    wait_for_job(client, job["id"])
    summary = client.get("/api/jobs").json()[0]
    assert summary["id"] == job["id"]
    assert summary["length"] == 9 and summary["plddt"] is not None
    for heavy in ("sequence", "result", "stages", "log_tail"):
        assert heavy not in summary


def test_app_event_stream_sends_a_snapshot_then_changes(client: TestClient) -> None:
    import threading
    import time

    job = client.post(
        "/api/jobs",
        json={"model_id": "demo", "entity_type": "protein", "sequence": "MKTAYIAK"},
    ).json()["job"]
    wait_for_job(client, job["id"])

    def delete_soon() -> None:
        time.sleep(0.6)
        client.delete(f"/api/jobs/{job['id']}")

    # TestClient delivers a streamed body when it ends, so the change happens
    # on another thread while a short stream is open.
    threading.Thread(target=delete_soon).start()
    events: list[tuple[str, dict]] = []
    with client.stream("GET", "/api/events?duration=2") as stream:
        kind = None
        for line in stream.iter_lines():
            if line.startswith("event: "):
                kind = line[7:]
            elif line.startswith("data: ") and kind:
                events.append((kind, json.loads(line[6:])))
    kinds = [kind for kind, _ in events]
    assert kinds[0] == "snapshot"
    assert any(item["id"] == job["id"] for item in events[0][1]["jobs"])
    assert ("deleted", {"id": job["id"]}) in events


def test_device_profile_sizes_memory(client: TestClient) -> None:
    device = client.get("/api/device").json()
    assert device["memory_gb"] > 0
    assert 0 < device["gpu_budget_gb"] < device["memory_gb"]
    assert device["tier"] in ("compact", "standard", "large")
    assert client.put("/api/settings", json={"keep_warm_minutes": 3}).status_code == 200
    assert client.get("/api/device").json()["keep_warm_minutes"] == 3
    assert client.put("/api/settings", json={"keep_warm_minutes": "x"}).status_code == 400
