# Architecture

Dimitri Studio is a SwiftUI app, a local FastAPI backend that the app starts
and stops, and one warm worker process per loaded model, each in that model's
own Python environment.

```
┌───────────────────────────────┐   HTTP + one SSE stream   ┌──────────────────────────────┐
│ Dimitri Studio.app (SwiftUI)  │   127.0.0.1:8642          │ Backend (FastAPI, uv venv)   │
│                               │ ────────────────────────▶ │                              │
│ BackendController ── starts, ─┼─ watches, stops ─────────▶│ AppState                     │
│ AppModel (@Observable)        │ ◀──────────────────────── │  ├ JobStore (+ versions)     │
│  ├ Predict                    │  snapshot, then changes   │  ├ JobManager (1 GPU queue)  │
│  ├ Results ── Mol* (WKWebView)│                           │  ├ RunnerRegistry            │
│  ├ Library                    │                           │  ├ WorkerPool ───────────────┼──┐
│  └ Settings / Welcome         │                           │  ├ DeviceProfile, DiskSizer  │  │
└───────────────────────────────┘                           │  └ CatalogService, LM probe  │  │
                                                            └──────────────────────────────┘  │
                         JSON lines on stdin/stdout, one process per loaded model             │
             ┌───────────────────────────────┬──────────────────────────────────┬─────────────┘
             ▼                               ▼                                  ▼
   rhofold_worker.py               af3_worker.py                       (OpenFold3: one
   rhofold-mac/.venv (PyTorch MPS) alphafold3-mac/.venv (MLX)           process per job)
   imports rhofold-mac/RhoFold     imports mac-af3 core + streaming
```

The backend owns all state and files. The app never loads weights or runs
inference; model runtimes never run inside the backend process.

## Runtime policy

MacBook-only: Apple Silicon and Metal. MLX first, PyTorch MPS second, CPU only
as a reported last resort. No CUDA, no llama.cpp, no GGUF.

| Runner | Runtime | Device | Installed from | Environment |
|---|---|---|---|---|
| `rhofold` | rhofold-mac (RhoFold+ in PyTorch) | `mps`, CPU fallback | github.com/vasanthsreeram/rhofold-mac, its own `setup.sh` | `<models>/rhofold-mac/.venv` |
| `alphafold3-mac` | mac-af3 on alphafold3-mac (MLX) | `mlx` | github.com/vasanthsreeram/mac-af3 (private) + omrikais/alphafold3-mac @ 3d1ce7b | `<models>/alphafold3-mac/.venv` |
| `openfold3` | OpenFold3-MLX (MLX kernels in PyTorch) | `mps` | latent-spacecraft/openfold-3-mlx | `<models>/openfold-3-mlx/.venv` |

Neither rhofold-mac nor mac-af3 is vendored. Dimitri clones them, runs their
own setup, and imports their code from those checkouts at run time.

## App

`app/Sources/DimitriStudio/` is one SwiftPM executable target (macOS 14+, no
third-party Swift packages).

| File | Role |
|---|---|
| `DimitriApp.swift` | `@main`: one `Window`, a `Settings` scene, menus and keyboard shortcuts, files opened from Finder |
| `BackendController.swift` | finds, starts, watches and stops the backend; first-launch environment setup with the bundled uv |
| `AppModel.swift` | `@Observable` state, the event-stream loop, actions, caches (structures, PAE, comparisons) |
| `BackendClient.swift` | typed HTTP client and the `/api/events` parser |
| `RootView.swift` | `NavigationSplitView`: sidebar (logo, screens, recent jobs, backend/device footer), start-up states, toasts, window-wide file drop |
| `PredictView.swift` | input (FASTA paste/drop, entity detection, composition strip), model cards (multi-select), run panel |
| `ResultsView.swift` | job list, live stage timeline, metrics, Mol* viewer card, charts, run details, export |
| `CompareView.swift` | superposed overlay, RMSD, per-residue deviation and pLDDT of several models on one input |
| `LibraryView.swift` | model cards with install progress, weights guidance, loaded-model controls, disk use |
| `SettingsView.swift`, `OnboardingView.swift` | settings tabs; first-run checklist with a one-click first fold |
| `Charts.swift` | Swift Charts pLDDT (bands, hover), PAE bitmap heatmap, overlay and deviation charts |
| `MolStarView.swift`, `Resources/Viewer/` | the structure viewer (below) |
| `Theme.swift`, `LogoMark.swift`, `Files.swift`, `Automation.swift` | design system, vector logo, FASTA/structure files, scripted snapshots |

