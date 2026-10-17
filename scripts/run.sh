#!/usr/bin/env bash
# One command from a checkout: build and launch the Mac app. The app starts the
# local backend itself (creating backend/.venv with uv on first run), reuses a
# backend that is already running on port 8642, and stops the one it started
# when you quit.
set -euo pipefail
cd "$(dirname "$0")/../app"

if ! command -v swift >/dev/null 2>&1; then
  echo "Swift is required. Install Xcode or the Command Line Tools: xcode-select --install" >&2
  exit 1
fi

exec swift run
