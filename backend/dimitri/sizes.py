"""Directory sizes computed off the request path.

A model checkout with its Python environment holds tens of thousands of
files; walking it inside an HTTP request made status polling slow. Sizes are
computed on one background thread and served from cache (0 until the first
walk finishes).
"""

from __future__ import annotations

import os
import threading
import time
from pathlib import Path
from typing import Iterable


def dir_size(path: Path) -> int:
    total = 0
    stack = [str(path)]
    while stack:
        current = stack.pop()
        try:
            with os.scandir(current) as entries:
                for entry in entries:
                    try:
                        if entry.is_symlink():
                            continue
                        if entry.is_dir(follow_symlinks=False):
                            stack.append(entry.path)
                        else:
                            total += entry.stat(follow_symlinks=False).st_size
                    except OSError:
                        continue
        except OSError:
            continue
    return total


class DiskSizer:
    def __init__(self, ttl: float = 120.0) -> None:
        self.ttl = ttl
        self._sizes: dict[str, tuple[float, int]] = {}
        self._pending: set[str] = set()
        self._lock = threading.Lock()
        self._wake = threading.Event()
        self._thread = threading.Thread(target=self._loop, daemon=True)
        self._thread.start()

    def size(self, paths: Iterable[Path | str]) -> int:
        """Cached total size of ``paths``; schedules a refresh when stale."""
        total = 0
        now = time.time()
        for raw in paths:
            key = str(Path(raw).expanduser())
            with self._lock:
                cached = self._sizes.get(key)
                if cached is None or now - cached[0] > self.ttl:
                    self._pending.add(key)
                    self._wake.set()
                total += cached[1] if cached else 0
        return total

    def invalidate(self, path: Path | str | None = None) -> None:
        with self._lock:
            if path is None:
                self._pending.update(self._sizes)
            else:
                self._pending.add(str(Path(path).expanduser()))
            self._wake.set()

    def compute_now(self, paths: Iterable[Path | str]) -> int:
        """Walk synchronously (tests and first-run CLI use)."""
        total = 0
        for raw in paths:
            key = str(Path(raw).expanduser())
            value = dir_size(Path(key)) if Path(key).exists() else 0
            with self._lock:
                self._sizes[key] = (time.time(), value)
            total += value
        return total

    def _loop(self) -> None:
        while True:
            self._wake.wait()
            with self._lock:
                todo = list(self._pending)
                self._pending.clear()
                self._wake.clear()
            for key in todo:
                path = Path(key)
                value = dir_size(path) if path.exists() else 0
                with self._lock:
                    self._sizes[key] = (time.time(), value)
