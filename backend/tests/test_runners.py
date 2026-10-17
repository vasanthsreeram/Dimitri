from __future__ import annotations

from pathlib import Path

import httpx
import pytest

from dimitri.config import Settings
from dimitri.models import PredictionRequest
from dimitri.runners import RunnerError, RunnerRegistry
from dimitri.runners.alphafold3_mac import AlphaFold3MacRunner
from dimitri.runners.openfold3 import OpenFold3Runner
from dimitri.runners.rhofold import RhoFoldRunner


def request(entity_type: str, sequence: str, name: str = "job") -> PredictionRequest:
    return PredictionRequest(
        model_id="alphafold3-mac",
        entity_type=entity_type,
        sequence=sequence,
        name=name,
        seed=7,
        samples=2,
    )


def test_registry_hides_demo_runner() -> None:
    registry = RunnerRegistry(Settings())
    assert "demo" not in {runner.manifest.id for runner in registry.all()}
    assert "demo" in {runner.manifest.id for runner in registry.all(include_hidden=True)}
    assert registry.get("demo").manifest.visible is False


def test_af3_input_payload_for_each_entity_type() -> None:
    runner = AlphaFold3MacRunner(Settings())
    protein = runner._input_payload(request("protein", "MKTAYIAK"))
    assert protein["dialect"] == "alphafold3"
    assert protein["version"] == 4
    assert protein["modelSeeds"] == [7]
    assert protein["sequences"][0]["protein"] == {"id": "A", "sequence": "MKTAYIAK"}

    rna = runner._input_payload(request("rna", "GGGAAACCC"))
    assert rna["sequences"][0]["rna"]["sequence"] == "GGGAAACCC"

    dna = runner._input_payload(request("dna", "GGGAAACCC"))
    assert dna["sequences"][0]["dna"]["sequence"] == "GGGAAACCC"
    assert "unpairedMsa" not in dna["sequences"][0]["dna"]

    ccd = runner._input_payload(request("ligand", "ATP"))
    assert ccd["sequences"][0]["ligand"]["ccdCodes"] == ["ATP"]

    smiles = runner._input_payload(request("ligand", "CC(=O)O"))
    assert smiles["sequences"][0]["ligand"]["smiles"] == "CC(=O)O"


def test_af3_validation_rejects_bad_residues() -> None:
    runner = AlphaFold3MacRunner(Settings())
    with pytest.raises(RunnerError, match="Invalid protein"):
        runner._validate("protein", "MKT*")
    with pytest.raises(RunnerError, match="Invalid RNA"):
        runner._validate("rna", "ACGT")
    runner._validate("dna", "ACGT")
    runner._validate("ligand", "CC(=O)O")


def test_af3_ready_requires_checkout_and_weights(tmp_path: Path) -> None:
    repo = tmp_path / "af3"
    weights = tmp_path / "weights"
    (repo / ".venv" / "bin").mkdir(parents=True)
    (repo / "run_alphafold_mlx.py").write_text("")
    (repo / ".venv" / "bin" / "python").write_text("")
    weights.mkdir()
    (weights / "af3.bin.zst").write_bytes(b"0" * 1_100_000)
    settings = Settings(home=str(tmp_path / "h"))
    settings.af3_repo = str(repo)
    settings.af3_weights_dir = str(weights)
    status = AlphaFold3MacRunner(settings).status(settings)
    assert status.installed and status.weights_present and status.ready


def make_rhofold_mac(root: Path, *, weights: bool = True) -> Path:
    """A fake rhofold-mac checkout with the files the runner checks."""
    repo = root / "rhofold-mac"
    (repo / ".venv" / "bin").mkdir(parents=True)
    (repo / ".venv" / "bin" / "python").write_text("")
    (repo / "RhoFold" / "rhofold").mkdir(parents=True)
    (repo / "RhoFold" / "pretrained").mkdir(parents=True)
    for name in ("setup.sh", "run.sh", "doctor.sh"):
        (repo / name).write_text("#!/bin/bash\n")
    if weights:
        (repo / "RhoFold" / "pretrained" / "RhoFold_pretrained.pt").write_bytes(b"0" * 1_100_000)
    return repo


def test_rhofold_ready_requires_rhofold_mac_and_weights(tmp_path: Path) -> None:
    repo = make_rhofold_mac(tmp_path, weights=False)
    settings = Settings(home=str(tmp_path / "h"))
    settings.rhofold_repo = str(repo)
    runner = RhoFoldRunner(settings)
    status = runner.status(settings)
    assert status.installed and not status.ready
    assert "Weights missing" in status.detail
    (repo / "RhoFold" / "pretrained" / "RhoFold_pretrained.pt").write_bytes(b"0" * 1_100_000)
    assert runner.status(settings).ready


def test_plain_upstream_checkout_is_not_rhofold_mac(tmp_path: Path) -> None:
    repo = tmp_path / "rhofold"
    (repo / "rhofold").mkdir(parents=True)
    (repo / "inference.py").write_text("")
    settings = Settings(home=str(tmp_path / "h"))
    settings.rhofold_repo = str(repo)
    status = RhoFoldRunner(settings).status(settings)
    assert not status.installed
    assert "rhofold-mac" in status.detail


