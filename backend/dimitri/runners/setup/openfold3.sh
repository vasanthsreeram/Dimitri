#!/usr/bin/env bash
# OpenFold3-MLX setup for Dimitri Studio.
# Usage: openfold3.sh <repo-dir> <cache-dir>
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
CACHE="${2:?cache dir required}"

mkdir -p "$(dirname "$REPO")"
if [ ! -d "$REPO/.git" ]; then
  echo "Cloning OpenFold3-MLX into $REPO"
  git clone https://github.com/latent-spacecraft/openfold-3-mlx.git "$REPO"
fi

cd "$REPO"
if [ ! -x .venv/bin/python ]; then
  echo "Creating Python 3.12 environment"
  uv venv --python 3.12 .venv
fi

echo "Installing OpenFold3-MLX (PyTorch + MLX; first run is large)"
uv pip install --python .venv/bin/python -e .

mkdir -p "$CACHE"
if [ ! -f "$CACHE/ckpt_root" ]; then
  echo "Downloading OpenFold3 parameters into $CACHE"
  export PATH="$PWD/.venv/bin:$PATH"
  bash openfold3/scripts/download_openfold3_params.sh --download_dir="$CACHE"
  printf '%s' "$CACHE" > "$CACHE/ckpt_root"
fi

echo "OpenFold3-MLX setup complete"
