"""Structure export and conversion (CIF, PDB, JSON)."""

from __future__ import annotations

import io
import warnings
from dataclasses import dataclass

from Bio.PDB import MMCIFIO, MMCIFParser, PDBIO, PDBParser
from Bio.PDB.PDBExceptions import PDBConstructionWarning


class StructureError(RuntimeError):
    pass


@dataclass(frozen=True)
class StructureStats:
    atoms: int
    residues: int
    chains: int


def _parse_pdb(pdb_text: str):
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", PDBConstructionWarning)
        return PDBParser(QUIET=True).get_structure("dimitri", io.StringIO(pdb_text))


def pdb_to_cif(pdb_text: str) -> str:
    structure = _parse_pdb(pdb_text)
    out = io.StringIO()
    writer = MMCIFIO()
    writer.set_structure(structure)
    writer.save(out)  # type: ignore[arg-type]
    text = out.getvalue()
    if "_atom_site." not in text:
        raise StructureError("CIF conversion produced no atom records")
    return text


def cif_to_pdb(cif_text: str) -> str:
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", PDBConstructionWarning)
        structure = MMCIFParser(QUIET=True).get_structure(
            "dimitri", io.StringIO(cif_text)
        )
    out = io.StringIO()
    io_writer = PDBIO()
    io_writer.set_structure(structure)
    io_writer.save(out)  # type: ignore[arg-type]
    text = out.getvalue()
    if "ATOM" not in text and "HETATM" not in text:
        raise StructureError("PDB conversion produced no atom records")
    return text


def structure_stats(pdb_text: str) -> StructureStats:
    atoms = residues = 0
    chains: set[str] = set()
    seen: set[tuple[str, str, str]] = set()
    for line in pdb_text.splitlines():
        if not line.startswith(("ATOM", "HETATM")):
            continue
        atoms += 1
        chain = line[21].strip() or "A"
        resseq = line[22:26].strip()
        icode = line[26].strip()
        chains.add(chain)
        key = (chain, resseq, icode)
        if key not in seen:
            seen.add(key)
            residues += 1
    return StructureStats(atoms=atoms, residues=residues, chains=max(1, len(chains)))


def ensure_exports(
    pdb_text: str | None, cif_text: str | None
) -> tuple[str, str, StructureStats]:
    """Return a valid ``(pdb, cif, stats)`` triple from either representation."""
    if pdb_text is None and cif_text is None:
        raise StructureError("runner returned no structure")
    if pdb_text is None:
        assert cif_text is not None
        pdb_text = cif_to_pdb(cif_text)
    if cif_text is None:
        cif_text = pdb_to_cif(pdb_text)
    return pdb_text, cif_text, structure_stats(pdb_text)
