#!/usr/bin/env bash
# Start only the backend on http://127.0.0.1:8642 (for scripts or debugging).
# The Mac app normally starts and stops it for you; if this one is running,
# the app uses it and leaves it running when it quits.
set -euo pipefail
cd "$(dirname "$0")/../backend"

if ! command -v uv >/dev/null 2>&1; then
  echo "uv is required: https://docs.astral.sh/uv/getting-started/installation/" >&2
  exit 1
fi

if [ ! -x .venv/bin/python ]; then
  echo "Creating the backend environment (first run)…"
  uv sync --extra dev
fi

exec .venv/bin/python -m dimitri --port 8642
