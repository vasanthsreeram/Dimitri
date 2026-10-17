"""Runner plugin interface.

A runner is one Python class plus a manifest. The backend discovers runners
through :mod:`dimitri.runners.registry`, exposes their manifests over HTTP, and
calls :meth:`Runner.run` for predictions and :meth:`Runner.install` for setup.

Nothing here assumes a particular framework: runners shell out to their own
environment or import their own libraries, and return a structure plus
confidence data through :class:`RunResult`.
"""

from __future__ import annotations

import shutil
import signal
import subprocess
import threading
from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Sequence

from ..config import Settings
from ..models import InstallResult, RunResult, RunnerManifestModel, RunnerStatusModel, Stage


class RunnerError(RuntimeError):
    """A prediction failed for a reason the runner can describe."""


class RunnerNotReady(RunnerError):
    """The runner cannot run until the user installs it or its weights."""

    def __init__(self, message: str, hint: str | None = None) -> None:
        super().__init__(message)
        self.hint = hint


@dataclass(frozen=True)
class StageSpec:
    id: str
    name: str


@dataclass(frozen=True)
class RunnerManifest:
    id: str
    name: str
    short_name: str
    version: str
    description: str
    entity_types: tuple[str, ...]
    source_url: str
    stages: tuple[StageSpec, ...]
    citation: str | None = None
    license: str | None = None
    weight_note: str | None = None
    weight_request_url: str | None = None
    weight_dir_key: str | None = None
    requires_weights: bool = True
    setup_hint: str | None = None
    visible: bool = True

    def to_model(self, settings: Settings) -> RunnerManifestModel:
        weight_dir = (
            getattr(settings, self.weight_dir_key, None) if self.weight_dir_key else None
        )
        return RunnerManifestModel(
            id=self.id,
            name=self.name,
            short_name=self.short_name,
            version=self.version,
            description=self.description,
            entity_types=list(self.entity_types),
            source_url=self.source_url,
            citation=self.citation,
            license=self.license,
            weight_note=self.weight_note,
            weight_request_url=self.weight_request_url,
            weight_dir=weight_dir,
            requires_weights=self.requires_weights,
            setup_hint=self.setup_hint,
            stages=[Stage(id=s.id, name=s.name) for s in self.stages],
            visible=self.visible,
        )


ProgressFn = Callable[[str, float, str | None], None]


class JobControl:
    """Cooperative cancellation and process control for one job."""

    def __init__(self) -> None:
        self._event = threading.Event()
        self._lock = threading.Lock()
        self._proc: subprocess.Popen[str] | None = None

    @property
    def cancelled(self) -> bool:
        return self._event.is_set()

    def cancel(self) -> None:
        self._event.set()
        with self._lock:
            proc = self._proc
        if proc and proc.poll() is None:
            try:
                proc.send_signal(signal.SIGTERM)
            except ProcessLookupError:
                pass

    def attach(self, proc: subprocess.Popen[str]) -> None:
        with self._lock:
            self._proc = proc
        if self.cancelled and proc.poll() is None:
            proc.send_signal(signal.SIGTERM)

    def detach(self) -> None:
        with self._lock:
            self._proc = None


class Runner(ABC):
    manifest: RunnerManifest

    @abstractmethod
    def status(self, settings: Settings) -> RunnerStatusModel: ...

    @abstractmethod
    def install(
        self, settings: Settings, progress: ProgressFn, control: JobControl
    ) -> InstallResult: ...

    @abstractmethod
    def run(
        self,
        request,  # PredictionRequest — typed loosely to avoid a cycle
        workdir: Path,
        settings: Settings,
        progress: ProgressFn,
        control: JobControl,
    ) -> RunResult: ...


def which_or_none(name: str) -> str | None:
    return shutil.which(name)


def run_command(
    args: Sequence[str],
    *,
    cwd: Path | None,
    env: dict[str, str] | None,
    control: JobControl,
    on_line: Callable[[str], None],
    label: str,
) -> None:
    """Run a subprocess, stream its output, and honour cancellation."""
    if control.cancelled:
        raise RunnerError("cancelled")
    try:
        proc = subprocess.Popen(
            list(args),
            cwd=str(cwd) if cwd else None,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
            start_new_session=True,
        )
    except FileNotFoundError as exc:
        raise RunnerError(f"{label} could not start: {exc}") from exc
    control.attach(proc)
    try:
        assert proc.stdout is not None
        for line in proc.stdout:
            on_line(line.rstrip())
            if control.cancelled:
                break
        code = proc.wait()
    finally:
        control.detach()
    if control.cancelled:
        raise RunnerError("cancelled")
    if code != 0:
        raise RunnerError(f"{label} exited with code {code}")


def tail_lines(lines: list[str], limit: int = 60) -> list[str]:
    return lines[-limit:]


@dataclass
class LogBuffer:
    """Keep a bounded tail of subprocess output for the job record."""

    lines: list[str] = field(default_factory=list)
    limit: int = 120

    def add(self, line: str) -> None:
        self.lines.append(line)
        if len(self.lines) > self.limit:
            del self.lines[: len(self.lines) - self.limit]

    def text(self) -> list[str]:
        return list(self.lines)
