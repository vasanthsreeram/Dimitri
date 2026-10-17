"""Start the backend: ``python -m dimitri [--port N] [--parent-pid PID]``.

The Mac app starts the backend this way and passes its own process id, so the
backend (and its warm model workers) exit when the app quits or crashes.
"""

from __future__ import annotations

import argparse

from .config import DEFAULT_PORT
from .main import run


def main() -> None:
    parser = argparse.ArgumentParser(prog="python -m dimitri")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--parent-pid", type=int, default=None)
    args = parser.parse_args()
    run(port=args.port, parent_pid=args.parent_pid)


if __name__ == "__main__":
    main()
