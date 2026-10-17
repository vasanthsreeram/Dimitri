#!/usr/bin/env bash
# Backend tests, the Mac app build, and (when a display is available) the
# offline Mol* viewer check on 1L2Y.
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

if [ -x "$ROOT/scripts/viewer-check.sh" ] && [ "${SKIP_VIEWER_CHECK:-0}" != 1 ]; then
  echo "== viewer check (bundled Mol*, no network)"
  "$ROOT/scripts/viewer-check.sh" "$ROOT/backend/dimitri/data/1l2y.pdb"
fi
