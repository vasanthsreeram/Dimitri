# alphafold3-mac web UI: reference notes

Source: [omrikais/alphafold3-mac](https://github.com/omrikais/alphafold3-mac) at commit `3d1ce7b` (Sep 20, 2026). These are read-only notes for Dimitri Studio. The screenshots in this folder come from that repo's `docs/images/`.

## Layout: two screens
- **Top bar (every page):** the logo, which also resets the form; a "Model ready" badge showing the chip and memory (e.g. "M4 128GB"); and a light/dark toggle.
- **Home (`/`):** a "New Prediction Session" card, with the prediction setup form on the left and Recent jobs on the right. See `home-fresh.png`.
- **Job page (`/job`):** live progress while a job runs, then the results.

## Home page form
- Job name (with a random-name button), seed (default 42, with an auto option), and a switch for MSA and template search.
- Import by PDB ID (fetched from RCSB), or upload JSON, PDB, CIF or mmCIF.
- An entity builder with protein, RNA, DNA, ligand (CCD code or SMILES) and ion cards. Cards can be dragged to reorder and have a copy count, so complexes work. Proteins get a per-residue grid for marking modifications. See `prediction-setup.png`.
- A restraint editor for guided docking: distance, contact and repulsive restraints, plus guidance scale, annealing and step range. See `restraint-editor.png`.
- A preview-and-submit dialog that shows whether the MSA is already cached, with a "use cache" switch.
- No model picker, since it only runs AF3. The number of samples isn't shown in the UI; the API default is 5.

## Job page stages
Loading model, then MSA and template search, preparing features, recycling (Evoformer), diffusion denoising, computing confidence, and writing outputs. There's a progress bar with a percentage and a cancel button, and updates arrive over a WebSocket. The Recent jobs list has search, status filters, and reuse, cancel and delete buttons. There's no log viewer.

## Results
- Score cards for pTM, ipTM (for complexes) and mean pLDDT.
- A **Mol\*** 3D viewer showing the selected sample's CIF, with a sample picker that stars the top-ranked sample. Restraint lines are green when met and red when not.
- A per-residue pLDDT bar chart (bands at >90, 70-90, 50-70 and <50), a PAE heatmap, and a sample ranking table. See `results-structure.png` and `restrained-results.png`.

## Downloads
The selected sample's CIF, the confidence JSON, all samples as a ZIP, and "Open in Finder". There's no PDB export.

## Models, weights and network use
- Weights are requested by hand from DeepMind (`af3.bin.zst`, about 1 GB) and placed in `~/.alphafold3/weights/model/`. They're converted to MLX in memory at load time.
- **No model hub**: no Hugging Face, bio.rodeo or similar. The only external fetches are setup downloads and optional PDB lookups.
- MSA search uses local HMMER against DeepMind's databases (about 500 GB, optional) and caches its results. There's no ColabFold or MMseqs2 server. Without the databases it runs on sequence alone.

## Stack and launch
Next.js 16 static export (React 19, Tailwind, shadcn, Recharts, Mol\*) served by FastAPI. Install with `scripts/install.sh`, start with `scripts/start.sh`, and open http://127.0.0.1:8642. It recommends an M-series Max or Ultra chip with 36 GB or more. There's no hosted demo.

## Takeaways for Dimitri Studio
- The two-screen flow (set up, then job and results) is simple and worth copying.
- Gaps Dimitri could fill: a model picker and library, PDB export, a visible sample count, and pLDDT coloring in the 3D view.
