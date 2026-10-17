# bio.rodeo integration notes

Verified on **2026-10-17** with real HTTP requests. bio.rodeo is a live,
public directory and evaluation site for biological foundation models (a
Pulsatance project). It is a catalogue and review site, not a model-download hub.

## What exists

| Probe | Result |
|---|---|
| `GET https://bio.rodeo` | `200`, Next.js on Vercel, title “bio.rodeo - The Analyst for Bio AI” |
| `GET https://bio.rodeo/robots.txt` | `200`; allows all; points at the sitemap |
| `GET https://bio.rodeo/sitemap.xml` | `200`, ~554 KB, **3,347** `<loc>` URLs, including `/models/<slug>` |
| `GET https://bio.rodeo/models` | `200`; searchable list; `?q=` filters results |
| `GET https://bio.rodeo/models/alphafold-3` | `200`; full model page |
| `GET https://bio.rodeo/models/rhofold-plus` | `200`; RhoFold+ page |
| `GET https://bio.rodeo/models/openfold3` | `200`; OpenFold3 page |
| `GET https://bio.rodeo/api` | **`404`** (HTML) |
| `GET https://bio.rodeo/api/models` | **`404`** (HTML) |
| `GET https://bio.rodeo/api/v1/models` | **`404`** (HTML) |

There is no documented or discoverable JSON API. Slugs are not guessable in all
cases: `/models/rhofold` renders “Model Not Found”, while `/models/rhofold-plus` is
the real entry.

## What the adapter reads

Each model page embeds schema.org structured data:

```json
{
  "@context": "https://schema.org",
  "@type": "SoftwareApplication",
  "name": "AlphaFold 3",
  "description": "Diffusion-based structure prediction model for ...",
  "applicationCategory": "Scientific Software",
  "provider": [{"@type": "Organization", "name": "Google DeepMind"}],
  "citation": {"@type": "ScholarlyArticle", "headline": "Accurate structure prediction ..."}
}
```

From visible markup it also reads two stat spans:

- `Openness` score (0–100), e.g. AlphaFold 3 = 28, RhoFold+ = 65, OpenFold3 = 92.
- `License`, e.g. `Apache-2.0`, `MIT`.

Implementation: `backend/dimitri/catalog.py`.

- `parse_model_page(slug, html)` extracts one record from the first
  `SoftwareApplication` JSON-LD block plus the stat spans. It returns `None` for
  “Model Not Found”.
- `BioRodeoAdapter.search_slugs(query)` reads `/models?q=<query>` and takes unique
  `/models/<slug>` links.
- `BioRodeoAdapter.sitemap_slugs()` lists model slugs from the sitemap.
- `refresh(slugs)` fetches pages with a 150 ms pause, writes
  `~/.dimitri/cache/bio_rodeo.json`, and is served by
  `POST /api/catalog/refresh`.
- The repository ships `catalog/bio_rodeo_snapshot.json`, built by
  `scripts/build_bio_rodeo_snapshot.py`, so the Library works on first launch with
  no network. Live refresh takes precedence once present.

The app merges these records with local runner metadata
(`catalog/models.json`). Local data answers “can Dimitri run it?”; bio.rodeo answers
“what is it, who made it, how open is it, where is its page?”.

## Reproduce

```bash
curl -sS -o /dev/null -w "%{http_code}\n" https://bio.rodeo/api/models
curl -sS https://bio.rodeo/sitemap.xml | grep -c "<loc>"
curl -sS https://bio.rodeo/models/alphafold-3 | grep -o '"@type":"SoftwareApplication"'
PYTHONPATH=backend backend/.venv/bin/python scripts/build_bio_rodeo_snapshot.py
```

## The gap, stated plainly

- **No API.** Integration is HTML parsing. It can break when bio.rodeo changes its
  markup. The parser is covered by a fixture test, but that cannot predict a
  redesign.
- **Metadata only.** bio.rodeo does not provide model weights, downloads or
  installers. Those come from each model's own project (GitHub, Hugging Face,
  OpenFold, or DeepMind's request form for AlphaFold 3).
- **Coverage is curated.** Dimitri reads a small set of slugs relevant to structure
  prediction, not the full 3,000+ catalogue.
- **No affiliation.** bio.rodeo is used as a public reference source. Dimitri is not
  endorsed by it, and links point back to the model pages.
- **Rate and usage.** The adapter uses a descriptive User-Agent, fetches only public
  GET pages, pauses between requests, and caches for 24 hours. A refresh of six
  pages is normal use, not bulk crawling.
