"""Persistent warm workers: one long-lived model process per runner.

Phase 1 started a fresh Python process for every prediction, so each job paid
for interpreter start-up, importing PyTorch or MLX and loading the weights
before doing any work. A warm worker does that once, then serves predictions
until it has been idle for a while (or another model needs the memory).

Workers run in the model's own environment, so the backend never imports
PyTorch or MLX. They speak JSON lines on stdin/stdout:

  backend → worker  {"type": "predict", "job": id, "request": {...}, "workdir": path}
                    {"type": "shutdown"}
  worker → backend  {"type": "ready", "device": "mps", "load_s": 1.2, "info": {...}}
                    {"type": "progress", "job": id, "stage": "fold", "fraction": 0.4,
                     "message": "Recycle 4/10"}
                    {"type": "log", "message": "..."}
                    {"type": "result", "job": id, "result": {...}}
                    {"type": "error", "job": id, "message": "...", "hint": "...",
                     "fatal": false}

Other stdout lines and all of stderr go to the worker's log file. A worker exits
when its stdin closes, so it never outlives the backend.
"""

from __future__ import annotations

import ctypes
import hashlib
import json
import os
import signal
import subprocess
import threading
import time
from collections import deque
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable

from .models import WorkerStatus
from .runners.base import JobControl, RunnerError, RunnerNotReady

EventFn = Callable[[dict[str, Any]], None]


class WorkerError(RunnerError):
    """The worker process failed to start, crashed, or broke the protocol."""

    def __init__(self, message: str, tail: list[str] | None = None) -> None:
        detail = "\n".join((tail or [])[-12:]).strip()
        super().__init__(f"{message}\n{detail}" if detail else message)
        self.tail = tail or []


@dataclass(frozen=True)
class WorkerSpec:
    """How to launch a runner's worker. A changed spec restarts the worker."""

    runner_id: str
    argv: tuple[str, ...]
    cwd: str
    env: tuple[tuple[str, str], ...] = field(default_factory=tuple)
    ready_timeout: float = 900.0

    @property
    def signature(self) -> str:
        payload = json.dumps([self.argv, self.cwd, sorted(self.env)])
        return hashlib.sha1(payload.encode()).hexdigest()[:16]


