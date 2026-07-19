# JGI Portal Proteins & PFAM — Cross-Portal Reference Guide

What we know about **proteins and their PFAM domain assignments** across the three JGI portal
database systems that feed the cross-domain PFAM search tool (`pfuniv-dev.jgi.lbl.gov`, repo
`~/git/pfam-search` = gitlab `dsi/data-lakehouse/pfam-universal`). Covers where the proteins live,
how PFAM hits are stored, what filtering the extractor applies, and — importantly — **what filtering
we still need to add**.

All three are reached as **federated Trino catalogs** on the lakehouse
(`lakehouse-pov.jgi.lbl.gov:443`, JWT in `~/.starburst_jwt`; see `starburst-guide.md`). Catalog names
carry a backend suffix that can rotate — always `SHOW CATALOGS` to confirm. **Never inline credentials**
— read the JWT from the file; use config-file readers for direct DB access.

---

## The three portal systems at a glance

| Portal | Organisms | Catalog / DB | PFAM source table | Grain |
|---|---|---|---|---|
| **Phytozome** | plants | `"plant-db-7_postgresql"` (CHADO, `public`) | `analysisfeature` + `dbxref` (db `PFAM`) | per HSP on a protein |
| **Mycocosm** | fungi | `"myco-db-{1,2,3}_mysql".<genome>` | `<genome>.proteinipr` (`domaindb='HMMPfam'`) | per domain hit |
| **Phycocosm** | algae | same myco DBs (split by portal config) | same `proteinipr` | per domain hit |
| **IMG isolates** | microbes | `"img-db-2_postgresql".img_core_v400` | `gene_pfam_families` | per gene×pfam (isolate only) |
| **IMG metagenomes** | microbial communities | `numg_hive.numg` | `gene2pfam` (35.68 B rows) | per gene×pfam (metagenome) |

Canonical key everywhere: `pfam_id = PF#####`. Phyto `accession` and Myco `domainid` are already
`PF#####`; IMG `gene_pfam_families.pfam_family` is `pfam#####` → uppercase to `PF#####`.

---

## 1. Phytozome (plants) — `plant-db-7_postgresql`, CHADO `public` schema

- **Released proteomes**: `deploy.proteome_progress WHERE released_in_phytozome=2` (`proteome_id`,
  `organism`). Direct CHADO access is `plant_chado` — **only** the `public` / `denormalized` /
  `json_export` schemas (never others; qualify `public.` explicitly since search_path defaults to chado).
- **Proteins / PFAM hits** (`phytozome_rows`): gene `feature.type_id=818` (not obsolete) → polypeptide
  via `feature_relationship.type_id=50` → transcript `type_id=349`; PFAM via `analysisfeature` on HSP
  features (`type_id=154`) joined to `dbxref`/`db` where `db.name='PFAM'`, restricted to a specific
  `analysis_set`. `rawscore`→bitscore, `significance`→evalue, `featureloc` fmin/fmax.
- **Deflines** (cascade): curated = `featureprop.type_id=39157` (rank≠2); provisional =
  `featureprop.type_id=39341` (rank=1). Curated wins.
- **Organism / URL token**: `pac_genome_worklist.accession` = proteome id; organism name from
  `organism` (genus+species); URL token = `pac_proteome_properties.organism_shortname` (a **matview**
  — invisible to Trino federation, must be read via a PG pushdown/`plant_chado` direct).
- Report URL: `phytozome-next.jgi.doe.gov/report/protein/<organism_shortname>/<protein_id>`.

## 2. Mycocosm + Phycocosm — `myco-db-{1,2,3}_mysql` + `portal-db-1_mysql`

Each **genome is its own MySQL schema** spread across `myco-db-1/2/3`. Phycocosm is not a separate DB —
it's the same genome schemas, split out by the portal config.

**Per-genome tables** (schema = the portal/db code, lowercase; URL db param = `code[0].upper()+code[1:]`):
- **`proteinipr`** — the InterProScan-style domain hits. Columns: `proteinid, length, domaindb,
  domainid, domaindesc, sfcount, sfstarts, sfends, sfscores, iprid, iprdesc, go, url, output`.
  `domaindb` ∈ {HMMPfam, SMART, TIGRFAM, SUPERFAMILY, ProSitePatterns, ProSiteProfiles, PIRSF, …}.
  **PFAM = `domaindb='HMMPfam'`**, `domainid=PF#####`. Coords/scores are comma-lists
  (`sfstarts`/`sfends`/`sfscores`) — take the first element per hit. `url`/`output` are typically empty.
- **`protein`** — `proteinid, transcriptid, name, description`. `description` is the annotator defline.
- **`genecatalog`** — the **published/filtered representative gene-model set** ("filtered models"). Its
  `url` embeds `&id=<proteinid>` and/or `&tid=<transcriptid>`. **This is how we keep only filtered
  models** (see filtering below). No `genecatalog` table ⇒ genome is skipped entirely.
- **`koginfo_*`** — `kogdefline` (defline fallback).

