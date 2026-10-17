# Vendored RhoFold assets and attribution

## `rhofold-mac-fast.patch`

- **Source:** Vas's `rhofold-mlx` reference project (read-only during this build), file `rhofold-mac-fast.patch`.
- **Upstream it patches:** [ml4bio/RhoFold](https://github.com/ml4bio/RhoFold) commit `6bdfbda` (2025-05-29), the RhoFold+ code from Shen et al., *Nature Methods* 21:2287 (2024).
- **SHA-256:** `6803c0d6b8b4b5bcd44e71e74ec44f8f4b43322e85b99e22d69b4f4c28571b4f`
- **What it does:** behind `RHOFOLD_FAST=1`, chunks the EGNN edge tensor so long RNA fits in MPS memory, and computes the first edge MLP layer as an algebraically equivalent per-node matmul. Unset, behaviour is upstream's. It also adds a `run_refine` switch.
- **License:** the patch is derived from Apache-2.0 upstream code; keep upstream's license with any copy.

## `run_rhofold.py`

Dimitri's own adapter. It imports the upstream package from a checkout made by
`runners/setup/rhofold.sh`; no upstream source is copied into this repository.
The forward pass and PDB export are upstream APIs. Model weights are downloaded by
the setup script from Hugging Face (`cuhkaih/rhofold`) and are never committed.
