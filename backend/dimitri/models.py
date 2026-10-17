"""API schemas shared by the FastAPI routes and the job engine."""

from __future__ import annotations

import hashlib
from dataclasses import dataclass, field
from typing import Any, Literal

from pydantic import BaseModel, Field, field_validator

EntityType = Literal["protein", "rna", "dna", "ligand"]
JobStatus = Literal["queued", "running", "completed", "failed", "cancelled"]
JobKind = Literal["predict", "install", "import"]


def sequence_key(entity_type: str, sequence: str) -> str:
    """Stable key for "same input": jobs that share it can be compared."""
    digest = hashlib.sha1(f"{entity_type}:{sequence}".encode()).hexdigest()
    return digest[:16]


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


class ImportRequest(BaseModel):
    """A structure file the user dropped into the app (PDB or mmCIF)."""

    filename: str = "structure.pdb"
    text: str = Field(min_length=1, max_length=60_000_000)
    name: str | None = None


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
    # The PAE matrix lives in confidence.json and is served by
    # /api/jobs/{id}/pae; job records only carry its size.
    pae: list[list[float]] | None = None
    pae_size: int = 0
    pae_note: str | None = None
    residues: int = 0
    atoms: int = 0
    chains: int = 1
    models: int = 1
    polymer_types: list[str] = Field(default_factory=list)
    # Native format of the structure as the model wrote it. The viewer loads
    # this file; the other format is converted for export.
    format: Literal["cif", "pdb"] = "cif"
    has_confidence: bool = True
    device: str | None = None
    duration_s: float | None = None
    warm: bool | None = None
    timings: dict[str, float] = Field(default_factory=dict)
    peak_memory_gb: float | None = None
    version: str = "0.2.0"
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

    def summary(self) -> "JobSummary":
        stage = next((s for s in self.stages if s.id == self.current_stage), None)
        result = self.result
        return JobSummary(
            id=self.id,
            kind=self.kind,
            name=self.name,
            model_id=self.model_id,
            entity_type=self.entity_type,
            length=len(self.sequence),
            sequence_key=sequence_key(self.entity_type, self.sequence)
            if self.sequence
            else "",
            seed=self.seed,
            samples=self.samples,
            status=self.status,
            progress=self.progress,
            current_stage=self.current_stage,
            stage_name=stage.name if stage else None,
            stage_message=stage.message if stage else None,
            created_at=self.created_at,
            started_at=self.started_at,
            finished_at=self.finished_at,
            error=(self.error or "").splitlines()[0][:300] if self.error else None,
            hint=self.hint,
            plddt=result.metrics.plddt if result else None,
            ptm=result.metrics.ptm if result else None,
            iptm=result.metrics.iptm if result else None,
            device=result.device if result else None,
            duration_s=result.duration_s if result else None,
            warm=result.warm if result else None,
            residues=result.residues if result else 0,
        )


class JobSummary(BaseModel):
    """What job lists need: no sequence text, stages, logs or arrays."""

    id: str
    kind: JobKind
    name: str
    model_id: str
    entity_type: EntityType
    length: int
    sequence_key: str
    seed: int
    samples: int
    status: JobStatus
    progress: float
    current_stage: str | None = None
    stage_name: str | None = None
    stage_message: str | None = None
    created_at: float
    started_at: float | None = None
    finished_at: float | None = None
    error: str | None = None
    hint: str | None = None
    plddt: float | None = None
    ptm: float | None = None
    iptm: float | None = None
    device: str | None = None
    duration_s: float | None = None
    warm: bool | None = None
    residues: int = 0


class CreateJobResponse(BaseModel):
    job: Job


class CreateJobsRequest(BaseModel):
    """The same input on several models, for side-by-side comparison."""

    model_ids: list[str] = Field(min_length=1, max_length=8)
    entity_type: EntityType = "protein"
    sequence: str = Field(min_length=1, max_length=8_000)
    name: str = "Untitled fold"
    seed: int = 42
    samples: int = Field(default=5, ge=1, le=20)


class CreateJobsResponse(BaseModel):
    jobs: list[Job]


class PaeResponse(BaseModel):
    size: int
    stride: int
    matrix: list[list[float]]
    note: str | None = None


class CompareResponse(BaseModel):
    reference_id: str
    other_id: str
    rmsd: float
    aligned: int
    atoms: str
    per_residue_distance: list[float | None]
    moved_text: str
    moved_format: Literal["pdb", "mmcif"]


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
    warm_capable: bool = False


class RunnerStatusModel(BaseModel):
    id: str
    installed: bool
    ready: bool
    weights_present: bool
    detail: str
    paths: dict[str, str] = Field(default_factory=dict)
    warm: bool = False
    version: str | None = None


class DeviceInfo(BaseModel):
    chip: str
    memory_gb: float
    performance_cores: int | None = None
    efficiency_cores: int | None = None
    macos: str = ""
    tier: str
    tier_label: str
    keep_warm_minutes: int
    max_resident_models: int
    gpu_budget_gb: float
    mlx_cache_limit_gb: float
    notes: list[str] = Field(default_factory=list)


class WorkerStatus(BaseModel):
    runner_id: str
    state: Literal["starting", "ready", "busy", "stopping", "dead"]
    pid: int | None = None
    started_at: float
    last_used: float
    jobs_served: int = 0
    load_s: float | None = None
    device: str | None = None
    rss_mb: float | None = None
    detail: str | None = None


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
    status_detail: str | None = None
    warm: bool = False


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
    device: DeviceInfo | None = None
    workers: list[WorkerStatus] = Field(default_factory=list)


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
    warm: bool | None = None
    timings: dict[str, float] = field(default_factory=dict)
    peak_memory_gb: float | None = None
    extra: dict[str, Any] = field(default_factory=dict)