**Portal config** (`"portal-db-1_mysql".portal`), shared across Mycocosm + Phycocosm + others:
- `organismConfigProd` — `name` (= genome code), `parent`, `deleted`.
- `organismConfigPropertyProd` — `(organism, name, value, deleted)` key/value props. Known keys:
  `displayName`, **`isTestOrganism`** (`'1'`=test), `supersededBy`, `message`, `taxonomyId`, `phylum`,
  `version` (**genome release version** e.g. `1.0`/`2.0`/`v1.0` — NOT a Pfam version), `dbName`,
  `hmmpfamTableName`, `subCategory`, `superkingdom`, `class`, `jgiOwner`, `isWriteProtected`, etc.
- **Phyco classification**: walk the `parent` chain; membership under `fungal-program-phycocosm-genome`
  or `fungal-program-phycocosm-groups` ⇒ Phycocosm, else Mycocosm.

**No PFAM provenance/versioning is stored in these DBs**: `proteinipr` has no Pfam-release, no
InterProScan/HMMER version, no run date; no analysis/version table in the genome schema. The only
`version` is the genome release version. The provenance lives only in JGI's **pipeline history**
(Mycocosm annotation team / Igor S), out-of-band.

> **PROVENANCE (per the Mycocosm group, 2026):** the Mycocosm/Phycocosm PFAM domains were called with
> **`interproscan-5.9-50.0-P8`** — i.e. InterProScan **5.9-50.0** (InterPro data release 50.0, early
> 2015), JGI pipeline protocol **P8**. The bundled Pfam member-DB release for IPS 5.9-50.0 is **Pfam
> 27.0** (confirm against the IPS 5.9-50.0 member-DB manifest if it matters). The `P8`/`P9`… tags also
> appear in test-genome codes (e.g. `Galpa001_1_TEST_P8_3`, `..._TEST_P9_25d_1`) — those are the
> annotation **protocol** versions. So HMMPfam hits here reflect ~Pfam 27.0 / IPS 5.9-50.0, not a
> current Pfam release.

## 3. IMG — `img-db-2_postgresql` (+ `numg_hive`, GOLD)

**`img_core_v400`** (isolates + metagenome sample metadata):
- **`taxon`** — one row per IMG genome/sample. Key columns: `taxon_oid`, `taxon_display_name`,
  **`genome_type`** (only two values: `isolate` ≈199,015 / `metagenome` ≈93,065 — **no metatranscriptome
  genome_type**), **`analysis_project_type`** (the rich classifier — see below), `ncbi_taxon_id`
  (≈empty for metagenomes: only ~8 populated), `genus`/`species`, `proposal_name`, `analysis_project_id`,
  `sequencing_gold_id`, `study_gold_id`, `jgi_project_id`.