### Backend lifecycle

`BackendController` probes `127.0.0.1:8642/api/health`. A healthy Dimitri
0.2 backend (it reports `"app": "dimitri-studio"`) is reused and left running
on quit. Otherwise the app starts `python -m dimitri --port N --parent-pid
<app pid>`:

- **In the .app** the backend's source is `Contents/Resources/backend`. On first
  launch the app runs the bundled `Contents/Helpers/uv` (`uv sync --frozen
  --no-dev --no-install-project`) to create the environment in
  `~/Library/Application Support/Dimitri Studio/backend-venv`, outside the
  signed bundle; a hash of `uv.lock` and the build number decides when to
  re-sync. Bytecode goes to `~/Library/Caches/Dimitri Studio/pycache`, so
  nothing inside the bundle ever changes.
- **From a checkout** (`swift run`) it uses `backend/.venv`, creating it with
  uv if missing.
- If something else holds port 8642, it picks a free port.
- If the backend exits unexpectedly it is restarted (up to three times).
- On quit it sends SIGTERM and waits up to four seconds. The backend's
  shutdown stops warm workers. The backend also watches the app's pid and
  exits if the app dies, and workers exit when their stdin closes.

Output goes to `~/Library/Logs/Dimitri Studio/backend.log` (Help → Show
Backend Log).

### Live updates

The app opens one `GET /api/events` stream for its whole life. It receives a
snapshot of every job summary, then only changes: `job` events (summary,
stages, last log lines) as jobs move, `deleted`, and `runners` when a model is
loaded, unloaded or installed. Nothing polls except `/api/status` every 30
seconds (disk, LM Studio, device). Full job records are fetched once a job is
selected or finishes; PAE matrices, structures and comparisons are fetched on
demand and cached. The phase 1 app polled four endpoints every five seconds
and downloaded every result's PAE matrix on each poll.

### Structure viewer

Mol* 5.12.0 (MIT) is bundled in `Resources/Viewer` with Dimitri's own
`index.html` and `viewer.js`; the viewer needs no network. One
`MolStarController` (a `WKWebView` plus a `dimitri` script-message bridge)
lives as long as the app, so switching jobs or screens never reloads Mol*.
Swift sends structure text and format with `callAsyncJavaScript`; the page
answers `ready`, `loaded` (atoms, residues, polymer types, secondary
structure, whether B-factors are usable as confidence) or `error`.

Why phase 1 showed "circular dots": every structure it displayed on this Mac
came from the demo runner, whose PDB files had atom names one column too far
left (`ALA` parsed as alternate location `A` plus residue `LA`, no chain). Mol*
recognised no polymer, and the old page used Mol*'s automatic preset, which
draws non-polymers as unbonded atoms. The page also depended on a CDN, never
loaded Mol*'s stylesheet, did not colour by confidence and could not report
errors; and the Biopython-written mmCIF it loaded has no entity records and
splits chains at modified residues. Now:

1. the viewer gets the model's **native** text and format
   (`/api/jobs/{id}/structure`, `X-Structure-Format: pdb|mmcif`);
2. mmCIF without entity records (alphafold3-mac writes one) gets them added
   with gemmi, which also writes every exported CIF;
3. `viewer.js` builds explicit representations: polymer → cartoon (protein and
   nucleic acids, with computed secondary structure when the file has none),
   ligands → ball-and-stick, ions small spheres, water hidden. It never falls
   back to atoms for a polymer, and reports a file with no polymer. Only the
   first model of an NMR ensemble is shown;
