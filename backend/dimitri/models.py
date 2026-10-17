"""API schemas shared by the FastAPI routes and the job engine."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Literal

from pydantic import BaseModel, Field, field_validator

EntityType = Literal["protein", "rna", "dna", "ligand"]
JobStatus = Literal["queued", "running", "completed", "failed", "cancelled"]
JobKind = Literal["predict", "install"]


class PredictionRequest(BaseModel):
    model_id: str
    entity_type: EntityType = "protein"
    sequence: str = Field(min_length=1, max_length=8_000)
    name: str = "Untitled fold"
    seed: int = 42
    samples: int = Field(default=5, ge=1, le=20)

    @field_validator("sequence")
    @classmethod
    def normalize_sequence(cls, value: str, info) -> str:
        cleaned = "".join(value.split())
        if not cleaned:
            raise ValueError("sequence must not be empty")
        # SMILES is case-sensitive; only sequence entities are uppercased.
        if info.data.get("entity_type") == "ligand":
            return cleaned
        return cleaned.upper()

    @field_validator("name")
    @classmethod
    def default_name(cls, value: str) -> str:
        return (value or "Untitled fold").strip()[:120]


class Stage(BaseModel):
    id: str
    name: str
    status: Literal["pending", "running", "done", "failed", "skipped"] = "pending"
    progress: float = 0.0
    message: str | None = None


class Metrics(BaseModel):
    plddt: float | None = None
    ptm: float | None = None
    iptm: float | None = None


class JobResult(BaseModel):
    model_id: str
    model_name: str
    metrics: Metrics
    per_residue_plddt: list[float] = Field(default_factory=list)
    pae: list[list[float]] | None = None
    pae_note: str | None = None
    residues: int = 0
    atoms: int = 0
    chains: int = 1
    format: Literal["cif", "pdb"] = "cif"
    device: str | None = None
    duration_s: float | None = None
    version: str = "0.1.0"
    note: str | None = None
    extra: dict[str, Any] = Field(default_factory=dict)


class Job(BaseModel):
    id: str
    kind: JobKind = "predict"
    name: str
    model_id: str
    entity_type: EntityType = "protein"
    sequence: str = ""
    seed: int = 42
    samples: int = 5
    status: JobStatus = "queued"
    progress: float = 0.0
    current_stage: str | None = None
    stages: list[Stage] = Field(default_factory=list)
    created_at: float
    started_at: float | None = None
    finished_at: float | None = None
    error: str | None = None
    hint: str | None = None
    result: JobResult | None = None
    log_tail: list[str] = Field(default_factory=list)


class CreateJobResponse(BaseModel):
    job: Job


class RunnerManifestModel(BaseModel):
    id: str
    name: str
    short_name: str
    version: str
    description: str
    entity_types: list[str]
    source_url: str
    runtime: str
    device: str
    fallback: str | None = None
    citation: str | None = None
    license: str | None = None
    weight_note: str | None = None
    weight_request_url: str | None = None
    weight_dir: str | None = None
    requires_weights: bool = True
    setup_hint: str | None = None
    stages: list[Stage] = Field(default_factory=list)
    visible: bool = True


class RunnerStatusModel(BaseModel):
    id: str
    installed: bool
    ready: bool
    weights_present: bool
    detail: str
    paths: dict[str, str] = Field(default_factory=dict)


class CatalogEntry(BaseModel):
    id: str
    name: str
    runner_id: str | None = None
    provider: str | None = None
    description: str
    tags: list[str] = Field(default_factory=list)
    license: str | None = None
    openness: int | None = None
    source: str = "local"
    source_url: str | None = None
    entity_types: list[str] = Field(default_factory=list)
    runtime: str | None = None
    device: str | None = None
    fallback: str | None = None
    installed: bool = False
    ready: bool = False
    installable: bool = True
    size_bytes: int = 0
    weight_note: str | None = None
    weight_request_url: str | None = None
    weight_dir: str | None = None


class CatalogResponse(BaseModel):
    entries: list[CatalogEntry]
    sources: dict[str, Any] = Field(default_factory=dict)


class DiskUsage(BaseModel):
    path: str
    bytes: int
    exists: bool


class LmStudioStatus(BaseModel):
    reachable: bool
    base_url: str
    models: list[str] = Field(default_factory=list)
    detail: str = ""


class StatusResponse(BaseModel):
    status: str
    version: str
    python: str
    platform: str
    backend_url: str
    storage: list[DiskUsage]
    lm_studio: LmStudioStatus
    runners: list[RunnerStatusModel]
    active_jobs: int
    bio_rodeo: dict[str, Any] = Field(default_factory=dict)


@dataclass
class InstallResult:
    """Outcome of a runner install, with optional guidance for manual steps."""

    message: str
    hint: str | None = None


@dataclass
class RunResult:
    """What a runner returns before the store normalizes exports."""

    pdb_text: str | None = None
    cif_text: str | None = None
    metrics: dict[str, float | None] = field(default_factory=dict)
    per_residue_plddt: list[float] = field(default_factory=list)
    pae: list[list[float]] | None = None
    pae_note: str | None = None
    note: str | None = None
    device: str | None = None
    extra: dict[str, Any] = field(default_factory=dict)
