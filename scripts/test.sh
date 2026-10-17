#!/usr/bin/env bash
# Run the backend test suite and compile the Mac app.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "== backend tests"
cd "$ROOT/backend"
if [ ! -x .venv/bin/python ]; then
  uv sync --extra dev
fi
.venv/bin/python -m pytest -q

echo "== swift build"
cd "$ROOT/app"
swift build
