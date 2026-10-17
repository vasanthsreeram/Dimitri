"""Worker side of Dimitri's JSON-lines protocol (see dimitri/workers.py).

Worker scripts run inside each model's own Python environment, so this module
uses the standard library only and must not import the ``dimitri`` package.

The protocol owns the process's original stdout. File descriptor 1 is
redirected to stderr before any model code is imported, so prints from model
code, C extensions or Metal logging cannot corrupt the protocol stream.
"""

from __future__ import annotations

import json
import os
import sys
import threading
import time
import traceback
from typing import Any, Callable, Iterator


class WorkerFailure(Exception):
    """A problem the user can act on; reported without a traceback."""

    def __init__(self, message: str, hint: str | None = None, *, not_ready: bool = False) -> None:
        super().__init__(message)
        self.hint = hint
        self.not_ready = not_ready


class Channel:
    def __init__(self) -> None:
        protocol_fd = os.dup(1)
        os.dup2(2, 1)
        self._out = os.fdopen(protocol_fd, "w", buffering=1, encoding="utf-8")
        sys.stdout = sys.stderr
        self._lock = threading.Lock()
        self.job: str | None = None

    def send(self, **message: Any) -> None:
        line = json.dumps(message, separators=(",", ":"), default=_jsonable)
        with self._lock:
            self._out.write(line + "\n")
            self._out.flush()

    def progress(self, stage: str | None, fraction: float, message: str | None = None) -> None:
        self.send(
            type="progress",
            job=self.job,
            stage=stage,
            fraction=round(max(0.0, min(1.0, float(fraction))), 4),
            message=message,
        )

    def log(self, message: str) -> None:
        self.send(type="log", message=message)

    def requests(self) -> Iterator[dict[str, Any]]:
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                message = json.loads(line)
            except json.JSONDecodeError:
                self.log(f"ignored a malformed request: {line[:120]}")
                continue
            if isinstance(message, dict):
                yield message


def serve(
    load: Callable[[Channel], tuple[Any, dict[str, Any]]],
    predict: Callable[[Any, dict[str, Any], Channel], dict[str, Any]],
    *,
    after_job: Callable[[Any], None] | None = None,
) -> int:
    """Load once, then answer predict requests until shutdown or stdin closes.

    ``load`` returns ``(state, ready_info)``; ready_info should include
    ``device``. ``predict`` returns the result payload for one request.
    """
    channel = Channel()
    started = time.perf_counter()
    try:
        state, info = load(channel)
    except WorkerFailure as exc:
        channel.send(
            type="error",
            job=None,
            message=str(exc),
            hint=exc.hint,
            fatal=True,
            not_ready=exc.not_ready,
        )
        return 2
    except Exception as exc:  # report, then exit: the backend shows the tail
        traceback.print_exc()
        channel.send(
            type="error",
            job=None,
            message=f"Model failed to load: {type(exc).__name__}: {exc}",
            fatal=True,
        )
        return 1
    info = dict(info)
    info.setdefault("load_s", round(time.perf_counter() - started, 2))
    channel.send(type="ready", pid=os.getpid(), **info)

    for request in channel.requests():
        kind = request.get("type")
        if kind == "shutdown":
            break
        if kind != "predict":
            continue
        channel.job = request.get("job")
        try:
            result = predict(state, request, channel)
            channel.send(type="result", job=channel.job, result=result)
        except WorkerFailure as exc:
            channel.send(type="error", job=channel.job, message=str(exc), hint=exc.hint)
        except MemoryError as exc:
            channel.send(
                type="error",
                job=channel.job,
                message=f"Out of memory: {exc}",
                hint="Close other apps or try a shorter sequence.",
            )
        except Exception as exc:
            traceback.print_exc()
            channel.send(
                type="error",
                job=channel.job,
                message=f"{type(exc).__name__}: {exc}",
            )
        finally:
            channel.job = None
            if after_job is not None:
                try:
                    after_job(state)
                except Exception:
                    traceback.print_exc()
    return 0


def memory_budget_bytes() -> int | None:
    """The GPU memory budget the backend sized for this Mac, in bytes."""
    try:
        return int(float(os.environ["DIMITRI_GPU_BUDGET_GB"]) * 1024**3)
    except (KeyError, ValueError):
        return None


def _jsonable(value: Any) -> Any:
    if hasattr(value, "tolist"):
        return value.tolist()
    if hasattr(value, "item"):
        return value.item()
    return str(value)