4. pLDDT colouring reads B-factors with the AlphaFold bands (≥90 #0053D6,
   70–90 #65CBF3, 50–70 #FFDB13, <50 #FF7D45). Files whose B-factors are not
   confidence values (all zero, constant, or experimental) are coloured by
   secondary structure or chain, and the legend says so.

`scripts/viewer-check.sh` compiles the app's `MolStarView.swift` into an
offscreen harness, blocks all network access, loads a structure and checks the
rendered image (cartoon present, helix found, pixels in the pLDDT bands).

## Backend lifecycle

`BackendController` probes `127.0.0.1:8642/api/health`. A healthy Dimitri
0.2 backend (it reports `"app": "dimitri-studio"`) is reused and left running
on quit. Otherwise the app starts `python -m dimitri --port N --parent-pid
<app pid>`:

- **In the .app** the backend's source is `Contents/Resources/backend`. On first
  launch the app runs the bundled `Contents/Helpers/uv` (`uv sync --frozen
  --no-dev --no-install-project`) to create the environment in
  `~/Library/Application Support/Dimitri Studio/backend-venv`, outside the
  signed bundle; a hash of `uv.lock` and the build number decides when to
  re-sync. Bytecode goes to `~/Library/Caches/Dimitri Studio/pycache`, so
  nothing inside the bundle ever changes.
- **From a checkout** (`swift run`) it uses `backend/.venv`, creating it with
  uv if missing.
- If something else holds port 8642, it picks a free port.
- If the backend exits unexpectedly it is restarted (up to three times).
- On quit it sends SIGTERM and waits up to four seconds. The backend's
  shutdown stops warm workers. The backend also watches the app's pid and
  exits if the app dies, and workers exit when their stdin closes.

Output goes to `~/Library/Logs/Dimitri Studio/backend.log` (Help → Show
Backend Log).

### Live updates

The app opens one `GET /api/events` stream for its whole life. It receives a
snapshot of every job summary, then only changes: `job` events (summary,
stages, last log lines) as jobs move, `deleted`, and `runners` when a model is
loaded, unloaded or installed. Nothing polls except `/api/status` every 30
seconds (disk, LM Studio, device). Full job records are fetched once a job is
selected or finishes; PAE matrices, structures and comparisons are fetched on
demand and cached. The phase 1 app polled four endpoints every five seconds
and downloaded every result's PAE matrix on each poll.

### Structure viewer

Mol* 5.12.0 (MIT) is bundled in `Resources/Viewer` with Dimitri's own
`index.html` and `viewer.js`; the viewer needs no network. One
`MolStarController` (a `WKWebView` plus a `dimitri` script-message bridge)
lives as long as the app, so switching jobs or screens never reloads Mol*.
Swift sends structure text and format with `callAsyncJavaScript`; the page
answers `ready`, `loaded` (atoms, residues, polymer types, secondary
structure, whether B-factors are usable as confidence) or `error`.

Why phase 1 showed "circular dots": it always passed Mol* a `structure.cif`
written by Biopython from the model's PDB. That file had
`_atom_site.label_entity_id ?` and no `_entity`, `_entity_poly` or
`_struct_asym`, so Mol* could not classify the chain as a polymer and its
default preset drew loose atoms. Now:

1. the viewer gets the model's **native** text and format
   (`/api/jobs/{id}/structure`, `X-Structure-Format: pdb|mmcif`);
2. mmCIF without entity records (alphafold3-mac writes one) gets them added
   with gemmi, which also writes every exported CIF;
3. `viewer.js` builds explicit representations: polymer → cartoon (protein and
   nucleic acids, with computed secondary structure when the file has none),
   ligands → ball-and-stick, ions small spheres, water hidden. It never falls
   back to spacefill for a polymer. Only the first model of an NMR ensemble is
   shown;
4. pLDDT colouring reads B-factors with the AlphaFold bands (≥90 #0053D6,
   70–90 #65CBF3, 50–70 #FFDB13, <50 #FF7D45). Files whose B-factors are not
   confidence values (all zero, constant, or experimental) are coloured by
   secondary structure or chain, and the legend says so.

## Backend

### Device profile

`dimitri/device.py` reads the chip, unified memory and core counts with
`sysctl` and sizes three things:

| | 16 GB | 24–36 GB | 48 GB+ |
|---|---|---|---|
| GPU budget per model process | RAM − max(4 GB, 20 %) | same | same |
| MLX buffer cache | 5 % of RAM (0.5–4 GB) | same | same |
| Keep an idle model loaded | 5 min | 15 min | 30 min |
| Models loaded at once | 1 | 2 | 3 |
| AlphaFold 3 (mac-af3) | layer streaming + lean activations | resident weights; lean patches above 640 tokens | resident; lean above 1024 tokens |

Workers apply the budget themselves: `torch.mps.set_per_process_memory_fraction`
relative to Metal's recommended working set (RhoFold), `mx.set_memory_limit`
and `mx.set_cache_limit` (AlphaFold 3). A job that does not fit fails with a
clear out-of-memory message instead of pushing the Mac into heavy swap.

### Warm workers

`dimitri/workers.py`. A `WorkerSpec` is how to launch a runner's worker
(interpreter, script, environment); a changed spec restarts the worker. The
`WorkerPool`:

- reuses a ready worker for the next job of the same model;
- evicts the least recently used idle worker when the profile's limit is
  reached;
- stops workers idle longer than the keep-warm time (configurable: device
  default, 5/15/60 minutes, until quit, or never warm);
- cancels a job by killing its worker (the next job starts a fresh one);
- reports state, jobs served, load time and physical footprint
  (`proc_pid_rusage`) to `/api/workers` and the app.

Protocol (`runners/workers/protocol.py`, standard library only, runs in each
model's environment):

```
backend → worker  {"type": "predict", "job": id, "request": {...}, "workdir": path}
                  {"type": "shutdown"}
worker → backend  {"type": "ready", "device": "mps", "load_s": 2.1, ...}
                  {"type": "progress", "stage": "fold", "fraction": 0.4, "message": "Recycle 4/10"}
                  {"type": "result", "result": {...}}   or   {"type": "error", "message": ..., "hint": ...}
```

The worker moves the original stdout to a private descriptor and points file
descriptor 1 at stderr before importing model code, so prints from PyTorch,
MLX or C extensions cannot corrupt the protocol.

**RhoFold+** (`rhofold_worker.py`) imports rhofold-mac's patched RhoFold from
`<rhofold-mac>/RhoFold` with `RHOFOLD_FAST=1`, loads the checkpoint once,
reports each of the 10 recycles from a forward hook on `dist_head` (the last
module of each recycle), and writes the files rhofold-mac's `run.sh` writes:
`unrelaxed_model.pdb`, `ss.ct`, `results.npz`, `run_info.json`. pLDDT is
reported on 0–100. Upstream's PDB writer puts residue *i−1*'s confidence in
residue *i*'s B-factor; the worker rewrites B-factors from the model output.
If the worker cannot start, the runner falls back to rhofold-mac's `run.sh`.

**AlphaFold 3** (`af3_worker.py`) adds `alphafold3-mac/src` and mac-af3's
`core/scripts` and `tracks/weight-streaming/src` to the path, applies
`mac_af3_patches.apply_pre_build`, `streaming.install` and
`streaming.build_model` with the profile's configuration, then runs
alphafold3-mac's `InferenceRunner` per job with recycle, diffusion-step and
confidence callbacks. Inputs are single-sequence (empty MSAs, no templates).
Diffusion uses 20 steps for proteins and DNA and AlphaFold 3's reference 200
for RNA and ligands, following mac-af3's lab notebook.

### Jobs and storage

One `JobManager` thread runs one job at a time (these models fill unified
memory). Progress updates are applied in place under the store lock, streamed
immediately and written to disk at most every two seconds or on a stage
change. Every change bumps a version so the event stream sends only what
changed.

```
results/jobs/<id>/
  job.json          job record (no PAE matrix; it is in confidence.json)
  structure.pdb     exports; the runner's native one is byte for byte as written,
  structure.cif     except that a CIF without entity records gets them added
  result.json       normalized confidence JSON (the JSON export, PAE included)
  confidence.json   metrics, per-residue pLDDT, PAE
  work/             runner scratch and raw model output
```

Imported files (`POST /api/imports`) become completed jobs of kind `import`,
with the first polymer's sequence, so a prediction and an experimental
structure of the same sequence can be compared.

`/api/jobs/{a}/compare/{b}` superposes `b` onto `a` with gemmi (sequence
alignment, Kabsch fit on Cα or P) and returns the RMSD, per-residue distances
and the moved structure for the overlay.

Directory sizes are computed on a background thread; LM Studio is probed in
the background every 20 seconds. No request walks the disk or waits on the
network.

### Runner contract

```python
class Runner(ABC):
    manifest: RunnerManifest             # id, names, entity types, stages, runtime, weights note
    pool: WorkerPool | None              # set by the registry

    def status(self, settings) -> RunnerStatusModel       # files only, cheap
    def install(self, settings, progress, control) -> InstallResult
    def run(self, request, workdir, settings, progress, control) -> RunResult
    def worker_spec(self, settings) -> WorkerSpec | None   # warm-capable runners
```

## API

| Method | Path | Purpose |
|---|---|---|
| GET | `/api/health` | Liveness and app identity |
| GET | `/api/events` | App-wide SSE: snapshot, then job/deleted/runners changes |
| GET | `/api/status` | Device, storage, LM Studio, runners, loaded workers |
| GET | `/api/device`, `/api/workers` | Device profile; warm workers |
| GET/PUT | `/api/settings` | Paths, warm-worker settings |
| GET | `/api/runners`, `/api/runners/status`, `/api/runners/{id}` | Manifests and status |
| POST | `/api/runners/{id}/warm`, `/api/runners/{id}/release` | Load a model in the background; unload it |
| GET | `/api/models` | Catalogue with install state and sizes |
| POST | `/api/models/{id}/install` | Queue a setup job |
| POST | `/api/catalog/refresh` | Re-read bio.rodeo pages |
| GET/POST | `/api/jobs` | Job summaries; create a prediction |
| POST | `/api/jobs/batch` | One input on several models |
| POST | `/api/imports` | Open a PDB/mmCIF file as a result |
| GET/DELETE | `/api/jobs/{id}` | Full job; delete with its files |
| POST | `/api/jobs/{id}/cancel` | Cancel (kills the job's worker) |
| GET | `/api/jobs/{id}/structure` | Native structure text and format |
| GET | `/api/jobs/{id}/pae?max=N` | PAE, block-averaged to at most N cells |
| GET | `/api/jobs/{id}/compare/{other}` | Superposition, RMSD, per-residue distance |
| GET | `/api/jobs/{id}/events` | Per-job SSE (kept for scripts) |
| GET | `/api/jobs/{id}/download/{cif,pdb,json}` | Exports |

The server binds only to 127.0.0.1 and has no authentication; it is not meant
to be exposed on a network.

## Packaging

`scripts/build-app.sh` builds the release executable and assembles
`dist/Dimitri Studio.app`: Info.plist (bundle id
`com.vasanthsreeram.dimitristudio`, document types for FASTA, PDB and mmCIF),
the icon (`app/Bundle`), the viewer resources, the backend source, and uv in
`Contents/Helpers`. It signs uv and then the app with the Developer ID,
hardened runtime and a secure timestamp, with an empty entitlements file
(reasons in the script), and verifies with `codesign --verify --deep
--strict` and `spctl`. `scripts/notarize.sh` notarizes and staples when a
notarytool keychain profile exists; `scripts/make-dmg.sh` builds the
drag-to-Applications disk image.

## Tests

`backend/tests/` (pytest, about 15 s): API, jobs and persistence, the event
stream, exports and gemmi conversion (including the entity records the
viewer needs), imports and superposition, the worker pool through a real
worker process (reuse, cold mode, errors, cancel, load failures, idle and LRU
eviction), runner status and outputs for rhofold-mac and mac-af3, catalogue
parsing. `swift build` must stay warning-free. `scripts/viewer-check.sh`
renders structures with the bundled Mol* offscreen and checks for a cartoon.
`scripts/bench_runner.py` times real RhoFold+ or AlphaFold 3 jobs cold and warm.
