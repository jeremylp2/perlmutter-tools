# BioMart guide (phytozome_mart_C + ortholog load)

The live BioMart behind the Phytozome V14 "Genomes and Families" frontend.

**Host `plant-db-6.jgi.lbl.gov`, DB `phytozome_mart_C`** — this is the ONLY live mart.
Credentials: `~/.confFile` `[deploy_config_metadata]` (the same account works on plant-db-5 and plant-db-6). Read via `configparser`/`ConfigReader`; never inline a password. groovy/CLI tools take `-p <pw>` — pass it from a config read, not a literal.

Do NOT use these for live-frontend questions: `phytozome_mart_A`/`_B` (staging/legacy, stale XML), `phytozome_mart_TEST`, the `phytozome_mart_archive*` variants (one dataset PER organism, ~810 in archive_14), `sequence_mart_*`, `phytozome_diversity_mart`.

## Datasets

`phytozome_mart_C` has **8 datasets** in `meta_conf__dataset__main`: `phytozome` (V14 Genomes, id_key 86), `phytozome_structure` (87), `phytozome_clusters` (61), and the pan-family ones (`sorghumpan_clusters`, `brapapan_clusters`, `camelinapan_clusters`, `brachypan_clusters`, `pennypan_clusters`). The user-visible label comes from `meta_conf__dataset__main.display_name` (the inner XML's `displayName="Phytozome V13 Genomes"` is stale and ignored).
Per-organism datasets (`<short>_<pid>`) are NOT in `meta_conf__dataset__main` — they only exist in archive marts and as cached server templates (see "dropdown gap" below).

## Key data tables (phytozome dataset, InnoDB unless noted)

- `phytozome__gene__main` (one row/gene: `gene_id_key, organism_id, restricted, organism_name, gene_name, chr_name, …, has_*_bool`), `phytozome__transcript__main`
- functional `*_dm`: `phytozome__{defline,go,interpro,pfam,panther,kegg,kog,enzyme,pathway,synonyms,gene3d,smart,ssf,prodom,profile,uniprot}__dm`
- `phytozome__expression__dm`, `phytozome__coexpression__dm` (coexpression has NO `organism_id` — key by gene_id_key)
- `phytozome__ortholog__dm` — **MERGE/MRG_MYISAM** table over `phytozome__ortholog__dm_NNNN` MyISAM partitions (UNION clause)

Check an org has data: `SELECT organism_id, COUNT(*) FROM phytozome__gene__main WHERE organism_id IN (...) GROUP BY organism_id;` (repeat across transcript/go/pfam/… for completeness).

## Meta / XML tables

- `meta_conf__dataset__main`, `meta_conf__interface__dm`, `meta_conf__user__dm`, `meta_version__version__main`, `meta_template__template__main`
- `meta_conf__xml__dm`: `dataset_id_key, xml (longblob), compressed_xml (longblob, gzip), message_digest (MD5)` — `xml` and `compressed_xml` hold the SAME content; compressed is gzip.
- `meta_template__xml__dm`: `template, compressed_xml` (gzip, no raw column).
- **Both compressed_xml are gzip** (`1f 8b 08`), NOT MySQL `COMPRESS()` — decompress in Python `gzip.GzipFile(fileobj=io.BytesIO(blob)).read()`; do NOT use SQL `UNCOMPRESS()`.
- `mysql.connector` returns BLOBs as `bytes`/`bytearray` — decode/handle accordingly.

### Editing dataset XML
Editor → file → `insertConfXML.groovy <db> <dataset> <file>` (writes `meta_conf__xml__dm.xml`) → `finishXML.groovy <db>` (populates `compressed_xml` + `message_digest` from `xml`). Both groovy scripts in `~/git/zome-biomart/biomart-builders/`. The `phytozome` dataset's organism `<Option>` list (inside the `internalName="organism_id"` FilterDescription) is alphabetically sorted by displayName.

## Build / load scripts (~/git/zome-biomart/biomart-builders/)

- `BioMart.cfg` — `[Genomes]` has `dbhost`/`dbname`, `args=` (comma-sep proteome IDs to process), `restricted_orgs=`. Used by buildBioMart.py and the ortholog pipeline.
- `buildBioMart.py` — top-level genome pipeline (extract from chado → load → register).
- `insertDataSet.groovy -N <short>_<pid> -D '<display>' -d <data_dir> -s <seq_file>` / `removeDataSet.groovy` / `renameDataSet.groovy`
- `generateArchiveDatasets.py`, `generateBioMartArchiveCommand.sh`, `insertBioMartArchive.sh` — archive marts (target `phytozome_mart_archive*`, NOT mart_C)

## Ortholog (homolog) load — orthologPipeline.py

`~/git/zome-biomart/biomart-builders/orthologPipeline.py` — resume-safe (done-file + `.state.json`). Companion: `ortholog_pipeline_guide.md` in the repo. Stages: `precheck, extract, forcedelete, partition, disablekeys, load, enablekeys, record, merge, verify`.

Layout: `phytozome__ortholog__dm` (MERGE) over `phytozome__ortholog__dm_NNNN` MyISAM partitions (~250-300M rows each); `loaded_ortholog_pairs` (`organism_id, ortholog_organism_id, cnt`) tracking table.

Pair-file location tables in **`deploy_config_metadata`** (plant-db-5): `diamondparanoid_loc` (current, DIAMOND) and `inparanoid_loc` (legacy) — `(proteome_a, proteome_b, path)`. The pipeline checks **diamondparanoid_loc first, inparanoid_loc as fallback**.

Run (wrapper template), credentials from env/config not literals:
```bash
conda run --no-capture-output -n chado python3 -u prepareBioMartOrthologs.py \
    -c BioMart.cfg -u "$DB_USER" -p "$DB_PASS" --diamond --threads 8 -v 2>&1 | tee -a "$LOG"
```
Critical flags/gotchas:
- **`conda run --no-capture-output`** — without it, output is buffered until the subprocess exits (see `feedback_conda_run_buffering.md`); `python3 -u` for unbuffered.
- **Don't set `connection_timeout` on mysql.connector** for ENABLE KEYS / multi-hour ALTERs — it becomes a socket read timeout and breaks mid-rebuild.
- **Never DISABLE KEYS on a partition already in the live UNION** — forces user queries to table-scan; the pipeline checks UNION membership first.
- `isinstance(x, (bytes, bytearray))` everywhere (chado conda env's connector returns bytearray).
- `stage_record` dedupes `loaded_ortholog_pairs` via `INSERT … SELECT DISTINCT` swap (no unique constraint exists; dupes can recur if `record` runs twice).
- BrachyPan org IDs (283, 326-381) are hard-excluded from pair computation.
- Verify: `verifyBioMartOrthologs.py -c BioMart.cfg -u … -p … <pids>` → `checked_ortholog_pairs.tsv`.

## Known gap: genome loaded but org missing from the frontend dropdown

A proteome can have data in `phytozome__*` tables AND appear in the `phytozome` XML organism Options, yet NOT show in the BioMart filter dropdown. Cause: the build's per-organism dataset enumeration (the `<short>_<pid>` datasets, ~635 of them) didn't include it — these come from a registry the live `meta_conf__dataset__main` (only 8 rows) doesn't hold. Adding XML Options does NOT fix it; JAMO portal tags are unrelated.
- The deployed BioMart Perl server runs in a **Rancher container**; the live template cache location is inside the container (NOT `~/biomart-perl/conf/templates/cached/` — that was a wrong guess). The build iteration is in `~/git/zome-biomart-perl/lib/BioMart/Web/TemplateBuilder.pm` (~L258), datasets from `getAllDataSetsByDatabaseName(...)`.
- **This registration step is unresolved** — ask the user which script registers per-organism datasets in the LIVE mart (vs the archive mart pipeline) before attempting a fix.
