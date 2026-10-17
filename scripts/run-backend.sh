#!/usr/bin/env bash
# Start the Dimitri backend on http://127.0.0.1:8642
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

exec .venv/bin/uvicorn dimitri.main:app --host 127.0.0.1 --port 8642