- **`analysis_project_type`** distinct values incl.: `Genome Analysis (Isolate)` 153k,
  `Metagenome Analysis` 51k, `Metagenome-Assembled Genome` 26k (MAGs), `Metatranscriptome Analysis`
  ~13.4k (**metatranscriptomes exist here even though genome_type doesn't distinguish them**),
  `Metagenome - Single Particle Sort` 13k, `Single Cell Analysis (unscreened)` 11,429 +
  `(screened)` 3,281 (**= SAGs**, filed as isolate), `Metagenome - Cell Enrichment` 5.5k, etc.
- **`gene_pfam_families`** — **isolate-only** gene→PFAM. `gene_oid, pfam_family (='pfam#####'), taxon,
  evalue, bit_score, query_start/end`. Join `gene` (`product_name`→defline, `locus_tag`) on
  `(gene_oid, taxon)`; join `pfam_family` (`ext_accession`→`name`) for the PFAM name. Metagenome taxa
  have **0 rows** here — their gene→PFAM lives only in `numg` (below).
- **`taxon_gtdbtk_lineage`** — **isolate-only** GTDB-Tk classification (164,856 rows = 82.8% of isolates).
  `gtdbtk_lineage` (full `d__…;s__…` path) + per-rank cols + `checkm_completeness/contamination`,
  `version_info` (GTDB r220). GTDB ≠ NCBI; convert via GTDB metadata `ncbi_taxid` or `taxonkit`.

**`numg_hive.numg`** (IMG metagenomes — separate Hive catalog, Parquet, **partitioned by `oid`=taxon_oid**):
- `gene2pfam` (35.68 B rows) = metagenome gene→PFAM. `scaffold_genes` (gene→contig), `phylodist-contiglin`
  (26.6 B per-contig NCBI-style lineage), `gene_product`, `ko_genes`, `scaffold_stats`, `faa`, `fna`.
  Gene→contig via `scaffold_genes` (co-partitioned by taxon). Backed up to CFS (all but `fna`) under
  `/global/cfs/cdirs/plant/xdomain_pfam/numg/` (and `faa`→`/global/cfs/cdirs/wfs_plnt/numg/faa`).

**GOLD** (environment/provenance): schema `"img-db-2_postgresql".img_gold` (embedded copy;
`gold_master_project.sequencing_strategy`, `gold_analysis_project`, `gold_master_biosample`,
`gold_master_study`, ecosystem/habitat CVs) **and** a standalone `gold-db-2_postgresql` catalog.
Link taxon→GOLD via `taxon.sequencing_gold_id`/`study_gold_id`. Note IMG `analysis_project_type` and
GOLD `sequencing_strategy` share vocabulary strings but count different populations (loaded taxa vs
GOLD projects).

---

## Filtering the extractor CURRENTLY applies (`pipeline/build_xdomain_annotation.py`)

**Phytozome**: only `released_in_phytozome=2` proteomes; only the designated PFAM `analysis_set`;
non-obsolete gene features.

**Mycocosm / Phycocosm** (genome-level + model-level):
1. Genome must have a `proteinipr` table (selection) **and** a `genecatalog` table (else skipped).
2. **Archival exclusion**: drop genomes with a `supersededBy` or `message` property in portal config.
3. **Phytozome dedup**: drop Phycocosm **Streptophyta** land-plants whose `taxonomyId` matches a released
   Phytozome proteome.
4. Phyco vs Myco routing via the portal-config parent chain.
5. `deleted=0` on all portal-config lookups.
6. **Keep only filtered models** ⇒ the **GeneCatalog join**: a protein contributes hits only if its
   `proteinid` or `transcriptid` appears in `genecatalog` (via the `&id=`/`&tid=` url params). This drops
   all-models / alternative transcripts not in the published filtered-model track.
7. `domaindb='HMMPfam'` — only Pfam member-DB hits (not SMART/TIGRFAM/etc. in the same table).

**IMG**: `taxon.genome_type='isolate'` (metagenomes excluded by design — they're the huge `numg` set);
`pfam_family 'pfam#####'`→`PF#####`.

---

## ⚑ Filtering we STILL NEED TO ADD (the gap list — keep in mind)

**Mycocosm / Phycocosm**
- [ ] **Test organisms** — exclude `organismConfigPropertyProd.isTestOrganism='1'`. Authoritative flag
  (NOT the name — `%TEST%` gives 1,277 mostly-false-positives AND misses test genomes with no "test" in
  the code). **307** genomes flagged portal-wide; **49** currently leak into the index (e.g.
  `Galpa001_1_TEST_P8_3`, `dimcr_ahpznsc`, `dirot4477_1`, `hemcrynuc1`, `olpsp1_coasm`). Confirm with the
  Mycocosm team (Igor S) that the flag is populated on every test genome (no nulls/0 on real test orgs).
  Fix = fold the flagged set into `exclude` in `myco_portal_class`.
- [ ] **Cross-portal taxonomic overlaps** beyond the current Streptophyta-vs-Phytozome dedup — e.g.
  **metazoans in Mycocosm**, and genomes that belong to another portal's system.

**IMG**
- [ ] **Non-public / obsolete / cross-portal-duplicate genomes** — a query-time exclusion index
  (`pfam_exclusions`, `PFAM_EXCLUDE_INDEX`) was a stopgap and is currently OFF; the real fix is a
  filtered rebuild that drops them at index time (the "clean index" effort). Includes off-portal IMG
  genomes (e.g. plants in IMG).
- [ ] **SAGs / single-cell not distinguished** — not necessarily a *filter*, but `analysis_project_type`
  ∈ {`Single Cell Analysis …`} (SAGs, ~14.7k) are silently mixed into the isolate set; may want to
  flag/facet or exclude.

**Phytozome**
- [ ] Gene-model fix / re-extraction (repo tasks): Phytozome gene fix; IMG `locus_tag` re-extraction
  (`protein_id` currently = `gene_oid`, should be `locus_tag`).

**Provenance (all portals)**
- No Pfam-release / InterProScan version is *stored in the DBs* — it comes from pipeline history.
  **Myco/Phyco RESOLVED**: `interproscan-5.9-50.0-P8` → ~Pfam 27.0 (see the Provenance box in §2).
- [ ] **IMG** Pfam-assignment version still unknown — get the IMG annotation pipeline's Pfam/HMMER
  version from the IMG team if version provenance matters there.

---

## Practical notes

- Extractor: `~/git/pfam-search/pipeline/build_xdomain_annotation.py` (`phytozome_rows`,
  `mycocosm_rows`, `img_rows`, `myco_portal_class`). Uses the public `trino` client directly — no
  cross-repo imports.
- The live tool serves from an **Elasticsearch index** (`pfam-es-v2`) + CFS Parquet (DuckDB), built
  offline from these sources — it is a **point-in-time snapshot**, with no live dependency on the portal
  DBs. Adding/removing a filter requires a re-extract + index rebuild (or a targeted index delete-by-query
  for an immediate purge).
- Portal DBs are MySQL (myco/portal) and PostgreSQL (plant/img); the `_mysql`/`_postgresql` suffix in the
  Trino catalog name is the backend type.
