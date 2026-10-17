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


def test_rhofold_ready_requires_checkpoint(tmp_path: Path) -> None:
    repo = tmp_path / "rhofold"
    (repo / ".venv" / "bin").mkdir(parents=True)
    (repo / "rhofold").mkdir(parents=True)
    (repo / "inference.py").write_text("")
    (repo / ".venv" / "bin" / "python").write_text("")
    (repo / "pretrained").mkdir()
    settings = Settings(home=str(tmp_path / "h"))
    settings.rhofold_repo = str(repo)
    runner = RhoFoldRunner(settings)
    assert runner.status(settings).installed
    assert runner.status(settings).ready is False
    (repo / "pretrained" / "rhofold_pretrained_params.pt").write_bytes(b"0" * 1_100_000)
    assert runner.status(settings).ready


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
    repo = tmp_path / "rhofold"
    (repo / "rhofold").mkdir(parents=True)
    (repo / "inference.py").write_text("")
    (repo / ".venv" / "bin").mkdir(parents=True)
    (repo / ".venv" / "bin" / "python").write_text("")
    (repo / "pretrained").mkdir()
    (repo / "pretrained" / "rhofold_pretrained_params.pt").write_bytes(b"0" * 1_100_000)
    settings.rhofold_repo = str(repo)
    runner = RhoFoldRunner(settings)

    with pytest.raises(RunnerError, match="RNA bases"):
        runner.run(
            request("rna", "MKT"),
            tmp_path / "work",
            settings,
            lambda *args: None,
            _Control(),
        )


class _Control:
    cancelled = False

    def cancel(self) -> None:
        pass


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


def test_openfold3_collect_outputs_picks_best_sample(tmp_path: Path) -> None:
    out = tmp_path / "out"
    for sample, score in ((0, 70.0), (1, 88.0)):
        directory = out / "query" / "seed_7" / f"query_seed_7_sample_{sample}"
        directory.mkdir(parents=True)
        (directory / f"query_seed_7_sample_{sample}_model.cif").write_text(
            f"data_sample_{sample}\n"
        )
        (directory / f"query_seed_7_sample_{sample}_confidences_aggregated.json").write_text(
            '{"avg_plddt": %s, "ptm": 0.8, "plddt": [%s, %s]}'
            % (score, score, score)
        )
    runner = OpenFold3Runner(Settings())
    result = runner._collect_outputs(
        out, PredictionRequest(model_id="openfold3", entity_type="protein", sequence="MK")
    )
    assert result.cif_text == "data_sample_1\n"
    assert result.metrics["plddt"] == 88.0
    assert result.per_residue_plddt == [88.0, 88.0]
