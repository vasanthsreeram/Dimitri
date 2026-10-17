"""Model catalog: local runner metadata enriched by bio.rodeo.

bio.rodeo has no public API (checked 2026-10-17: ``/api`` returns 404). It is a
Next.js site with server-rendered model pages that carry schema.org
``SoftwareApplication`` JSON-LD. This adapter reads the public sitemap and model
pages, extracts the JSON-LD, and caches the result. See docs/BIO_RODEO.md.
"""

from __future__ import annotations

import json
import re
import time
from pathlib import Path
from typing import Any, Iterable

import httpx

from .config import Settings
from .models import CatalogEntry
from .runners import RunnerRegistry

BIO_RODEO_BASE = "https://bio.rodeo"
BIO_RODEO_TTL_HOURS = 24
USER_AGENT = "DimitriStudio/0.1 (local research app)"
CATALOG_FILE = Path(__file__).resolve().parent / "catalog" / "models.json"
SNAPSHOT_FILE = Path(__file__).resolve().parent / "catalog" / "bio_rodeo_snapshot.json"

JSONLD_RE = re.compile(
    r'<script type="application/ld\+json">(.*?)</script>', re.DOTALL
)
OPENNESS_RE = re.compile(r"openness (\d{1,3})/100")
OPENNESS_STAT_RE = re.compile(
    r'tabular-nums[^"]*">(\d{1,3})</span><span class="text-xs text-sand-500">Openness'
)
LICENSE_RE = re.compile(
    r'tabular-nums text-foreground">([^<]{1,40})</span>\s*'
    r'<span class="text-xs text-sand-500">License</span>'
)
SLUG_RE = re.compile(r'href="/models/([a-z0-9][a-z0-9-]{1,80})"')


def _provider_name(data: dict[str, Any]) -> str | None:
    provider = data.get("provider")
    if isinstance(provider, list) and provider:
        provider = provider[0]
    if isinstance(provider, dict):
        name = provider.get("name")
        return str(name) if name else None
    if isinstance(provider, str):
        return provider
    return None


def parse_model_page(slug: str, html: str) -> dict[str, Any] | None:
    """Extract a catalog record from one bio.rodeo model page."""
    if "Model Not Found" in html[:5000]:
        return None
    app_data: dict[str, Any] | None = None
    for match in JSONLD_RE.finditer(html):
        try:
            data = json.loads(match.group(1))
        except json.JSONDecodeError:
            continue
        if data.get("@type") == "SoftwareApplication":
            app_data = data
            break
    if app_data is None:
        return None
    citation = app_data.get("citation")
    citation_text = None
    if isinstance(citation, dict):
        citation_text = (
            citation.get("headline")
            or citation.get("name")
            or citation.get("identifier")
        )
    elif isinstance(citation, str):
        citation_text = citation
    openness_match = OPENNESS_RE.search(html) or OPENNESS_STAT_RE.search(html)
    license_match = LICENSE_RE.search(html)
    return {
        "slug": slug,
        "url": f"{BIO_RODEO_BASE}/models/{slug}",
        "name": app_data.get("name") or slug,
        "description": app_data.get("description") or "",
        "provider": _provider_name(app_data),
        "citation": citation_text,
        "openness": int(openness_match.group(1)) if openness_match else None,
        "license": license_match.group(1).strip() if license_match else None,
        "application_category": app_data.get("applicationCategory"),
    }


