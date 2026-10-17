#!/usr/bin/env bash
# RhoFold+ setup for Dimitri Studio.
# Usage: rhofold.sh <repo-dir> <patch-file>
# Clones upstream ml4bio/RhoFold, applies the vendored speed patch, creates a
# uv environment, and downloads the public checkpoint from Hugging Face.
set -euo pipefail

REPO="${1:?repo dir required}"
PATCH="${2:?patch file required}"

mkdir -p "$(dirname "$REPO")"
if [ ! -d "$REPO/.git" ]; then
  echo "Cloning RhoFold into $REPO"
  git clone https://github.com/ml4bio/RhoFold.git "$REPO"
fi

cd "$REPO"
if ! grep -q "RHOFOLD_FAST" rhofold/model/structure_module.py 2>/dev/null; then
  echo "Applying Dimitri's RhoFold speed patch"
  git apply "$PATCH"
fi

if [ ! -x .venv/bin/python ]; then
  echo "Creating Python 3.12 environment"
  uv venv --python 3.12 .venv
fi

echo "Installing RhoFold dependencies"
uv pip install --python .venv/bin/python \
  torch numpy einops ml-collections biopython huggingface_hub scipy matplotlib dm-tree

mkdir -p pretrained
if [ ! -f pretrained/rhofold_pretrained_params.pt ] && [ ! -f pretrained/RhoFold_pretrained.pt ]; then
  echo "Downloading checkpoint cuhkaih/rhofold (about 508 MB)"
  .venv/bin/python - <<'PY'
from huggingface_hub import hf_hub_download
path = hf_hub_download(
    repo_id="cuhkaih/rhofold",
    filename="rhofold_pretrained_params.pt",
    local_dir="pretrained",
)
print("checkpoint:", path)
PY
fi

echo "RhoFold setup complete"
