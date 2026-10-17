#!/usr/bin/env bash
# Launch the Mac app. The backend must already be running.
set -euo pipefail
cd "$(dirname "$0")/../app"

if ! command -v swift >/dev/null 2>&1; then
  echo "Swift is required. Install Xcode or the Command Line Tools." >&2
  exit 1
fi

exec swift run
