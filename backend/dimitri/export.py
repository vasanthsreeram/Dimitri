"""Structure parsing, conversion and comparison (PDB, mmCIF, JSON).

gemmi does the parsing and writing. Reading a PDB file with gemmi and calling
``setup_entities`` gives every chain an entity, a polymer type and label
sequence numbers, so the mmCIF it writes carries ``_entity``,
``_entity_poly`` and ``_struct_asym``. Phase 1 converted with Biopython's
MMCIFIO, which writes ``label_entity_id ?`` and no entity categories; Mol*
then could not tell a chain was a polymer and drew loose atoms instead of a
cartoon.

Runners return either PDB or mmCIF. The store keeps that native text as the
file the viewer loads and writes the other format with gemmi for export.
"""

from __future__ import annotations

import shlex
from dataclasses import dataclass, field
from typing import Literal

import gemmi

StructureFormat = Literal["pdb", "mmcif"]

_PDB_RECORDS = (
    "ATOM",
    "HETATM",
    "HEADER",
    "TITLE",
    "COMPND",
    "SOURCE",
    "REMARK",
    "CRYST1",
    "MODEL",
    "EXPDTA",
    "SEQRES",
    "HELIX",
    "SHEET",
    "AUTHOR",
    "KEYWDS",
)

_POLYMER_KIND = {
    gemmi.PolymerType.PeptideL: "protein",
    gemmi.PolymerType.PeptideD: "protein",
    gemmi.PolymerType.Rna: "rna",
    gemmi.PolymerType.Dna: "dna",
    gemmi.PolymerType.DnaRnaHybrid: "dna/rna",
}


class StructureError(RuntimeError):
    pass


@dataclass(frozen=True)
class StructureStats:
    atoms: int
    residues: int
    chains: int
    models: int = 1
    polymer_types: tuple[str, ...] = field(default_factory=tuple)


@dataclass(frozen=True)
class Superposition:
    rmsd: float
    aligned: int
    atoms: str
    per_residue_distance: list[float | None]
    moved_text: str
    moved_format: StructureFormat


# ----------------------------------------------------------------- reading


def detect_format(text: str) -> StructureFormat:
    """Tell PDB from mmCIF by the first meaningful line."""
    for line in text.splitlines()[:400]:
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if stripped.startswith(("data_", "loop_", "_atom_site.")):
            return "mmcif"
        if stripped.startswith(_PDB_RECORDS):
            return "pdb"
    return "mmcif" if "_atom_site." in text else "pdb"


def read_structure(text: str, fmt: str | None = None) -> gemmi.Structure:
    """Parse PDB or mmCIF text and set up entities and label numbering."""
    kind = _normalize_format(fmt) if fmt else detect_format(text)
    try:
        if kind == "mmcif":
            document = gemmi.cif.read_string(text)
            if len(document) == 0:
                raise StructureError("the mmCIF file has no data block")
            structure = gemmi.make_structure_from_block(document[0])
        else:
            structure = gemmi.read_pdb_string(text)
    except (RuntimeError, ValueError, IndexError) as exc:
        raise StructureError(f"Could not read the {kind.upper()} structure: {exc}") from exc
    structure.remove_empty_chains()
    if len(structure) == 0 or structure[0].count_atom_sites() == 0:
        raise StructureError("the structure has no atoms")
    structure.setup_entities()
    _tidy_generated_ids(structure)
    try:
        structure.assign_label_seq_id(False)
    except RuntimeError:
        pass  # numbering stays as read; viewers fall back to auth numbering
    return structure


def _normalize_format(fmt: str) -> StructureFormat:
    value = fmt.lower().lstrip(".")
    if value in ("cif", "mmcif", "pdbx"):
        return "mmcif"
    if value in ("pdb", "ent"):
        return "pdb"
    raise StructureError(f"Unknown structure format: {fmt}")


