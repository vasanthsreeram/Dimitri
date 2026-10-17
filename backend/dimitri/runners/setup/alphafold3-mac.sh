#!/usr/bin/env bash
# AlphaFold 3 for Dimitri Studio: alphafold3-mac (MLX) run through mac-af3.
# Usage: alphafold3-mac.sh <alphafold3-mac dir> <mac-af3 dir> <weights dir>
#
#   1. Checks: Apple Silicon, Xcode Command Line Tools, git, uv.
#   2. mac-af3 (github.com/vasanthsreeram/mac-af3, a private repository): cloned
#      with your own GitHub access (gh if it is signed in, else git), or updated.
#   3. alphafold3-mac (github.com/omrikais/alphafold3-mac) at the commit mac-af3
#      pins (3d1ce7b), its uv environment and the alphafold3.cpp C++ extension.
#   4. The chemical-components (CCD) pickles.
#   5. Verifies the imports and the MLX version (0.30.6).
#   6. Weights: your own af3.bin.zst, checked against mac-af3's pinned SHA-256.
#      Never downloaded or copied anywhere by Dimitri.
#   7. mac-af3's local weight shards (streaming.py convert), used for layer
#      streaming on 16 GB Macs. A local cache of your own weights; never shared.
#
# Skips HMMER, the genetic databases and the alphafold3-mac web UI: Dimitri
# runs AlphaFold 3 in single-sequence mode on this Mac. Safe to re-run.
set -euo pipefail

AF3_DIR="${1:?alphafold3-mac directory required}"
MAC_AF3_DIR="${2:?mac-af3 directory required}"
WEIGHTS_DIR="${3:?weights directory required}"
AF3_REPO_URL="https://github.com/omrikais/alphafold3-mac"
MAC_AF3_REPO="vasanthsreeram/mac-af3"
AF3_COMMIT="3d1ce7b"
AF3_MLX_EXPECTED="0.30.6"
WEIGHTS_SHA256="74d0258616917cd122f5eab6d076afe4a8930e96823851e65e4f777dfb1f33ff"
TOTAL=7

step() { printf '[af3-setup] [%s/%s] %s\n' "$1" "$TOTAL" "$2"; }
log()  { printf '[af3-setup] %s\n' "$*"; }
die()  { printf '[af3-setup] ERROR: %s\n' "$*" >&2; exit 1; }

unset VIRTUAL_ENV UV_PROJECT_ENVIRONMENT CONDA_PREFIX PYTHONPATH || true
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
export GIT_TERMINAL_PROMPT=0

# ---------------------------------------------------------------- 1. checks
step 1 "Checking this Mac"
[ "$(uname -s)" = Darwin ] || die "macOS is required."
[ "$(uname -m)" = arm64 ] || die "Apple Silicon (arm64) is required; a Rosetta shell will not work."
xcode-select -p >/dev/null 2>&1 || die "Xcode Command Line Tools are missing. Install them with: xcode-select --install"
command -v git >/dev/null || die "git not found. Install the Xcode Command Line Tools: xcode-select --install"
command -v clang++ >/dev/null || die "clang++ not found. Install the Xcode Command Line Tools: xcode-select --install"
command -v uv >/dev/null || die "uv not found (https://docs.astral.sh/uv/)."

# ---------------------------------------------------------------- 2. mac-af3
step 2 "mac-af3 runtime ($MAC_AF3_REPO)"
if [ -d "$MAC_AF3_DIR/.git" ]; then
  git -C "$MAC_AF3_DIR" pull --ff-only --quiet 2>/dev/null \
    && log "mac-af3 updated" \
    || log "mac-af3: could not update (offline or local changes); using the current checkout"
elif [ -e "$MAC_AF3_DIR" ]; then
  die "$MAC_AF3_DIR exists but is not a git checkout of mac-af3. Move it aside or set the mac-af3 path in Settings."
else
  mkdir -p "$(dirname "$MAC_AF3_DIR")"
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    gh repo clone "$MAC_AF3_REPO" "$MAC_AF3_DIR" -- --quiet \
      || die "Could not clone $MAC_AF3_REPO with gh. It is a private repository: ask its owner for access."
  else
    git clone --quiet "https://github.com/$MAC_AF3_REPO.git" "$MAC_AF3_DIR" \
      || die "Could not clone $MAC_AF3_REPO. It is a private repository: you need access and GitHub credentials (sign in with 'gh auth login'), or clone it yourself and point Settings at it."
  fi
  log "cloned mac-af3 into $MAC_AF3_DIR"
fi
[ -f "$MAC_AF3_DIR/core/scripts/mac_af3_patches.py" ] && [ -f "$MAC_AF3_DIR/tracks/weight-streaming/src/streaming.py" ] \
  || die "$MAC_AF3_DIR does not look like mac-af3 (core/scripts/mac_af3_patches.py missing)."

