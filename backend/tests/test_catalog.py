from __future__ import annotations

from pathlib import Path

import httpx
import pytest

from dimitri.catalog import (
    BioRodeoAdapter,
    CatalogService,
    load_local_catalog,
    parse_model_page,
)
from dimitri.config import Settings
from dimitri.runners import RunnerRegistry

FIXTURES = Path(__file__).parent / "fixtures"


def test_parse_model_page_extracts_jsonld_and_stats() -> None:
    html = (FIXTURES / "bio_rodeo_model.html").read_text()
    record = parse_model_page("alphafold-3", html)
    assert record is not None
    assert record["name"] == "AlphaFold 3"
    assert record["provider"] == "Google DeepMind"
    assert record["openness"] == 28
    assert record["license"] == "Apache-2.0"
    assert record["url"].endswith("/models/alphafold-3")
    assert "Diffusion-based" in record["description"]


def test_parse_model_page_detects_missing_model() -> None:
    assert parse_model_page("nope", "<title>Model Not Found | bio.rodeo</title>") is None


def test_parse_model_page_without_jsonld_returns_none() -> None:
    assert parse_model_page("nope", "<html><title>Something</title></html>") is None


def test_adapter_refreshes_and_caches(tmp_path: Path) -> None:
    html = (FIXTURES / "bio_rodeo_model.html").read_text()

    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/models/alphafold-3":
            return httpx.Response(200, text=html)
        return httpx.Response(404, text="missing")

    settings = Settings(home=str(tmp_path / "home"))
    settings.ensure_dirs()
    client = httpx.Client(transport=httpx.MockTransport(handler))
    adapter = BioRodeoAdapter(settings, client=client)
    payload = adapter.refresh(["alphafold-3", "missing"])
    assert payload["api"] is None
    assert payload["source"] == "bio.rodeo"
    assert len(payload["entries"]) == 1
    assert adapter.cache_file.exists()
    cached = adapter.load_cache()
    assert cached["entries"][0]["slug"] == "alphafold-3"
    assert adapter.cache_fresh(cached)


def test_adapter_search_finds_slugs(tmp_path: Path) -> None:
    search_html = (
        '<a href="/models/rhofold-plus">x</a>'
        '<a href="/models/alphafold-3">y</a>'
        '<a href="/models/rhofold-plus">z</a>'
    )

    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, text=search_html)

    settings = Settings(home=str(tmp_path / "home"))
    client = httpx.Client(transport=httpx.MockTransport(handler))
    adapter = BioRodeoAdapter(settings, client=client)
    assert adapter.search_slugs("rna") == ["rhofold-plus", "alphafold-3"]


def test_local_catalog_maps_to_runners() -> None:
    entries = load_local_catalog()
    runner_ids = {runner.manifest.id for runner in RunnerRegistry(Settings()).all()}
    for entry in entries:
        if entry["runner_id"]:
            assert entry["runner_id"] in runner_ids
        assert entry["rodeo_slug"]


def test_catalog_entries_merge_bio_rodeo_metadata(tmp_path: Path) -> None:
    settings = Settings(home=str(tmp_path / "home"))
    settings.ensure_dirs()
    registry = RunnerRegistry(settings)
    service = CatalogService(settings, registry)
    entries, sources = service.entries()
    by_id = {entry.id: entry for entry in entries}
    assert by_id["alphafold3-mac"].source == "bio.rodeo"
    assert by_id["alphafold3-mac"].provider == "Google DeepMind"
    assert by_id["alphafold3-mac"].device == "mlx"
    assert by_id["alphafold3-mac"].runtime == "MLX (Metal) · mac-af3"
    assert by_id["rhofold"].runtime == "PyTorch MPS (rhofold-mac)"
    assert by_id["rhofold"].device == "mps"
    assert by_id["openfold3"].device == "mps"
    assert by_id["openfold3"].runtime == "MLX kernels on PyTorch"
    assert by_id["openfold3"].name == "OpenFold3-MLX"
    assert by_id["rhofold"].source_url.endswith("/models/rhofold-plus")
    assert sources["bio_rodeo"]["api"] is None


@pytest.mark.parametrize("runner_id", ["alphafold3-mac", "rhofold", "openfold3"])
def test_runner_status_points_at_configured_paths(tmp_path: Path, runner_id: str) -> None:
    settings = Settings(home=str(tmp_path / "home"))
    status = RunnerRegistry(settings).status(runner_id)
    assert status.installed is False
    assert status.ready is False
    assert status.paths
    assert status.detail


def test_stale_cache_falls_back_to_the_shipped_snapshot(tmp_path: Path) -> None:
    settings = Settings(home=str(tmp_path / "home"))
    settings.ensure_dirs()
    adapter = BioRodeoAdapter(settings, client=httpx.Client(transport=httpx.MockTransport(lambda r: httpx.Response(200))))
    adapter.save_cache({"entries": [{"slug": "stale-only", "name": "Stale"}], "fetched_at": 0})
    service = CatalogService(settings, RunnerRegistry(settings), adapter)
    payload, records = service.rodeo_records()
    assert "stale-only" not in records
    assert payload.get("verified_at") == "2026-10-17"