def _tidy_generated_ids(structure: gemmi.Structure) -> None:
    """Replace gemmi's generated subchain names ("Axp", "Ax1") and letter
    entity ids with conventional ones ("A", "1").

    Only applies when every subchain name was generated, which is the case for
    PDB input; label_asym_id values from an mmCIF file are kept as they are.
    """
    first = structure[0]
    order: list[tuple[str, str]] = []  # (subchain, chain name)
    for chain in first:
        for residue in chain:
            if residue.subchain and (not order or order[-1][0] != residue.subchain):
                if residue.subchain not in {name for name, _ in order}:
                    order.append((residue.subchain, chain.name))
    if not order or not all(name.startswith(chain + "x") for name, chain in order):
        return

    mapping: dict[str, str] = {}
    taken: set[str] = set()
    for name, chain in order:
        if name == f"{chain}xp" and chain not in taken:
            mapping[name] = chain
            taken.add(chain)
    spare = (_label(i) for i in range(10_000))
    for name, _ in order:
        if name in mapping:
            continue
        candidate = next(spare)
        while candidate in taken:
            candidate = next(spare)
        mapping[name] = candidate
        taken.add(candidate)

    entity_ids: dict[str, str] = {}
    for index, entity in enumerate(structure.entities, start=1):
        entity_ids[entity.name] = str(index)
        entity.subchains = [mapping.get(sub, sub) for sub in entity.subchains]
        entity.name = str(index)
    subchain_entity = {
        sub: entity.name for entity in structure.entities for sub in entity.subchains
    }
    for model in structure:
        for chain in model:
            for residue in chain:
                residue.subchain = mapping.get(residue.subchain, residue.subchain)
                residue.entity_id = subchain_entity.get(
                    residue.subchain, entity_ids.get(residue.entity_id, residue.entity_id)
                )


def _label(index: int) -> str:
    letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    label = ""
    index += 1
    while index:
        index, rest = divmod(index - 1, 26)
        label = letters[rest] + label
    return label


# ----------------------------------------------------------------- writing


def to_mmcif(structure: gemmi.Structure) -> str:
    text = structure.make_mmcif_document().as_string()
    if "_atom_site." not in text:
        raise StructureError("CIF conversion produced no atom records")
    return text


def to_pdb(structure: gemmi.Structure) -> str:
    copy = structure.clone()
    if any(len(chain.name) > 1 for chain in copy[0]):
        copy.shorten_chain_names()
    text = copy.make_pdb_string()
    if "ATOM" not in text and "HETATM" not in text:
        raise StructureError("PDB conversion produced no atom records")
    return text


def pdb_to_cif(pdb_text: str) -> str:
    return to_mmcif(read_structure(pdb_text, "pdb"))


def cif_to_pdb(cif_text: str) -> str:
    try:
        return to_pdb(read_structure(cif_text, "mmcif"))
    except StructureError:
        # Some model CIFs (non-standard residues, missing auth fields) defeat
        # the full reader. Fall back to reading the _atom_site loop directly.
        return _cif_atom_site_to_pdb(cif_text)


# ---------------------------------------------------------------- analysis


def stats_for(structure: gemmi.Structure) -> StructureStats:
    model = structure[0]
    residues = sum(len(chain) for chain in model)
    kinds: list[str] = []
    for entity in structure.entities:
        if entity.entity_type == gemmi.EntityType.Polymer:
            kind = _POLYMER_KIND.get(entity.polymer_type)
            if kind and kind not in kinds:
                kinds.append(kind)
    return StructureStats(
        atoms=model.count_atom_sites(),
        residues=residues,
        chains=max(1, len(model)),
        models=len(structure),
        polymer_types=tuple(kinds),
    )


def structure_stats(text: str, fmt: str | None = None) -> StructureStats:
    return stats_for(read_structure(text, fmt))


def residue_bfactors(structure: gemmi.Structure) -> list[float]:
    """Mean B-factor per polymer residue of the first model, in file order."""
    values: list[float] = []
    for chain in structure[0]:
        for residue in chain:
            if residue.entity_type != gemmi.EntityType.Polymer or len(residue) == 0:
                continue
            values.append(round(sum(atom.b_iso for atom in residue) / len(residue), 2))
    return values


