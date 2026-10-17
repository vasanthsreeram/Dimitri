# Architecture

Dimitri Studio is two processes on one Mac:

```
┌──────────────────────────────┐        HTTP + SSE         ┌───────────────────────────────┐
│  SwiftUI app (app/)          │  http://127.0.0.1:8642   │  FastAPI backend (backend/)   │
│                              │ ───────────────────────▶ │                               │
│  AppModel (one @MainActor)   │ ◀─────────────────────── │  AppState                     │
│   ├ Predict                  │      job JSON / events    │   ├ Settings                  │
│   ├ Results (Mol*, charts)   │                           │   ├ RunnerRegistry            │
│   ├ Library                  │                           │   ├ JobStore                  │
│   └ Settings sheet           │                           │   ├ JobManager (one worker)   │
└──────────────────────────────┘                           │   └ CatalogService            │
                                                           └───────────────┬───────────────┘
                                                                           │ subprocess
                                                           ┌───────────────▼───────────────┐
                                                           │ AF3 · RhoFold · OpenFold3     │
                                                           │ checkouts + environments      │
                                                           └───────────────────────────────┘
```

The backend owns all state and files. The app is a client: it never shells out or
touches model weights itself.

## Runtime policy

Dimitri is MacBook-only. All inference targets Apple Silicon through Metal:

| Runner | Runtime | Device | Fallback | Environment |
|---|---|---|---|---|
| `alphafold3-mac` | MLX port of AlphaFold 3 | `mlx` | none | `~/.dimitri/models/alphafold3-mac/.venv` |
| `rhofold` | Upstream RhoFold+ on PyTorch | `mps` | CPU, last resort | `~/.dimitri/models/rhofold/.venv` |
| `openfold3` | OpenFold3-MLX kernels on PyTorch | `mps` | none | `~/.dimitri/models/openfold-3-mlx/.venv` |

There is no CUDA code path, no llama.cpp, and no GGUF. No runner accepts a generic
`--device cuda` option. MLX is preferred where a port exists; PyTorch MPS is the
fallback for models without one; CPU is only used if MPS is unavailable, and the
result's device row and note say so.

The runtime is data, not hardcoded UI: `RunnerManifest` carries `runtime`, `device`
and `fallback`, and `to_model()` exposes them through `/api/runners` and
`/api/models`. Each completed job also records the device it actually used
(`JobResult.device`), which Results displays. The app shows the target runtime in
Predict and Library.

DeepSeek and other LLMs are not runtimes for structure prediction and are not part
of the inference stack. The LM Studio probe is a status check only.

## Backend

### AppState and settings

`dimitri/main.py` builds an `AppState` once. It loads `~/.dimitri/settings.json`
(or `DIMITRI_HOME`), creates the storage directories, then constructs the registry,
job store, job manager and catalogue. Saving settings rebuilds all four, so runner
paths change without a restart. Paths must be absolute; this is validated in
`PUT /api/settings`. Paths must be absolute or `~`-prefixed; both are expanded.

### Job queue

`dimitri/jobs.py` has one worker thread reading a `queue.Queue`. One job at a time
is deliberate: these models saturate unified memory. A job is an id plus a
`Runner.run` call; every update rewrites `job.json` atomically (temporary file +
`os.replace`).

State machine:

```
queued ──▶ running ──▶ completed
   │           ├──────▶ failed       (RunnerNotReady / RunnerError / exception)
   └───────────┴──────▶ cancelled    (control event + SIGTERM to the child)
```

On startup, `JobStore._load_existing()` reads every `results/jobs/*/job.json` and
marks jobs left `running`/`queued` as failed, because their worker no longer
exists.

### Runner contract

`dimitri/runners/base.py` defines a manifest and an abstract class. A runner is
executable code shipped in this repository that wraps an external model checkout.

```python
class Runner(ABC):
    manifest: RunnerManifest

    def status(self, settings) -> RunnerStatusModel: ...
    def install(self, settings, progress, control) -> InstallResult: ...
    def run(self, request, workdir, settings, progress, control) -> RunResult: ...
```

- **Manifest** declares id, display name, entity types, source URL, citation,
  weight note/request URL/directory, setup hint, and the ordered stage list.
  The job's initial stages come from this list, so the UI never hardcodes a model's
  pipeline.
- **status** is a cheap probe (files and directories only) that reports
  `installed`, `weights_present`, `ready`, and a human-readable detail.
- **install** runs the per-runner `setup/*.sh` script through
  `run_command`, which streams output and honours cancellation.
- **run** returns a `RunResult`: PDB or CIF text, metrics, per-residue pLDDT, PAE,
  a note and extra metadata. It may raise `RunnerNotReady` with a hint.
- **progress(stage_id, fraction, message)** updates the job. Stages before the
  target are marked done; the target stage gets the fraction. Overall progress is
  `(stage index + fraction) / stage count`.

`RunnerRegistry` registers the three real runners plus `DemoRunner`. The demo
runner sets `visible=False`; it appears in tests and never in `/api/runners` or the
catalogue shown to users.

### Output normalization

`dimitri/export.py` and `JobStore.write_result()` turn a `RunResult` into a fixed
on-disk contract:

```
results/jobs/<id>/
  job.json         # full job incl. stages, log tail, result
  structure.cif
  structure.pdb
  result.json      # normalized confidence JSON (the app's JSON export)
  confidence.json  # metrics + per-residue pLDDT + PAE
  work/            # runner scratch: input JSON, raw model output, temp files
```

If a runner provides only PDB, Biopython writes CIF, and vice versa. Metrics are
normalized to `{plddt, ptm, iptm}`; a model that does not report a metric returns
`null`, and the UI shows “—” rather than inventing a value.