def test_old_rhofold_default_path_migrates_to_rhofold_mac(tmp_path: Path) -> None:
    home = tmp_path / "h"
    home.mkdir()
    (home / "settings.json").write_text(
        '{"rhofold_repo": "%s"}' % (home / "models" / "rhofold")
    )
    settings = Settings.load(home)
    assert settings.rhofold_repo.endswith("models/rhofold-mac")


def test_openfold3_parameter_root_reads_ckpt_root(tmp_path: Path) -> None:
    cache = tmp_path / "of3"
    params = cache / "params"
    params.mkdir(parents=True)
    (cache / "ckpt_root").write_text(str(params))
    (params / "model.pt").write_bytes(b"0" * 11_000_000)
    settings = Settings(home=str(tmp_path / "h"))
    settings.openfold3_cache = str(cache)
    runner = OpenFold3Runner(settings)
    assert runner.parameter_root() == params
    assert runner.parameters_present()


def test_rhofold_rejects_non_rna(tmp_path: Path) -> None:
    settings = Settings(home=str(tmp_path / "h"))
    settings.rhofold_repo = str(make_rhofold_mac(tmp_path))
    runner = RhoFoldRunner(settings)
    with pytest.raises(RunnerError, match="Replace T with U"):
        runner.run(
            request("rna", "GGACUT"),
            tmp_path / "work",
            settings,
            lambda *args: None,
            _Control(),
        )


def test_rhofold_cold_path_reads_rhofold_mac_outputs(tmp_path: Path) -> None:
    """Without warm workers the runner calls rhofold-mac's own run.sh."""
    import numpy as np

    repo = make_rhofold_mac(tmp_path)
    # A stand-in run.sh that writes what rhofold-mac's predict.py writes,
    # including upstream's B-factors shifted by one residue.
    (repo / "run.sh").write_text(
        """#!/bin/bash
out="$2"; mkdir -p "$out"
echo "RhoFold+ | input.fasta | 3 nt | single-sequence | device=mps | fast=True"
cat > "$out/unrelaxed_model.pdb" <<PDB
ATOM      1  P     G 0   1       0.000   0.000   0.000  1.00 30.00           P
ATOM      2  P     G 0   2       5.900   0.000   0.000  1.00 90.00           P
ATOM      3  P     C 0   3      11.800   0.000   0.000  1.00 60.00           P
PDB
printf '3\n1\tG\t0\t2\t3\t1\n2\tG\t1\t3\t0\t2\n3\tC\t2\t4\t1\t3\n' > "$out/ss.ct"
echo '{"device": "mps", "model_load_s": 1.1, "predict_s": 2.2, "mean_plddt": 0.6}' > "$out/run_info.json"
echo "Model load 1.1 s | prediction 2.2 s | mean pLDDT 0.600"
"""
    )
    out = tmp_path / "work" / "rhofold-out"
    out.mkdir(parents=True)
    np.savez_compressed(out / "results.npz", plddt=np.array([[0.9, 0.6, 0.3]], dtype=np.float32))
    settings = Settings(home=str(tmp_path / "h"))
    settings.rhofold_repo = str(repo)
    settings.warm_workers = False
    events: list[tuple] = []
    result = RhoFoldRunner(settings).run(
        request("rna", "GGC"),
        tmp_path / "work",
        settings,
        lambda *args: events.append(args),
        _Control(),
    )
    assert result.per_residue_plddt == [90.0, 60.0, 30.0]
    assert result.metrics["plddt"] == 60.0
    # B-factors now carry each residue's own pLDDT.
    bfactors = [float(line[60:66]) for line in result.pdb_text.splitlines() if line.startswith("ATOM")]
    assert bfactors == [90.0, 60.0, 30.0]
    assert result.extra["dot_bracket"] == "(.)"
    assert result.timings["predict_s"] == 2.2
    assert result.warm is False
    assert any(stage == "fold" for stage, *_ in events)


def test_read_ct_dot_bracket_handles_pseudoknots(tmp_path: Path) -> None:
    from dimitri.runners.rhofold import read_ct_dot_bracket

    ct = tmp_path / "pk.ct"
    ct.write_text("6\n1 G 0 2 4 1\n2 G 1 3 5 2\n3 A 2 4 0 3\n4 C 3 5 1 4\n5 C 4 6 2 5\n6 A 5 0 0 6\n")
    assert read_ct_dot_bracket(ct) == "([.)]."


def _Control():
    from dimitri.runners.base import JobControl

    return JobControl()


def test_lm_studio_status_parses_models(monkeypatch) -> None:
    from dimitri import main

    def fake_get(url: str, timeout: float):
        return httpx.Response(
            200,
            json={"data": [{"id": "qwen3-8b"}, {"id": "llama-3.2"}]},
            request=httpx.Request("GET", url),
        )

    monkeypatch.setattr(main.httpx, "get", fake_get)
    status = main.lm_studio_status("http://localhost:1234/v1")
    assert status.reachable
    assert status.models == ["qwen3-8b", "llama-3.2"]


