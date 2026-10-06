# Taxonomy + Length Filters, Positional Domains — JGI Universal PFAM Search (feature layer)

## Context

**Why:** four new user-requested features on top of the already-built multi-domain search. The
multi-domain layer (all-domains-per-protein, boolean AND / exact-set, rank-by-#matched) is DONE and
now runs **winners-only** on the **Pfam 38.2** re-annotation: `build_pfam38_rollup.py` (validated) turns
the `resolve_clans.py` output into `protein_grain.parquet` + an EXACT architecture rollup. This feature
layer folds into that same build + the SPIN app (`~/git/pfam-search`, `feature/multidomain-search`),
served by ES + the rollup on zome-igb-1's docker (SPIN k8s is down — ignore it for now).

The four features:
1. **NCBI-taxonomy clade restriction** — an autocomplete box over clades present in the dataset;
   selecting a clade restricts results to that clade's descendant leaves. (**Advanced**, live.)
2. **Domain pills in protein order** (N→C by start coord, not e-value) + **each domain's alignment
   region highlighted on the sequence**.
3. **Kingdom selectors** in both the search box and the counts "toggle"; a more specific clade in the
   search **supersedes** the kingdom. (**Kingdom = Normal**, rollup-backed.)
4. **Sequence length min/max** filter. (**Advanced**, live `range`.)

**Organizing principle (user):** *Normal search is 100% rollup-backed (exact, instant); anything that
cannot be answered from a precomputed rollup lives in Advanced.* Advanced is a superset — it also hosts
rollup-backed power features (boolean expressions) that just need richer syntax.

### Feature classification against the principle

| Filter | Rollup-able? | Home | Mechanism |
|---|---|---|---|
| pfam sets ANY/ALL/exact | yes | Normal | architecture rollup (done) |
| **boolean pfam AND/OR/NOT** | **yes** | Advanced (grammar, not speed) | `archRollup.countsBool` — stays exact |
| portal | yes | Normal + toggle | rollup portal axis (done) |
| **kingdom (7 buckets)** | **yes** | **Normal + toggle** | new portal×kingdom rollup matrix |
| organism substring | no | Advanced | live `wildcard` (exists) |
| **arbitrary NCBI clade** | no | **Advanced** | live `term` on materialized `lineage_taxids[]` |
| **sequence length min/max** | no | **Advanced** | live `range` on `aa_length` |

When any live-only filter (organism / clade / length) is active, `/counts` falls back to live
aggregation — the ONLY time counts aren't rollup-exact, and only ever in Advanced.

**Locked decisions (user):** kingdom = **Animals, Plants, Fungi, Protists, Bacteria, Archaea, Viruses**
(each genome → exactly one); **kingdom in Normal, full clade box in Advanced** (clade supersedes
kingdom); **portal + kingdom = two toggle axes** (portal×kingdom matrix rollup); **IMG uses a real
`ncbi_taxon_id`** (verify the column first). Winners-only throughout (matches InterProScan clan
resolution).

---

## Track A — Taxonomy data pipeline (NEW; the join key + tree)

Goal: a small per-genome map `genome_taxonomy` keyed `(portal, genome_id)` →
`{taxid, kingdom, lineage_taxids[]}`. Per-genome (thousands of rows), NOT per-protein — joined at
build time, so it never bloats the annotation rows.

1. **Download NCBI taxdump** (`nodes.dmp`, `names.dmp`) to CFS `es_build/taxdump/`. Build a resolver:
   `taxid → [ancestor taxids root..taxid]` (materialized path) and `taxid → superkingdom / kingdom
   markers`.
2. **Capture a real NCBI taxid per genome** by extending `pipeline/build_xdomain_annotation.py` (the
   dedup code already READS all three; today it discards them):
   - Phytozome: CHADO `organism_dbxref→dbxref→db WHERE db.name='Taxonomy'` (`:171-176`).
   - Mycocosm/Phycocosm: `organismConfigPropertyProd` name=`taxonomyId` (`:178-180`).
   - IMG: `img_core_v400.taxon.ncbi_taxon_id` per `taxon_oid` — **verify this column exists** (a
     one-off `SELECT` against the lakehouse) before wiring; the `taxon` table definitely has
     `domain`+`phylum` as the fallback.
   Emit `genome_taxonomy.parquet/json` (portal, genome_id, taxid).
3. **Derive the 7-bucket kingdom** from each taxid's lineage: `Viruses`→Viruses, `Bacteria`→Bacteria,
   `Archaea`→Archaea; `Eukaryota` → `Metazoa`=Animals, `Viridiplantae`=Plants, `Fungi`=Fungi, else
   Protists. Store `kingdom` + `lineage_taxids[]` in the map.
4. **Emit `clades_in_dataset.json`** for the Advanced autocomplete: every taxid that appears in ANY
   genome's `lineage_taxids` (so a selection always has ≥1 leaf), with name + rank from `names.dmp`.

## Track B — Protein-grain builder (`build_pfam38_rollup.py`) changes

1. **Winners-only:** filter to `winner=1` before building `protein_pfams` / the rollup. The searchable
   & counted set becomes the clan winners (InterProScan view). Drop the "all-GA-passing" contract in
   the docstring (the current file argues the opposite — flip it).
2. **Positional coordinates (feature #2):** the TSV's `env_from/env_to` are already read as `fmin/fmax`
   (`:80-81`) but dropped. Carry them:
   - per (protein,pfam) winner: `min(fmin)` start, `max(fmax)` end;
   - order the aligned arrays (`protein_pfams`, `_evalues`, `_names`, starts, ends) **by start coord**
     so pills read N→C. Add `protein_pfam_starts[]`, `protein_pfam_ends[]`.
   - emit `domain_layout` = per-instance winner list `[{pfam,start,end}]` ordered by start (shows
     **repeats**, e.g. tandem ANK) — drives the sequence graphic. (Default: per-instance graphic +
     distinct positional pills. Flagged, reversible.)
3. **aa_length (feature #4):** join `protein_sequence.aa_length` on `(domain,genome_id,protein_id)`
   into the protein grain (aa_length lives only in `protein_sequence` today). One int per protein.
4. **Kingdom join for the rollup:** join `genome_taxonomy` on `(portal=domain, genome_id)` to attach
   `kingdom` to each protein.
5. **Rollup → portal×kingdom matrix:** value per architecture becomes a `[portal][kingdom]` matrix of
   distinct-protein counts (flat length-28 vector aligned to documented `portals[]`×`kingdoms[]`).
   Each protein falls in exactly one cell ⇒ additive & exact; sum over any portal-subset and/or
   kingdom-subset. Extend the builder's self-validation to prove `sum(matrix)==portal totals==direct`.

## Track C — ES mapping + protein-grain doc assembly (v-next mapping)

New per-doc fields (extend `es_mapping_v3.json` → new mapping, keep `index.sort evalue asc`):
- `kingdom` — keyword (indexed; Normal filter + rollup + display).
- `taxid` — keyword (display / NCBI link).
- `lineage_taxids` — **keyword[]** (indexed; Advanced clade `term` — set membership, early-terminating).
- `aa_length` — integer (indexed; Advanced `range`).
- `protein_pfam_starts` / `protein_pfam_ends` — integer[] (`index:false`, _source) — pill order + highlight.
- `domain_layout` — object[]/parallel arrays (`index:false`, _source) — per-instance graphic.

The doc-assembly step (the already-planned "next" step: join organism map + `resolved.json` portal
links + fasta) also joins `genome_taxonomy` (kingdom/taxid/lineage) and `aa_length`. Index into
zome-igb-1's ES with `refresh_interval:-1, replicas:0`, then force-merge.

## Track D — Server (`~/git/pfam-search/server/`)

- `pfam-controllers-elasticsearch.js`
  - `SOURCE_FIELDS` += `kingdom, taxid, protein_pfam_starts, protein_pfam_ends, domain_layout` (not
    `lineage_taxids` — filter-only). `hitToRow` passes them through.
  - `buildFilter` / `scopeFilters` add: `kingdom` → `terms:{kingdom:[...]}`; `clade` →
    `term:{lineage_taxids: cladeTaxid}`; length → `range:{aa_length:{gte,lte}}`. **Clade supersedes
    kingdom:** if `clade` present, omit the kingdom clause. OR/AND pfam path unchanged; sort stays bare
    `evalue asc` (early termination preserved — all new clauses are filter-context).
  - `counts`: portal×kingdom rollup for rollup-able queries (pfam-sets / boolean / portal / kingdom);
    live agg fallback when organism/clade/length present. Rollup lookups sum the matrix with
    portal-mask ∧ kingdom-mask.
- `pfam-arch-rollup.js`: make `counts()`/`countsBool()` matrix-aware (portal-subset ∧ kingdom-subset
  masks); load the length-28 vectors.
- `pfam-controllers-duckdb.js` + `-starburst.js` (download parity): `kingdom IN (...)`,
  `list_contains(lineage_taxids, X)` (add lineage to the parquet or join `genome_taxonomy`),
  `aa_length BETWEEN`. Fold `kingdom/clade/len_min/len_max` into `cache.keyFor`.
- `pfam-routes.js`: same 5 endpoints; new query params `kingdom, clade, len_min, len_max`.

## Track E — Frontend (`~/git/pfam-search/src/`)

- `api.js`: thread `kingdom, clade, len_min, len_max` through `searchPfam`/`fetchCounts`/`fastaUrl`/
  `tsvUrl` (`buildQuery` drops empties). Load `clades_in_dataset.json` for autocomplete.
- `SearchBar.jsx`:
  - Simple tab: a **Kingdom** multi-select (7 chips). Rollup-backed.
  - Advanced tab: **NCBI clade autocomplete** box (over `clades_in_dataset.json`), **length min/max**
    inputs, alongside existing organism + boolean. Clade selection supersedes kingdom.
- `App.jsx`: new `kingdom/clade/lenMin/lenMax` state; thread through
  `onSearch`/`runQuery`/`runSearch`/`loadCounts`/`activeQuery`/`displayQuery` (downloads honor them).
- Counts **toggle**: add a **kingdom chip row** beside the portal chips (`.portal-toggles` at
  `App.jsx:493-551`) — both include/exclude, both summed from the portal×kingdom matrix. New
  `hiddenKingdoms` state mirrors `hiddenPortals`.
- `ResultRow.jsx`:
  - order pills by `protein_pfam_starts` (positional) instead of the current e-value sort (`:81-85`).
  - sequence panel (`:185-199`): overlay colored spans per domain from `domain_layout` (start/end) on
    the fetched sequence; queried domains highlighted; repeats shown. Reuse the existing `/sequence`
    fetch — coords come from the row, no server change.
  - show `kingdom` (+ NCBI taxid link) per row.

## Autocomplete + graceful degradation

- Autocomplete source = `clades_in_dataset.json` (Track A.4) — only clades with ≥1 leaf present.
- Capability flags (health probe): `PFAM_HAS_TAXONOMY` (kingdom/clade/toggle), `PFAM_HAS_COORDS`
  (positional pills + highlight), `PFAM_HAS_LENGTH`. Against an index lacking a field, the control is
  hidden and the row falls back (pills by e-value, no highlight) — safe on either index.

## Verification (prove each feature)

- **Kingdom (rollup-exact):** builder self-validation `sum over kingdoms == portal totals == direct`.
  `/counts?ids=PF00069` → kingdom chips sum to the portal totals. Boolean + kingdom stays exact via
  `countsBool`.
- **Clade (Advanced, live):** pick e.g. Brassicaceae taxid → `term lineage_taxids` returns only
  descendants; cross-check a few organisms; count ≤ its kingdom count. Clade set → kingdom ignored.
- **Length:** `range aa_length [min,max]` returns only in-range proteins; matches
  `protein_sequence.aa_length` spot-checks; empty-range guarded.
- **Positional pills + highlight:** a known multidomain protein (Arabidopsis AT5G18650.1) → pills N→C
  by start; expanded sequence shows each domain's env span highlighted; a tandem-repeat protein shows
  repeats in order.
- **IMG taxid:** confirm `img_core_v400.taxon.ncbi_taxon_id` exists; IMG rows carry `lineage_taxids`
  and a correct kingdom (Bacteria/Archaea/Eukaryota split visible in the toggle).
- **No regression:** Normal search still rollup-only and instant; OR/AND pfam bodies unchanged except
  the new filter clauses; downloads (FASTA/TSV) == table under every new filter.

## Risks / open items

- **IMG `ncbi_taxon_id`** unverified — if absent, IMG falls back to `taxon.domain`/`phylum` (kingdom +
  coarse clade only). Verify before building the pipeline.
- **Rollup size:** portal×kingdom = 28 ints/architecture (×~540k arch). Larger JSON — measure; consider
  a compact binary if needed.
- **`index:false` landmine** persists — never `terms`-filter `protein_id`/`genome_id`; taxonomy
  narrowing is via `kingdom`/`lineage_taxids` (both indexed).
- **Repeats in pills:** default = per-instance graphic + distinct positional pills; confirm if the user
  wants distinct-only pills.
- **Kingdom for unmappable genomes:** a genome with no resolvable taxid → `kingdom='Unknown'` bucket
  (never silently dropped); surface the count.
- **Staleness:** taxdump snapshot frozen at build; note the download date.

## Critical files
- NEW `es_build/build_genome_taxonomy.py` (taxdump + per-portal taxid → kingdom + lineage + clades json)
- `pipeline/build_xdomain_annotation.py` (capture taxid per genome)
- `es_build/build_pfam38_rollup.py` (winners-only, coords, aa_length join, portal×kingdom rollup)
- NEW/updated ES mapping + the doc-assembly step (kingdom/taxid/lineage/aa_length/coords)
- `server/pfam-controllers-elasticsearch.js`, `server/pfam-arch-rollup.js`,
  `server/pfam-controllers-duckdb.js`, `server/pfam-controllers-starburst.js`
- `src/App.jsx`, `src/components/{SearchBar,ResultRow}.jsx`, `src/api.js`, new `clades_in_dataset.json`

**Sequencing note:** the data-side tracks (A, B, C) are gated on the full `resolve_clans.py` output
(another session, ~in progress) and a fresh Trino JWT + dori key. Server/frontend (D, E) can proceed
against the validated bench slice now. Nothing pushed to git without approval.
