"""RhoFold+ inference adapter for Dimitri Studio.

Attribution
-----------
This script is Dimitri's own thin wrapper around the upstream RhoFold+ code
(https://github.com/ml4bio/RhoFold, Shen et al., Nature Methods 21:2287, 2024),
written after the measurement approach in Vas's rhofold-mlx bench script. It
imports upstream modules; it does not include model weights or a copy of the
upstream repository.

Only the RNA forward pass and PDB export are used: no BLASTN database search and
no Amber relaxation. ``RHOFOLD_FAST=1`` is set by the runner to enable the
vendored, algebraically equivalent speed patch (see ../vendor/rhofold/).
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True)
    parser.add_argument("--weights", required=True)
    parser.add_argument("--fasta", required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--device", default="mps")
    args = parser.parse_args()

    repo = Path(args.repo).resolve()
    sys.path.insert(0, str(repo))

    import numpy as np
    import torch
    from rhofold.config import rhofold_config
    from rhofold.rhofold import RhoFold
    from rhofold.utils.alphabet import get_features

    out_dir = Path(args.output_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    device = args.device
    if device == "mps" and not torch.backends.mps.is_available():
        device = "cpu"

    started = time.time()
    model = RhoFold(rhofold_config)
    state = torch.load(args.weights, map_location="cpu", weights_only=False)
    model.load_state_dict(state["model"])
    model.eval().to(device)

    data = get_features(args.fasta, args.fasta)  # single-sequence mode
    tokens = data["tokens"].to(device)
    rna_fm_tokens = data["rna_fm_tokens"].to(device)

    with torch.no_grad():
        outputs = model(tokens=tokens, rna_fm_tokens=rna_fm_tokens, seq=data["seq"])
        output = outputs[-1]
        xyz = output["cord_tns_pred"][-1].squeeze(0).float().cpu().numpy()
        plddt = output["plddt"][0].float().cpu().numpy()

    pdb_path = out_dir / "rhofold_model.pdb"
    model.structure_module.converter.export_pdb_file(
        data["seq"], xyz, path=str(pdb_path), chain_id=None, confidence=plddt
    )

    payload = {
        "device": device,
        "sequence": data["seq"],
        "residues": len(data["seq"]),
        "per_residue_plddt": [round(float(v), 2) for v in np.asarray(plddt).reshape(-1)],
        "plddt": round(float(np.mean(plddt)), 2),
        "ptm": None,
        "iptm": None,
        "seconds": round(time.time() - started, 2),
        "pdb": str(pdb_path),
    }
    (out_dir / "rhofold_metrics.json").write_text(json.dumps(payload, indent=2))
    print(json.dumps({k: v for k, v in payload.items() if k != "per_residue_plddt"}))
    return 0


if __name__ == "__main__":
    os.environ.setdefault("RHOFOLD_FAST", "1")
    raise SystemExit(main())