class BioRodeoAdapter:
    """HTML/JSON-LD reader for bio.rodeo with an on-disk cache."""

    def __init__(
        self,
        settings: Settings,
        client: httpx.Client | None = None,
        base_url: str = BIO_RODEO_BASE,
    ) -> None:
        self.settings = settings
        self.base_url = base_url.rstrip("/")
        self.client = client or httpx.Client(
            timeout=20.0,
            headers={"User-Agent": USER_AGENT},
            follow_redirects=True,
        )
        self.cache_file = settings.cache_path / "bio_rodeo.json"

    def sitemap_slugs(self) -> list[str]:
        try:
            response = self.client.get(f"{self.base_url}/sitemap.xml")
            response.raise_for_status()
        except httpx.HTTPError:
            return []
        return list(
            dict.fromkeys(
                re.findall(r"<loc>[^<]*/models/([a-z0-9][a-z0-9-]+)</loc>", response.text)
            )
        )

    def search_slugs(self, query: str, limit: int = 24) -> list[str]:
        try:
            response = self.client.get(
                f"{self.base_url}/models", params={"q": query}
            )
            response.raise_for_status()
        except httpx.HTTPError:
            return []
        return list(dict.fromkeys(SLUG_RE.findall(response.text)))[:limit]

    def fetch_model(self, slug: str) -> dict[str, Any] | None:
        try:
            response = self.client.get(f"{self.base_url}/models/{slug}")
            response.raise_for_status()
        except httpx.HTTPError:
            return None
        return parse_model_page(slug, response.text)

    def fetch_many(self, slugs: Iterable[str], pause: float = 0.15) -> list[dict[str, Any]]:
        records: list[dict[str, Any]] = []
        for slug in dict.fromkeys(slugs):
            record = self.fetch_model(slug)
            if record:
                records.append(record)
            time.sleep(pause)
        return records

    def load_cache(self) -> dict[str, Any]:
        if not self.cache_file.exists():
            return {}
        try:
            return json.loads(self.cache_file.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            return {}

    def cache_fresh(self, payload: dict[str, Any]) -> bool:
        fetched = payload.get("fetched_at")
        if not isinstance(fetched, (int, float)):
            return False
        ttl = max(1, self.settings.bio_rodeo_cache_hours) * 3600
        return (time.time() - fetched) < ttl

    def save_cache(self, payload: dict[str, Any]) -> None:
        self.settings.cache_path.mkdir(parents=True, exist_ok=True)
        self.cache_file.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

    def refresh(self, slugs: Iterable[str] | None = None) -> dict[str, Any]:
        wanted = list(slugs or [])
        if not wanted:
            payload = self.load_cache()
            wanted = [entry["slug"] for entry in payload.get("entries", [])]
        if not wanted:
            wanted = self.sitemap_slugs()[:24]
        records = self.fetch_many(wanted)
        payload = {
            "source": "bio.rodeo",
            "base_url": self.base_url,
            "fetched_at": time.time(),
            "mode": "html + schema.org JSON-LD",
            "api": None,
            "entries": records,
            "note": (
                "bio.rodeo has no public API. Records are parsed from public model "
                "pages; fields may change without notice."
            ),
        }
        self.save_cache(payload)
        return payload


def load_local_catalog() -> list[dict[str, Any]]:
    return json.loads(CATALOG_FILE.read_text(encoding="utf-8"))


def _dir_size_bytes(path: Path) -> int:
    if not path.exists():
        return 0
    total = 0
    for child in path.rglob("*"):
        try:
            if child.is_file():
                total += child.stat().st_size
        except OSError:
            continue
    return total


def _entry_size(entry: dict[str, Any], settings: Settings) -> int:
    runner_id = entry.get("runner_id")
    if runner_id == "alphafold3-mac":
        return _dir_size_bytes(Path(settings.af3_repo).expanduser()) + _dir_size_bytes(
            Path(settings.af3_weights_dir).expanduser()
        )
    if runner_id == "rhofold":
        return _dir_size_bytes(Path(settings.rhofold_repo).expanduser())
    if runner_id == "openfold3":
        return _dir_size_bytes(Path(settings.openfold3_repo).expanduser()) + _dir_size_bytes(
            Path(settings.openfold3_cache).expanduser()
        )
    return 0


class CatalogService:
    def __init__(
        self, settings: Settings, registry: RunnerRegistry, adapter: BioRodeoAdapter | None = None
    ) -> None:
        self.settings = settings
        self.registry = registry
        self.adapter = adapter or BioRodeoAdapter(settings)
        self._size_cache: dict[str, tuple[float, int]] = {}

    def _snapshot(self) -> dict[str, Any]:
        if SNAPSHOT_FILE.exists():
            try:
                return json.loads(SNAPSHOT_FILE.read_text(encoding="utf-8"))
            except json.JSONDecodeError:
                return {}
        return {}

    def rodeo_records(self) -> tuple[dict[str, Any], dict[str, dict[str, Any]]]:
        cached = self.adapter.load_cache()
        snapshot = self._snapshot()
        if cached.get("entries") and (
            self.adapter.cache_fresh(cached) or not snapshot.get("entries")
        ):
            chosen = cached
        else:
            chosen = snapshot
        return chosen, {entry["slug"]: entry for entry in chosen.get("entries", [])}

    def _entry_size(self, entry: dict[str, Any]) -> int:
        """Disk walk with a short cache; status polling must not rescan every 5s."""
        key = entry.get("runner_id") or entry["id"]
        now = time.time()
        cached = self._size_cache.get(key)
        if cached and now - cached[0] < 60:
            return cached[1]
        size = _entry_size(entry, self.settings)
        self._size_cache[key] = (now, size)
        return size

    def sources(self) -> dict[str, Any]:
        rodeo, records = self.rodeo_records()
        return {
            "local": {
                "file": str(CATALOG_FILE),
                "entries": len(load_local_catalog()),
            },
            "bio_rodeo": {
                "base_url": self.adapter.base_url,
                "fetched_at": rodeo.get("fetched_at"),
                "entries": len(records),
                "mode": rodeo.get("mode", "snapshot"),
                "api": None,
                "note": rodeo.get("note"),
            },
        }

    def entries(self) -> tuple[list[CatalogEntry], dict[str, Any]]:
        statuses = {status.id: status for status in self.registry.statuses()}
        manifests = {m.id: m for m in self.registry.manifests()}
        rodeo, records = self.rodeo_records()
        result: list[CatalogEntry] = []
        for raw in load_local_catalog():
            runner_id = raw.get("runner_id")
            record = records.get(raw.get("rodeo_slug", ""), {})
            status = statuses.get(runner_id or "")
            manifest = manifests.get(runner_id or "")
            result.append(
                CatalogEntry(
                    id=raw["id"],
                    name=raw.get("name") or record.get("name") or raw["id"],
                    runner_id=runner_id,
                    provider=record.get("provider") or raw.get("provider"),
                    description=record.get("description") or raw.get("description", ""),
                    tags=raw.get("tags", []),
                    license=raw.get("license") or record.get("license"),
                    openness=record.get("openness"),
                    source="bio.rodeo" if record else "local",
                    source_url=record.get("url") or raw.get("source_url"),
                    entity_types=manifest.entity_types if manifest else raw.get("entity_types", []),
                    runtime=manifest.runtime if manifest else None,
                    device=manifest.device if manifest else None,
                    fallback=manifest.fallback if manifest else None,
                    installed=bool(status and status.installed),
                    ready=bool(status and status.ready),
                    installable=bool(runner_id),
                    size_bytes=self._entry_size(raw),
                    weight_note=manifest.weight_note if manifest else raw.get("weight_note"),
                    weight_request_url=manifest.weight_request_url if manifest else None,
                    weight_dir=manifest.weight_dir if manifest else None,
                )
            )
        sources = {
            "local": {"file": str(CATALOG_FILE), "entries": len(load_local_catalog())},
            "bio_rodeo": {
                "base_url": self.adapter.base_url,
                "fetched_at": rodeo.get("fetched_at"),
                "entries": len(records),
                "mode": rodeo.get("mode", "snapshot"),
                "api": None,
                "note": rodeo.get("note"),
            },
        }
        return result, sources

    def refresh(self, slugs: Iterable[str] | None = None) -> dict[str, Any]:
        return self.adapter.refresh(slugs)
