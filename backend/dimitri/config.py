"""Configuration and storage paths for the Dimitri backend."""

from __future__ import annotations

import json
import os
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any

APP_VERSION = "0.2.0"
DEFAULT_PORT = 8642


def default_home() -> Path:
    return Path(os.environ.get("DIMITRI_HOME", "~/.dimitri")).expanduser()


@dataclass
class Settings:
    """User-editable settings, persisted as ``settings.json`` in the home dir.

    Storage paths are plain strings so they round-trip through JSON and can be
    edited from the app's Settings sheet.
    """

    home: str = field(default_factory=lambda: str(default_home()))
    models_dir: str = ""
    results_dir: str = ""
    cache_dir: str = ""
    lms_base_url: str = "http://localhost:1234/v1"
    af3_repo: str = ""
    af3_weights_dir: str = ""
    mac_af3_repo: str = ""
    rhofold_repo: str = ""
    openfold3_repo: str = ""
    openfold3_cache: str = ""
    bio_rodeo_cache_hours: int = 24
    # Keep models loaded in warm worker processes between jobs.
    warm_workers: bool = True
    # Minutes a loaded model stays warm after its last job. None follows the
    # device profile; -1 keeps it until the backend stops.
    keep_warm_minutes: int | None = None

    def __post_init__(self) -> None:
        home = Path(self.home).expanduser()
        self.models_dir = self.models_dir or str(home / "models")
        self.results_dir = self.results_dir or str(home / "results")
        self.cache_dir = self.cache_dir or str(home / "cache")
        self.af3_repo = self.af3_repo or str(Path(self.models_dir) / "alphafold3-mac")
        self.af3_weights_dir = self.af3_weights_dir or str(
            Path("~/.alphafold3/weights/model").expanduser()
        )
        self.mac_af3_repo = self.mac_af3_repo or str(Path(self.models_dir) / "mac-af3")
        # rhofold-mac checkout (github.com/vasanthsreeram/rhofold-mac).
        self.rhofold_repo = self.rhofold_repo or str(Path(self.models_dir) / "rhofold-mac")
        self.openfold3_repo = self.openfold3_repo or str(
            Path(self.models_dir) / "openfold-3-mlx"
        )
        self.openfold3_cache = self.openfold3_cache or str(
            Path("~/.openfold3").expanduser()
        )

    @property
    def home_path(self) -> Path:
        return Path(self.home).expanduser()

    @property
    def models_path(self) -> Path:
        return Path(self.models_dir).expanduser()

    @property
    def results_path(self) -> Path:
        return Path(self.results_dir).expanduser()

    @property
    def cache_path(self) -> Path:
        return Path(self.cache_dir).expanduser()

    @property
    def settings_file(self) -> Path:
        return self.home_path / "settings.json"

    def ensure_dirs(self) -> None:
        for path in (self.home_path, self.models_path, self.results_path, self.cache_path):
            path.mkdir(parents=True, exist_ok=True)

    def save(self) -> None:
        self.ensure_dirs()
        self.settings_file.write_text(
            json.dumps(asdict(self), indent=2) + "\n", encoding="utf-8"
        )

    def keep_warm_seconds(self, device_default_minutes: int) -> float | None:
        """Seconds a warm worker may idle; None means until the backend stops."""
        if not self.warm_workers:
            return 0.0
        minutes = self.keep_warm_minutes
        if minutes is None:
            minutes = device_default_minutes
        if minutes < 0:
            return None
        return float(minutes) * 60.0

    def update(self, patch: dict[str, Any]) -> "Settings":
        allowed = set(asdict(self))
        for key, value in patch.items():
            if key in allowed and value is not None:
                setattr(self, key, value)
        self.__post_init__()
        self.save()
        return self

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)

    @classmethod
    def load(cls, home: Path | None = None) -> "Settings":
        root = home.expanduser() if home else default_home()
        path = root / "settings.json"
        data: dict[str, Any] = {}
        if path.exists():
            try:
                data = json.loads(path.read_text(encoding="utf-8"))
            except json.JSONDecodeError:
                data = {}
        data["home"] = str(root)
        # Phase 1 pointed RhoFold at a bare ml4bio/RhoFold checkout under
        # models/rhofold. The runner now uses rhofold-mac; drop the old default.
        old = data.get("rhofold_repo")
        models_dir = data.get("models_dir") or str(root / "models")
        if old and Path(old).expanduser() == Path(models_dir).expanduser() / "rhofold":
            data.pop("rhofold_repo")
        return cls(**{k: v for k, v in data.items() if k in cls.__dataclass_fields__})
