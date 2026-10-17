#!/usr/bin/env bash
# AlphaFold 3 (alphafold3-mac) setup for Dimitri Studio.
# Usage: alphafold3-mac.sh <repo-dir>
#
# Clones the MLX port and syncs its uv environment. Its own installer is
# interactive (it configures HMMER databases and native extensions), so Dimitri
# runs the non-interactive parts and then tells the user what is left.
set -euo pipefail

if [ "$(uname -s)" != "Darwin" ] || [ "$(uname -m)" != "arm64" ]; then
  echo "Dimitri Studio is MacBook-only (Apple Silicon). Linux/CUDA installs are not supported." >&2
  exit 1
fi

if ! command -v uv >/dev/null 2>&1; then
  echo "uv is required: https://docs.astral.sh/uv/getting-started/installation/" >&2
  exit 1
fi

REPO="${1:?repo dir required}"

mkdir -p "$(dirname "$REPO")"
if [ ! -d "$REPO/.git" ]; then
  echo "Cloning alphafold3-mac into $REPO"
  git clone https://github.com/omrikais/alphafold3-mac.git "$REPO"
fi

cd "$REPO"
if [ ! -x .venv/bin/python ]; then
  echo "Creating the project environment with uv"
  rm -rf .venv
  uv venv --python 3.12 .venv
fi
echo "Syncing the project environment with uv"
uv sync

echo "alphafold3-mac checkout is ready at $REPO"
echo "If the CLI still fails to start, run ./scripts/install.sh in that directory."
