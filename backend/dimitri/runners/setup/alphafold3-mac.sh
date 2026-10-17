#!/usr/bin/env bash
# AlphaFold 3 (alphafold3-mac) setup for Dimitri Studio.
# Usage: alphafold3-mac.sh <repo-dir>
#
# Clones the MLX port and syncs its uv environment. Its own installer is
# interactive (it configures HMMER databases and native extensions), so Dimitri
# runs the non-interactive parts and then tells the user what is left.
set -euo pipefail

REPO="${1:?repo dir required}"

mkdir -p "$(dirname "$REPO")"
if [ ! -d "$REPO/.git" ]; then
  echo "Cloning alphafold3-mac into $REPO"
  git clone https://github.com/omrikais/alphafold3-mac.git "$REPO"
fi

cd "$REPO"
if [ ! -d .venv ]; then
  echo "Syncing the project environment with uv"
  uv sync
fi

echo "alphafold3-mac checkout is ready at $REPO"
echo "If the CLI still fails to start, run ./scripts/install.sh in that directory."