class WarmWorker:
    def __init__(self, spec: WorkerSpec, log_path: Path) -> None:
        self.spec = spec
        self.log_path = log_path
        self.state = "starting"
        self.started_at = time.time()
        self.last_used = self.started_at
        self.jobs_served = 0
        self.ready_info: dict[str, Any] = {}
        self.loading_message: str | None = None
        self.detail: str | None = None
        self._ready = threading.Event()
        self._exited = threading.Event()
        self._request_lock = threading.Lock()
        self._outbox: deque[dict[str, Any]] = deque()
        self._outbox_cv = threading.Condition()
        self._tail: deque[str] = deque(maxlen=80)
        log_path.parent.mkdir(parents=True, exist_ok=True)
        self._log = log_path.open("a", encoding="utf-8", buffering=1)
        self._log.write(f"\n=== {time.strftime('%Y-%m-%d %H:%M:%S')} start {spec.runner_id}\n")
        try:
            self.proc = subprocess.Popen(
                list(spec.argv),
                cwd=spec.cwd,
                env=dict(spec.env),
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                bufsize=1,
                start_new_session=True,
            )
        except OSError as exc:
            self.state = "dead"
            self._log.close()
            raise WorkerError(f"{spec.runner_id} worker could not start: {exc}") from exc
        threading.Thread(target=self._read_stdout, daemon=True).start()
        threading.Thread(target=self._read_stderr, daemon=True).start()

    # ------------------------------------------------------------ plumbing
    def _note(self, line: str) -> None:
        self._tail.append(line)
        try:
            self._log.write(line + "\n")
        except ValueError:
            pass  # log closed during shutdown

    def _read_stdout(self) -> None:
        assert self.proc.stdout is not None
        for raw in self.proc.stdout:
            line = raw.rstrip("\n")
            message = _parse(line)
            if message is None:
                self._note(line)
                continue
            kind = message.get("type")
            if kind == "ready":
                self.ready_info = message
                if self.state == "starting":
                    self.state = "ready"
                self._ready.set()
            elif kind == "log":
                self._note(str(message.get("message", "")))
            elif kind == "progress" and self.state == "starting":
                self.loading_message = str(message.get("message") or "")
            elif kind == "error" and self.state == "starting":
                self.detail = str(message.get("message") or "")
                self._push(message)
            else:
                self._push(message)
        self._exited.set()
        if self.state != "stopping":
            self.state = "dead"
        self._push({"type": "exit"})

    def _read_stderr(self) -> None:
        assert self.proc.stderr is not None
        for raw in self.proc.stderr:
            self._note(raw.rstrip("\n"))

    def _push(self, message: dict[str, Any]) -> None:
        with self._outbox_cv:
            self._outbox.append(message)
            self._outbox_cv.notify_all()

    def _pop(self, timeout: float) -> dict[str, Any] | None:
        with self._outbox_cv:
            if not self._outbox:
                self._outbox_cv.wait(timeout)
            return self._outbox.popleft() if self._outbox else None

    def _send(self, message: dict[str, Any]) -> None:
        if self.proc.stdin is None or self.proc.poll() is not None:
            raise WorkerError(f"{self.spec.runner_id} worker is not running", list(self._tail))
        try:
            self.proc.stdin.write(json.dumps(message) + "\n")
            self.proc.stdin.flush()
        except (BrokenPipeError, OSError) as exc:
            raise WorkerError(
                f"{self.spec.runner_id} worker stopped accepting work: {exc}", list(self._tail)
            ) from exc

    @property
    def alive(self) -> bool:
        return self.proc.poll() is None

    @property
    def tail(self) -> list[str]:
        return list(self._tail)

    # ------------------------------------------------------------- lifecycle
    def wait_ready(self, control: JobControl | None, on_event: EventFn | None = None) -> dict:
        deadline = time.time() + self.spec.ready_timeout
        shown: str | None = None
        while not self._ready.is_set():
            if control is not None and control.cancelled:
                self.kill()
                raise RunnerError("cancelled")
            if self.loading_message and self.loading_message != shown and on_event:
                shown = self.loading_message
                on_event({"type": "progress", "stage": None, "fraction": 0.5, "message": shown})
            failure = self._pop_startup_error()
            if failure is not None:
                self.kill()
                raise _error_from(failure, self.tail)
            if self._exited.is_set() or not self.alive:
                self.state = "dead"
                raise WorkerError(
                    f"{self.spec.runner_id} stopped while loading the model", self.tail
                )
            if time.time() > deadline:
                self.kill()
                raise WorkerError(
                    f"{self.spec.runner_id} did not finish loading in "
                    f"{int(self.spec.ready_timeout)} s",
                    self.tail,
                )
            self._ready.wait(0.2)
        return self.ready_info

    def _pop_startup_error(self) -> dict[str, Any] | None:
        with self._outbox_cv:
            for message in list(self._outbox):
                if message.get("type") == "error":
                    self._outbox.remove(message)
                    return message
        return None

    def request(
        self,
        payload: dict[str, Any],
        on_event: EventFn,
        control: JobControl,
    ) -> dict[str, Any]:
        with self._request_lock:
            if not self._ready.is_set():
                raise WorkerError(f"{self.spec.runner_id} worker is not ready", self.tail)
            with self._outbox_cv:
                self._outbox.clear()
            self.state = "busy"
            self.last_used = time.time()
            self._send(payload)
            try:
                while True:
                    if control.cancelled:
                        self.kill()
                        raise RunnerError("cancelled")
                    message = self._pop(0.2)
                    if message is None:
                        continue
                    kind = message.get("type")
                    if kind == "exit":
                        raise WorkerError(
                            f"{self.spec.runner_id} worker exited during the job", self.tail
                        )
                    if kind == "progress":
                        on_event(message)
                    elif kind == "result":
                        self.jobs_served += 1
                        return message.get("result") or {}
                    elif kind == "error":
                        if message.get("fatal"):
                            self.kill()
                        raise _error_from(message, self.tail)
            finally:
                self.last_used = time.time()
                if self.alive and self.state == "busy":
                    self.state = "ready"

    def stop(self, timeout: float = 5.0) -> None:
        if not self.alive:
            self._close()
            return
        self.state = "stopping"
        try:
            self._send({"type": "shutdown"})
        except WorkerError:
            pass
        try:
            self.proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            self.kill()
        self._close()

    def kill(self) -> None:
        self.state = "stopping"
        for sig, wait in ((signal.SIGTERM, 3.0), (signal.SIGKILL, 3.0)):
            if self.proc.poll() is not None:
                break
            try:
                os.killpg(os.getpgid(self.proc.pid), sig)
            except (ProcessLookupError, PermissionError):
                try:
                    self.proc.send_signal(sig)
                except ProcessLookupError:
                    break
            try:
                self.proc.wait(timeout=wait)
            except subprocess.TimeoutExpired:
                continue
        self.state = "dead"
        self._close()

    def _close(self) -> None:
        for stream in (self.proc.stdin,):
            try:
                if stream:
                    stream.close()
            except OSError:
                pass
        try:
            self._log.close()
        except OSError:
            pass

    def footprint_mb(self) -> float | None:
        """Physical footprint (includes Metal buffers, unlike RSS)."""
        if not self.alive:
            return None
        value = phys_footprint(self.proc.pid)
        return round(value / 1024**2, 1) if value else None

    def status(self, with_memory: bool = False) -> WorkerStatus:
        state = self.state if self.alive or self.state == "starting" else "dead"
        return WorkerStatus(
            runner_id=self.spec.runner_id,
            state=state,  # type: ignore[arg-type]
            pid=self.proc.pid if self.alive else None,
            started_at=self.started_at,
            last_used=self.last_used,
            jobs_served=self.jobs_served,
            load_s=_float(self.ready_info.get("load_s")),
            device=self.ready_info.get("device"),
            rss_mb=self.footprint_mb() if with_memory else None,
            detail=self.detail or (self.loading_message if state == "starting" else None),
        )