### Live updates

`GET /api/jobs/{id}/events` is a `text/event-stream` that polls the in-memory job
every 250 ms and emits `event: job` only when the serialized job changes, with
heartbeats. It closes after a terminal status. The app also polls every 5 seconds,
which covers reconnects, app restarts, and jobs started elsewhere. SSE was chosen
over WebSockets because the stream is one-way and `URLSession.bytes` consumes it
with no dependency.

### Catalogue

`dimitri/catalog.py` merges:

1. a curated local list (`catalog/models.json`) that binds a model to a runner and
   a bio.rodeo slug, and
2. metadata read from bio.rodeo model pages (name, description, provider, license,
   openness).

It ships a snapshot built from live requests and can refresh into an on-disk cache.
The cache is used while it is younger than 24 hours; the shipped snapshot is the
fallback. There is no bio.rodeo API; the adapter parses schema.org JSON-LD plus two
visible stat spans. Details and evidence are in
[docs/BIO_RODEO.md](BIO_RODEO.md).

### Disk usage

`/api/status` walks the models, results and cache directories. Per-model sizes
combine the runner checkout and its weight directory. `/api/models` exposes the
sum per catalogue entry.

## App

`app/Sources/DimitriStudio/` is one SwiftPM executable target (no external
dependencies):

| File | Role |
|---|---|
| `DimitriApp.swift` | `@main`, window, activation policy |
| `RootView.swift` | top bar, three-screen switcher, offline/banner chrome |
| `PredictView.swift` | model picker, entity picker, sequence, seed/samples, run |
| `ResultsView.swift` | job list, live stages, metrics, viewer, exports |
| `LibraryView.swift` | catalogue cards, install progress, disk usage, sources |
| `SettingsView.swift` | storage/runner paths, backend status, LM Studio status |
| `Charts.swift` | Canvas pLDDT bars and PAE heatmap |
| `MolStarView.swift` | `WKWebView` + Mol* UMD build from jsDelivr |
| `AppModel.swift` | `@MainActor` state, polling, SSE watch, exports, settings |
| `BackendClient.swift` | typed HTTP client and SSE parser |
| `Models.swift` | Codable mirror of the API (`convertFromSnakeCase`) |

`AppModel` polls `/api/status`, `/api/models`, `/api/jobs` and `/api/runners` every
5 seconds (2 seconds while offline). Submitting a prediction selects the new job
and opens an SSE watch. Export fetches the file as `Data` and writes it where the
save panel points.

The app decodes only fields it uses; adding a field to a backend response does not
break the client. `BackendClient` surfaces the backend's `detail` string for
non-2xx responses.

## API

| Method | Path | Purpose |
|---|---|---|
| GET | `/api/health` | Liveness |
| GET | `/api/status` | Backend, storage, LM Studio, runner statuses, catalogue source |
| GET/PUT | `/api/settings` | Read/update settings |
| GET | `/api/runners` | Visible runner manifests |
| GET | `/api/runners/status` | Status for visible runners |
| GET | `/api/runners/{id}` | One manifest |
| GET | `/api/models` | Catalogue with install/ready state and sizes |
| POST | `/api/models/{id}/install` | Queue a setup job |
| POST | `/api/catalog/refresh` | Re-fetch bio.rodeo pages into the cache |
| GET/POST | `/api/jobs` | List/create prediction jobs |
| GET/DELETE | `/api/jobs/{id}` | Read/delete a job and its files |
| POST | `/api/jobs/{id}/cancel` | Cancel a queued or running job |
| GET | `/api/jobs/{id}/events` | SSE job stream |
| GET | `/api/jobs/{id}/download/{cif,pdb,json}` | Exports |

The server binds only to `127.0.0.1`. There is no authentication because there is
no remote surface; that would need to change before exposing it on a network.

## Adding a model

1. Create `backend/dimitri/runners/<id>.py` with a `RunnerManifest` and the three
   methods. Shell out to the model's own CLI; do not import heavy frameworks into
   the backend process.
2. Add `backend/dimitri/runners/setup/<id>.sh` that clones/installs and reports
   progress on stdout.
3. Register the class in `runners/registry.py`.
4. Add a catalogue entry in `catalog/models.json` with `runner_id` and the
   bio.rodeo slug.
5. Add unit tests for input construction and readiness probing.

## Design decisions and trade-offs

- **Subprocess isolation.** Model inference lives in the runner's own Python
  environment. The backend stays small, and a crashing model cannot take the app
  down. The cost is slower cold starts and environment drift.
- **Normalized results.** CIF + PDB + one JSON shape makes the UI simple and keeps
  results portable. Raw model output is preserved under `work/` but not exposed.
- **Polling plus SSE.** SSE gives instant stage updates; polling makes restarts and
  reconnects harmless. Both are cheap because jobs are small JSON objects.
- **No database.** A directory per job is inspectable, easy to delete, and survives
  crashes with atomic writes.
- **Honest unavailable metrics.** RhoFold has no pTM/ipTM/PAE. The cards and charts
  show that instead of computing a substitute.
- **The demo runner stays hidden.** It exists to test the pipeline without
  gigabytes of weights, not to look like a scientific result.

## Tests

`backend/tests/` covers the API surface, job lifecycle (including persistence across
restart and SSE), exports and conversions, catalogue parsing with mock HTTP
transports, runner readiness and input payloads, and LM Studio parsing. The Swift
target is verified by `swift build`; the UI was additionally rendered offscreen
with `NSHostingView` and inspected during development.
