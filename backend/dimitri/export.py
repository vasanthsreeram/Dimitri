"""Structure export and conversion (CIF, PDB, JSON)."""

from __future__ import annotations

import io
import shlex
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
    try:
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
        if "ATOM" in text or "HETATM" in text:
            return text
    except Exception:
        pass
    # Some model CIFs (non-standard residues, missing auth fields) defeat the
    # full parser. Fall back to reading the _atom_site loop directly.
    return _cif_atom_site_to_pdb(cif_text)


def _cif_atom_site_to_pdb(cif_text: str) -> str:
    lines = cif_text.splitlines()
    headers: list[str] = []
    data_start = -1
    for index, line in enumerate(lines):
        stripped = line.strip()
        if stripped.startswith("_atom_site."):
            headers.append(stripped.split(".", 1)[1].strip())
        elif headers:
            if not stripped or stripped.startswith("#"):
                continue
            if stripped.startswith("_"):
                break
            data_start = index
            break
    if not headers or data_start < 0:
        raise StructureError("CIF contains no _atom_site loop")

    def column(*names: str) -> int | None:
        for name in names:
            if name in headers:
                return headers.index(name)
        return None

    group_col = column("group_PDB")
    atom_col = column("auth_atom_id", "label_atom_id")
    comp_col = column("auth_comp_id", "label_comp_id")
    chain_col = column("auth_asym_id", "label_asym_id")
    seq_col = column("auth_seq_id", "label_seq_id")
    x_col = column("Cartn_x")
    y_col = column("Cartn_y")
    z_col = column("Cartn_z")
    occ_col = column("occupancy")
    b_col = column("B_iso_or_equiv")
    element_col = column("type_symbol")
    insert_col = column("pdbx_PDB_ins_code")
    model_col = column("pdbx_PDB_model_num")
    if None in (atom_col, comp_col, x_col, y_col, z_col):
        raise StructureError("CIF _atom_site loop is missing required columns")

    tokens: list[str] = []
    lines_out: list[str] = []
    serial = 1
    first_model: str | None = None

    def emit(row: list[str]) -> None:
        nonlocal serial, first_model
        if model_col is not None and model_col < len(row):
            if first_model is None:
                first_model = row[model_col]
            elif row[model_col] != first_model:
                return
        nonlocal serial
        try:
            x = float(row[x_col])  # type: ignore[index]
            y = float(row[y_col])  # type: ignore[index]
            z = float(row[z_col])  # type: ignore[index]
        except (TypeError, ValueError, IndexError):
            return
        atom = row[atom_col]  # type: ignore[index]
        comp = row[comp_col]  # type: ignore[index]
        chain = (row[chain_col] if chain_col is not None else "A")[:1] or "A"
        try:
            resseq = int(float(row[seq_col])) if seq_col is not None else 1
        except (TypeError, ValueError, IndexError):
            resseq = 1
        element = (
            row[element_col]
            if element_col is not None and element_col < len(row)
            else atom[:1]
        )
        occupancy = "1.00"
        if occ_col is not None:
            try:
                occupancy = f"{float(row[occ_col]):.2f}"
            except (TypeError, ValueError, IndexError):
                pass
        bfactor = 0.0
        if b_col is not None:
            try:
                bfactor = float(row[b_col])
            except (TypeError, ValueError, IndexError):
                pass
        insert = ""
        if insert_col is not None and insert_col < len(row):
            candidate = row[insert_col]
            insert = candidate if candidate not in (".", "?", "") else ""
        record = (
            row[group_col]
            if group_col is not None and group_col < len(row)
            else "ATOM"
        )
        record = "HETATM" if record.upper().startswith("HETATM") else "ATOM  "
        name_field = f" {atom:<3}" if len(atom) <= 3 else atom[:4]
        lines_out.append(
            f"{record}{serial:5d} {name_field}{' '}{comp:>3} {chain}{resseq:4d}"
            f"{insert:1}{'   '}{x:8.3f}{y:8.3f}{z:8.3f}{occupancy:>6}{bfactor:6.2f}"
            f"          {element:>2}"
        )
        serial += 1

    for line in lines[data_start:]:
        stripped = line.strip()
        if not stripped:
            continue
        if stripped.startswith(("#", "_", "data_")):
            break
        tokens.extend(shlex.split(line, posix=True))
        while len(tokens) >= len(headers):
            emit(tokens[: len(headers)])
            del tokens[: len(headers)]

    if not lines_out:
        raise StructureError("CIF conversion produced no atom records")
    lines_out.append("END")
    return "\n".join(lines_out) + "\n"


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