class WorkerPool:
    """Keeps warm workers alive between jobs and evicts them when idle.

    ``keep_warm_s`` of None keeps workers until the backend stops; 0 stops a
    worker as soon as its job finishes (the cold behaviour). At most
    ``max_resident`` workers are alive; the least recently used idle one is
    stopped to make room.
    """

    def __init__(
        self,
        log_dir: Path,
        *,
        keep_warm_s: float | None = 900.0,
        max_resident: int = 1,
        reap_interval: float = 10.0,
    ) -> None:
        self.log_dir = log_dir
        self.keep_warm_s = keep_warm_s
        self.max_resident = max(1, max_resident)
        self._workers: dict[str, WarmWorker] = {}
        self._lock = threading.RLock()
        self._listeners: list[Callable[[], None]] = []
        self._closed = False
        self._reaper = threading.Thread(
            target=self._reap_loop, args=(reap_interval,), daemon=True
        )
        self._reaper.start()

    # ---------------------------------------------------------- configuration
    def configure(self, *, keep_warm_s: float | None, max_resident: int) -> None:
        with self._lock:
            self.keep_warm_s = keep_warm_s
            self.max_resident = max(1, max_resident)
        self._reap_idle()

    def subscribe(self, listener: Callable[[], None]) -> None:
        self._listeners.append(listener)

    def _changed(self) -> None:
        for listener in list(self._listeners):
            try:
                listener()
            except Exception:  # listeners must never break the pool
                pass

    # ---------------------------------------------------------------- access
    def acquire(
        self,
        spec: WorkerSpec,
        control: JobControl | None = None,
        on_event: EventFn | None = None,
    ) -> tuple[WarmWorker, bool]:
        """Return a ready worker for ``spec`` and whether it was already warm."""
        stale: list[WarmWorker] = []
        with self._lock:
            if self._closed:
                raise WorkerError("the backend is shutting down")
            worker = self._workers.get(spec.runner_id)
            if worker and (not worker.alive or worker.spec.signature != spec.signature):
                stale.append(self._workers.pop(spec.runner_id))
                worker = None
            if worker is None:
                stale.extend(self._make_room(exclude=spec.runner_id))
                worker = WarmWorker(spec, self.log_dir / f"{spec.runner_id}.log")
                self._workers[spec.runner_id] = worker
                was_warm = False
            else:
                was_warm = worker.state in ("ready", "busy")
        for old in stale:
            old.stop()
        self._changed()
        try:
            worker.wait_ready(control, on_event)
        except BaseException:
            with self._lock:
                if self._workers.get(spec.runner_id) is worker:
                    del self._workers[spec.runner_id]
            self._changed()
            raise
        self._changed()
        return worker, was_warm

    def run(
        self,
        spec: WorkerSpec,
        payload: dict[str, Any],
        on_event: EventFn,
        control: JobControl,
    ) -> tuple[dict[str, Any], dict[str, Any]]:
        """Run one request; returns ``(result, info)`` where info says whether
        the worker was already warm and how long loading took."""
        started = time.time()
        worker, was_warm = self.acquire(spec, control, on_event)
        ready_s = time.time() - started
        self._changed()
        try:
            result = worker.request(payload, on_event, control)
        finally:
            with self._lock:
                if not worker.alive and self._workers.get(spec.runner_id) is worker:
                    del self._workers[spec.runner_id]
            if self.keep_warm_s == 0 and worker.alive:
                self.stop(spec.runner_id)
            self._changed()
        info = {
            "warm": was_warm,
            "wait_for_model_s": round(ready_s, 2),
            "load_s": _float(worker.ready_info.get("load_s")),
            "device": worker.ready_info.get("device"),
        }
        return result, info

    def prewarm(self, spec: WorkerSpec) -> bool:
        """Start loading a model in the background; False if already warm."""
        with self._lock:
            worker = self._workers.get(spec.runner_id)
            if worker and worker.alive and worker.spec.signature == spec.signature:
                return False

        def load() -> None:
            try:
                self.acquire(spec)
            except RunnerError:
                pass  # the failure is visible in the worker log and status

        threading.Thread(target=load, daemon=True).start()
        return True

    def is_warm(self, runner_id: str) -> bool:
        with self._lock:
            worker = self._workers.get(runner_id)
            return bool(worker and worker.alive and worker.state in ("ready", "busy"))

    def stop(self, runner_id: str) -> bool:
        with self._lock:
            worker = self._workers.pop(runner_id, None)
        if worker is None:
            return False
        worker.stop()
        self._changed()
        return True

    def shutdown(self) -> None:
        with self._lock:
            self._closed = True
            workers = list(self._workers.values())
            self._workers.clear()
        threads = [threading.Thread(target=w.stop, daemon=True) for w in workers]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(timeout=8)

    def statuses(self, with_memory: bool = False) -> list[WorkerStatus]:
        with self._lock:
            workers = list(self._workers.values())
        return [worker.status(with_memory) for worker in workers]

    # -------------------------------------------------------------- eviction
    def _make_room(self, exclude: str) -> list[WarmWorker]:
        """Pop least recently used idle workers until a new one fits."""
        evicted: list[WarmWorker] = []
        others = [
            (worker.last_used, runner_id)
            for runner_id, worker in self._workers.items()
            if runner_id != exclude
        ]
        others.sort()
        while len(self._workers) >= self.max_resident and others:
            _, runner_id = others.pop(0)
            worker = self._workers[runner_id]
            if worker.state == "busy":
                continue
            evicted.append(self._workers.pop(runner_id))
        return evicted

    def _reap_idle(self) -> None:
        now = time.time()
        expired: list[WarmWorker] = []
        with self._lock:
            for runner_id, worker in list(self._workers.items()):
                if not worker.alive and worker.state != "starting":
                    expired.append(self._workers.pop(runner_id))
                elif (
                    self.keep_warm_s is not None
                    and worker.state == "ready"
                    and now - worker.last_used > self.keep_warm_s
                ):
                    expired.append(self._workers.pop(runner_id))
        for worker in expired:
            worker.stop()
        if expired:
            self._changed()

    def _reap_loop(self, interval: float) -> None:
        while not self._closed:
            time.sleep(interval)
            try:
                self._reap_idle()
            except Exception:  # keep reaping even if one stop fails
                pass