def test_af3_collect_outputs_prefers_ranked_files(tmp_path: Path) -> None:
    out = tmp_path / "out" / "job"
    sample = out / "seed-7_sample-0"
    sample.mkdir(parents=True)
    (sample / "job_seed-7_sample-0_model.cif").write_text("data_sample\n")
    (out / "job_seed-7_sample-0_confidences.json").write_text(
        '{"plddt": [10.0, 20.0], "pae": [[0.0, 1.0], [1.0, 0.0]]}'
    )
    (out / "job_model.cif").write_text("data_ranked\n")
    (out / "job_summary_confidences.json").write_text(
        '{"ptm": 0.91, "iptm": 0.77, "ranking_score": 0.9}'
    )
    (out / "job_confidences.json").write_text(
        '{"plddt": [80.0, 90.0], "atom_plddts": [80.0, 85.0, 90.0], '
        '"pae": [[0.0, 2.0], [2.0, 0.0]]}'
    )
    runner = AlphaFold3MacRunner(Settings())
    result = runner._collect_outputs(out, request("protein", "MK"))
    assert result.cif_text == "data_ranked\n"
    assert result.metrics["ptm"] == 0.91
    assert result.metrics["iptm"] == 0.77
    assert result.metrics["plddt"] == 85.0
    assert result.per_residue_plddt == [80.0, 90.0]
    assert len(result.pae or []) == 2


CIF_WITH_BFACTORS = """\
data_x
loop_
_atom_site.group_PDB
_atom_site.id
_atom_site.label_atom_id
_atom_site.label_comp_id
_atom_site.auth_asym_id
_atom_site.auth_seq_id
_atom_site.Cartn_x
_atom_site.Cartn_y
_atom_site.Cartn_z
_atom_site.B_iso_or_equiv
ATOM 1 N ALA A 1 0.0 0.0 0.0 80.0
ATOM 2 CA ALA A 1 1.0 0.0 0.0 90.0
ATOM 3 N GLY A 2 2.0 0.0 0.0 50.0
ATOM 4 CA GLY A 2 3.0 0.0 0.0 70.0
#
"""


def test_openfold3_collect_outputs_reads_full_confidence_and_cif(tmp_path: Path) -> None:
    out = tmp_path / "out"
    directory = out / "query" / "seed_7" / "query_seed_7_sample_1"
    directory.mkdir(parents=True)
    (directory / "query_seed_7_sample_1_model.cif").write_text(CIF_WITH_BFACTORS)
    (directory / "query_seed_7_sample_1_confidences_aggregated.json").write_text(
        '{"avg_plddt": 88.0, "ptm": 0.8, "iptm": 0.7}'
    )
    (directory / "query_seed_7_sample_1_confidences.json").write_text(
        '{"plddt": [80.0, 90.0, 50.0, 70.0], "pde": [[0.0]]}'
    )
    runner = OpenFold3Runner(Settings())
    result = runner._collect_outputs(
        out, PredictionRequest(model_id="openfold3", entity_type="protein", sequence="MK")
    )
    assert result.metrics["plddt"] == 88.0
    assert result.metrics["ptm"] == 0.8
    assert result.per_residue_plddt == [85.0, 60.0]
    assert result.pae is None
    assert result.device == "mps"


def test_af3_collect_outputs_reads_mlx_confidence_scores(tmp_path: Path) -> None:
    out = tmp_path / "out"
    out.mkdir()
    (out / "structure_rank_1.cif").write_text("data_rank1\n")
    (out / "structure_rank_2.cif").write_text("data_rank2\n")
    (out / "confidence_scores.json").write_text(
        '{"num_samples": 2, "ranking_metric": "plddt", "samples": {'
        '"0": {"plddt": [70.0, 75.0], "pae": [[0.0, 1.0], [1.0, 0.0]], '
        '"ptm": 0.7, "iptm": 0.6, "mean_plddt": 72.5, "rank": 2}, '
        '"1": {"plddt": [81.0, 91.0], "pae": [[0.0, 2.0], [2.0, 0.0]], '
        '"ptm": 0.9, "iptm": 0.8, "mean_plddt": 86.0, "rank": 1}}}'
    )
    runner = AlphaFold3MacRunner(Settings())
    result = runner._collect_outputs(out, request("protein", "MK"))
    assert result.cif_text == "data_rank1\n"
    assert result.metrics == {"plddt": 86.0, "ptm": 0.9, "iptm": 0.8}
    assert result.per_residue_plddt == [81.0, 91.0]
    assert result.device == "mlx"


def test_demo_pdb_handles_three_digit_coordinates() -> None:
    from dimitri.export import ensure_exports
    from dimitri.runners.demo import DemoRunner

    coords, plddt = DemoRunner._backbone("protein", 300, 7)
    pdb = DemoRunner._pdb("protein", 300, coords, plddt)
    parsed_pdb, cif, stats = ensure_exports(pdb, None)
    assert "Invalid or missing coordinate" not in parsed_pdb
    assert stats.atoms == 300
    assert "_atom_site" in cif
