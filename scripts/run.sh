#!/usr/bin/env bash
# One command: start the local backend, wait for health, then launch the app.
# If a backend is already listening on 8642, leave it alone.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT=8642
BACKEND_PID=""

cleanup() {
  if [ -n "$BACKEND_PID" ] && kill -0 "$BACKEND_PID" 2>/dev/null; then
    kill "$BACKEND_PID" 2>/dev/null || true
    wait "$BACKEND_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

if ! curl -fsS "http://127.0.0.1:${PORT}/api/health" >/dev/null 2>&1; then
  echo "Starting Dimitri backend on port ${PORT}…"
  "$ROOT/scripts/run-backend.sh" &
  BACKEND_PID=$!
  for _ in $(seq 1 60); do
    if curl -fsS "http://127.0.0.1:${PORT}/api/health" >/dev/null 2>&1; then
      break
    fi
    if ! kill -0 "$BACKEND_PID" 2>/dev/null; then
      echo "Backend exited before it became healthy." >&2
      exit 1
    fi
    sleep 0.5
  done
  if ! curl -fsS "http://127.0.0.1:${PORT}/api/health" >/dev/null 2>&1; then
    echo "Backend did not become healthy on port ${PORT}." >&2
    exit 1
  fi
  echo "Backend ready."
else
  echo "Using the backend already running on port ${PORT}."
fi

echo "Launching Dimitri Studio…"
"$ROOT/scripts/run-app.sh"
