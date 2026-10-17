from __future__ import annotations

from dimitri.export import (
    StructureError,
    cif_to_pdb,
    ensure_exports,
    pdb_to_cif,
    structure_stats,
)

SAMPLE_PDB = """\
ATOM      1  N   ALA A   1      -0.677   0.000   0.000  1.00 95.00           N
ATOM      2  CA  ALA A   1       0.000   0.000   0.000  1.00 94.50           C
ATOM      3  C   ALA A   1       1.400   0.000   0.000  1.00 93.00           C
ATOM      4  N   GLY A   2       2.000   0.500   0.000  1.00 80.00           N
ATOM      5  CA  GLY A   2       3.300   0.500   0.000  1.00 79.00           C
ATOM      6  C   GLY A   2       4.000   1.000   0.000  1.00 78.00           C
END
"""


def test_pdb_to_cif_has_atom_site_loop() -> None:
    cif = pdb_to_cif(SAMPLE_PDB)
    assert "_atom_site" in cif
    assert cif.count("ALA") >= 1


def test_cif_to_pdb_round_trip() -> None:
    cif = pdb_to_cif(SAMPLE_PDB)
    pdb = cif_to_pdb(cif)
    assert "ATOM" in pdb
    assert "ALA" in pdb
    assert structure_stats(pdb).residues == 2


def test_structure_stats_counts_residues_and_chains() -> None:
    stats = structure_stats(SAMPLE_PDB)
    assert stats.atoms == 6
    assert stats.residues == 2
    assert stats.chains == 1


def test_ensure_exports_fills_missing_cif() -> None:
    pdb, cif, stats = ensure_exports(SAMPLE_PDB, None)
    assert "_atom_site" in cif
    assert stats.atoms == 6


def test_ensure_exports_rejects_empty() -> None:
    try:
        ensure_exports(None, None)
    except StructureError as exc:
        assert "no structure" in str(exc)
    else:
        raise AssertionError("expected StructureError")