# ---------------------------------------------------------------- 3. alphafold3-mac
step 3 "alphafold3-mac at $AF3_COMMIT (first install compiles a C++ extension for a few minutes)"
if [ -d "$AF3_DIR/.git" ]; then
  if ! git -C "$AF3_DIR" cat-file -e "${AF3_COMMIT}^{commit}" 2>/dev/null; then
    git -C "$AF3_DIR" fetch --quiet origin
  fi
  head="$(git -C "$AF3_DIR" rev-parse HEAD)"
  want="$(git -C "$AF3_DIR" rev-parse "${AF3_COMMIT}^{commit}")"
  if [ "$head" != "$want" ]; then
    [ -z "$(git -C "$AF3_DIR" status --porcelain --untracked-files=no)" ] \
      || die "$AF3_DIR has local changes to tracked files; refusing to switch to $AF3_COMMIT."
    git -C "$AF3_DIR" -c advice.detachedHead=false checkout --quiet "$want"
  fi
elif [ -e "$AF3_DIR" ]; then
  die "$AF3_DIR exists but is not a git checkout; move it aside first."
else
  mkdir -p "$(dirname "$AF3_DIR")"
  git clone --quiet "$AF3_REPO_URL" "$AF3_DIR"
  git -C "$AF3_DIR" -c advice.detachedHead=false checkout --quiet "$AF3_COMMIT"
fi
cd "$AF3_DIR"
find src/ -name '._*' -delete 2>/dev/null || true
if ! .venv/bin/python3 -c 'import sys, platform; sys.exit(0 if sys.version_info[:2] >= (3, 12) and platform.machine() == "arm64" else 1)' 2>/dev/null; then
  rm -rf .venv
  uv venv --quiet --python 3.12 --python-preference only-managed .venv
fi
log "Installing Python dependencies and building alphafold3.cpp"
uv sync --frozen --no-dev --compile-bytecode

# ---------------------------------------------------------------- 4. CCD
step 4 "Chemical components dictionary"
read -r CCD_PKL SETS_PKL < <(PYTHONPATH=src .venv/bin/python -c '
from alphafold3.build_data import _pickle_paths
a, b = _pickle_paths(); print(a, b)')
if [ -s "$CCD_PKL" ] && [ -s "$SETS_PKL" ]; then
  log "already built"
else
  PYTHONPATH=src .venv/bin/python -c 'from alphafold3.build_data import build_data; build_data()'
fi

# ---------------------------------------------------------------- 5. verify
step 5 "Verifying the runtime"
.venv/bin/python -m compileall -q -j 0 src >/dev/null 2>&1 || true
PYTHONPATH="src:$MAC_AF3_DIR/core/scripts:$MAC_AF3_DIR/tracks/weight-streaming/src" \
PYTHONPYCACHEPREFIX="${PYTHONPYCACHEPREFIX:-$HOME/.dimitri/cache/pycache}" \
.venv/bin/python - "$AF3_MLX_EXPECTED" <<'PY'
import sys
import mlx.core as mx
from alphafold3 import cpp  # noqa: F401  C++ extension
from alphafold3.build_data import _pickle_paths
from alphafold3_mlx.pipeline.runner import InferenceRunner  # noqa: F401
import mac_af3_patches, streaming, lean  # noqa: F401,E401
if mx.__version__ != sys.argv[1]:
    print(f"[af3-setup] note: MLX {mx.__version__}, mac-af3 was measured with {sys.argv[1]}")
for path in _pickle_paths():
    assert path.exists() and path.stat().st_size > 0, path
print(f"[af3-setup] runtime ok: MLX {mx.__version__}")
PY

# ---------------------------------------------------------------- 6. weights
step 6 "AlphaFold 3 weights (your own copy)"
WEIGHTS="$WEIGHTS_DIR/af3.bin.zst"
if [ ! -f "$WEIGHTS" ]; then
  log "NOTE: no weights at $WEIGHTS. AlphaFold 3 needs your own copy of the official parameters (af3.bin.zst, obtained from Google DeepMind under their terms). Put the file there and run setup again."
  log "alphafold3-mac and mac-af3 are installed; the model is not ready until the weights are in place."
  exit 0
fi
got="$(.venv/bin/python -c 'import hashlib, sys
h = hashlib.sha256()
with open(sys.argv[1], "rb") as f:
    for c in iter(lambda: f.read(1 << 24), b""):
        h.update(c)
print(h.hexdigest())' "$WEIGHTS")"
[ "$got" = "$WEIGHTS_SHA256" ] || die "af3.bin.zst does not match the weights mac-af3 was built for (sha256 $got). Expected $WEIGHTS_SHA256."
log "weights checksum matches mac-af3's pinned file"

# ---------------------------------------------------------------- 7. shards
step 7 "mac-af3 weight shards for layer streaming"
if ls "$HOME/.alphafold3/shards/"*/manifest.json >/dev/null 2>&1; then
  log "shards already built"
else
  PYTHONPATH="src:$MAC_AF3_DIR/core/scripts:$MAC_AF3_DIR/tracks/weight-streaming/src" \
  PYTHONPYCACHEPREFIX="${PYTHONPYCACHEPREFIX:-$HOME/.dimitri/cache/pycache}" \
  .venv/bin/python "$MAC_AF3_DIR/tracks/weight-streaming/src/streaming.py" convert --model_dir "$WEIGHTS_DIR"
fi
log "AlphaFold 3 is ready"