def bfactors_are_confidence(structure: gemmi.Structure, text: str = "") -> bool:
    """Best guess whether B-factors hold pLDDT rather than experimental B values.

    Predicted models (AlphaFold, ColabFold, RhoFold, Dimitri runners) store
    pLDDT in the B-factor column and carry no experimental method. Experimental
    entries record one, and NMR models usually have all-zero B-factors.
    """
    if "_ma_qa_metric" in text:
        return True
    if any(getattr(item, "method", "") for item in structure.meta.experiments):
        return False
    if "\nEXPDTA" in text or text.startswith("EXPDTA") or "_exptl.method" in text:
        return False
    values = [
        atom.b_iso for chain in structure[0] for residue in chain for atom in residue
    ]
    if not values:
        return False
    low, high = min(values), max(values)
    return high > 0 and high <= 100 and high - low > 1e-6


def plddt_scale(values: list[float]) -> list[float]:
    """pLDDT on a 0–100 scale; some models write 0–1."""
    if values and max(values) <= 1.0:
        return [round(value * 100, 2) for value in values]
    return values


def superpose(
    reference_text: str,
    reference_format: str,
    moving_text: str,
    moving_format: str,
) -> Superposition:
    """Superpose the first polymer of ``moving`` onto ``reference``.

    Uses gemmi's sequence alignment plus Kabsch fit on Cα (proteins) or P
    (nucleic acids). Returns the RMSD, the per-residue distance after the fit,
    and the moved structure in its own format so the viewer can overlay both.
    """
    reference = read_structure(reference_text, reference_format)
    moving = read_structure(moving_text, moving_format)
    ref_polymer, ref_chain = _first_polymer(reference)
    mov_polymer, _ = _first_polymer(moving)
    polymer_type = ref_polymer.check_polymer_type()
    selection = gemmi.SupSelect.CaP
    result = gemmi.calculate_superposition(
        ref_polymer, mov_polymer, polymer_type, selection
    )
    moving[0].transform_pos_and_adp(result.transform)
    moved_polymer, _ = _first_polymer(moving)

    atoms = "CA" if polymer_type in (gemmi.PolymerType.PeptideL, gemmi.PolymerType.PeptideD) else "P"
    distances: list[float | None] = []
    for index, residue in enumerate(ref_polymer):
        if index >= len(moved_polymer):
            distances.append(None)
            continue
        a = _representative_atom(residue, atoms)
        b = _representative_atom(moved_polymer[index], atoms)
        distances.append(round(a.pos.dist(b.pos), 3) if a and b else None)

    fmt = _normalize_format(moving_format)
    moved_text = to_pdb(moving) if fmt == "pdb" else to_mmcif(moving)
    return Superposition(
        rmsd=round(result.rmsd, 3),
        aligned=int(result.count),
        atoms=atoms,
        per_residue_distance=distances,
        moved_text=moved_text,
        moved_format=fmt,
    )


def _first_polymer(structure: gemmi.Structure):
    for chain in structure[0]:
        polymer = chain.get_polymer()
        if len(polymer) > 0:
            return polymer, chain
    raise StructureError("no polymer chain to superpose")


def _representative_atom(residue, name: str):
    for candidate in (name, "C4'", "CA", "P"):
        atom = residue.find_atom(candidate, "*")
        if atom is not None:
            return atom
    return None


def ensure_exports(
    pdb_text: str | None, cif_text: str | None
) -> tuple[str, str, StructureStats]:
    """Return a valid ``(pdb, cif, stats)`` triple from either representation.

    The text a runner returned is kept byte for byte; only the missing format
    is written with gemmi.
    """
    if pdb_text is None and cif_text is None:
        raise StructureError("runner returned no structure")
    if cif_text is not None:
        try:
            structure = read_structure(cif_text, "mmcif")
            if pdb_text is None:
                pdb_text = to_pdb(structure)
        except (StructureError, RuntimeError):
            if pdb_text is None:
                pdb_text = _cif_atom_site_to_pdb(cif_text)
            structure = read_structure(pdb_text, "pdb")
    else:
        assert pdb_text is not None
        structure = read_structure(pdb_text, "pdb")
        cif_text = to_mmcif(structure)
    return pdb_text, cif_text, stats_for(structure)


# ------------------------------------------------------- last-resort reader


def _cif_atom_site_to_pdb(cif_text: str) -> str:
    """Write PDB ATOM records straight from an mmCIF ``_atom_site`` loop."""
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