_RUSAGE_INFO_V4 = 4
_FOOTPRINT_OFFSET = 72  # rusage_info_v4.ri_phys_footprint: 16-byte uuid + 7 uint64 fields
try:
    _LIBPROC = ctypes.CDLL("/usr/lib/libproc.dylib")
except OSError:  # not macOS
    _LIBPROC = None


def phys_footprint(pid: int) -> int | None:
    """``phys_footprint`` of a process in bytes, the number Activity Monitor shows."""
    if _LIBPROC is None:
        return None
    buffer = ctypes.create_string_buffer(512)
    if _LIBPROC.proc_pid_rusage(ctypes.c_int(pid), ctypes.c_int(_RUSAGE_INFO_V4), buffer) != 0:
        return None
    return int.from_bytes(buffer.raw[_FOOTPRINT_OFFSET : _FOOTPRINT_OFFSET + 8], "little")


def _parse(line: str) -> dict[str, Any] | None:
    if not line.startswith("{"):
        return None
    try:
        value = json.loads(line)
    except json.JSONDecodeError:
        return None
    return value if isinstance(value, dict) and "type" in value else None


def _error_from(message: dict[str, Any], tail: list[str]) -> RunnerError:
    text = str(message.get("message") or "The model worker reported an error.")
    hint = message.get("hint")
    if message.get("not_ready"):
        return RunnerNotReady(text, hint=hint)
    error = RunnerError(text)
    error.hint = hint  # type: ignore[attr-defined]
    return error


def _float(value: Any) -> float | None:
    try:
        return round(float(value), 2) if value is not None else None
    except (TypeError, ValueError):
        return None
