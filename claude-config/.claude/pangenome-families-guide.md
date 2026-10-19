# Pangenome gene families (CHADO → Mongo family pages → browsers) guide

How Phytozome pangenome families (BrachyPan, SorghumPan, CamelinaPan, BrapaPan, PennyPan, EucyPan…) are stored,
loaded, exported and wired into the site. Read with `phytozome-chado-guide.md`, `jbrowse-guide.md`,
`deploy-config-metadata-guide.md`.

## ⛔ Safety rules (user, absolute)
- PROD CHADO = `plant_chado` @ plant-db-7; DEV = `dev_plant_chado_db` (same host). Never write prod without explicit OK for
  that exact step. Every write script proves its target first (resolved db name AND live `SELECT current_database()`).
- Perl CHADO loaders pick the DB with **`-dbconfig FILE`**. `-config` is silently ignored → falls back to `~/.chado.conf`
  = PROD. Python tools: `--chadoconf` / `$CHADOCONF` (`~/.chadoconf[.dev]`, `[chado]` section).
- Loads are ADD-ONLY and in ONE transaction (rollback on any failure). Avoid DELETE at all costs (even on dev).
- ONLY the current annotation set (`public.analysis_set` 1) anywhere; the set is a parameter with a default. 1-arg
  `json_export.pac_protein_annotation_view_call(text[])` / `pac_annotation_info_view_call(db,acc)` HARDCODE set 0 — use the
  2-/3-arg forms with the set.
- No hardcoded paths/ids/parameters: look up cvterms by (name, cv), dbs by name.
- Read-only query helper pattern: psql with `SET statement_timeout='60s'; SET default_transaction_read_only=on;`.

## CHADO representation (verified 2026-10-18)
- Family = `grp`, type `protein_cluster` (cv `group`); `grp.dbxref_id` → method dbxref in db `PACMethod`
  (accession = method id; **`description` = project name**, read by the Mongo exporter as `method_name`) + dbxrefprop
  `name` (cv `dbxref`). `grp.uniquename` = NUMERIC family id (API endpoints require numeric); `grp.name` = display name
  ("Gene Cluster Name"; e.g. GENESPACE HOG id for CamelinaPan/EucyPan).
- Members: `grpmember` type `gene_group` (cv `sequence`), rank; each member has 2 `feature_grpmember` rows: its polypeptide
  and its gene. Gene `uniquename` = `PAC:<id>` = its representative protein's uniquename.
- Member props (`group_property` cv): `member_type` ('0'), `proteome_id`, `cluster_alignment` (aligned seq, if MSAs). NO
  `msa_score` for pangenomes (only BrachyPan has it, all 0; it is meaningful only for gene_homolog groups).
- Family props: `group_size` (all), `cluster_type` (PAV class: Core/SoftCore/Shell/Cloud/Private), `cluster_hmm`,
  `cluster_tree`, `cluster_alignment`.
- Proteome set: `dbxref_relationship` (PACProteome dbxref `part_of` method dbxref), one per proteome.
- Method ids: BrachyPan 5043, SorghumPan 5679, CamelinaPan 5698, BrapaPan 5724, PennyPan 5761, EucyPan 6002 (loaded 2026-10-19 with load_pan_families.py). New ids come from
  `public.method_id_seq` (NOT `old_public.method_id_seq`, stale).
- Proteome-scoped lookups: annotation dbxref via MATERIALIZED VIEW `pac_genome_worklist` (accession = proteome id) or the
  PACProteome→GFF_source chain; never match gene names globally (names repeat across versions, e.g. 891 vs 993).

## Loading families (tools on compgen branch `family-export-python`, worktree ~/git/compgen-famexport, 2026-10-19)
- `data_wrangling/CHADOio/loaders/load_pan_families.py` — one-transaction, add-only loader: method dbxref (+description,
  name prop), grps (uniquename = after max numeric uniquename; name = input family id), group_size, cluster_type
  (--classes), members, member props, protein+gene links, proteome links; verifies all counts in-transaction; dry run
  unless `--commit`; `--expect-dbname` required. Input TSV: family_id, pac_id, proteome_id.
- Legacy `loadClusters.pl` (avoid): non-transactional, `Db::copy()` swallows COPY failures, writes empty `msa_score` rows
  when input has no 4th column (a non-numeric 4th column like `NA` suppresses them), `-nocluster_id` runs
  `MAX(to_integer(uniquename))` over all grp (≈56 GB seq scan on prod, many minutes), names = numeric id, no description.
- After loading: Families-tab table copy `generate_family_table('<method>')` (dbSetup/makeProteinFamilyTables.sql →
  `denormalized.pac_protein_family_<m>`, attached to LIST-partitioned `public.pac_protein_family`, group_class from
  cluster_type); microsynteny rows in `pac_synteny_view` (see memory reference_microsynteny_and_top_hit_rebuild.md:
  add the method id to select_body.sql's list; insert only the new proteomes when they have no rows yet).

## Mongo family pages
- Server/DB: plant-db-4 `phytozome_v14` (conf `~/.confFile` `[mongodb_genes]`); collection `family_<method>`, `_id` =
  grp.uniquename. Doc: method_id, method_name (=dbxref.description), cluster_name (=grp.name), size, membership
  {proteome: genes}, cluster_annotation {} (always), annotation_summary (TALLY of the member genes' annotations: per
  db/accession name, description, per-proteome counts), members[] (primary/secondary identifier, proteome, order =
  gene `contained_in` rank, strand, gene_deflines/symbols/synonyms, subgenome, annotation = that gene's own hits).
- Frontend (zome-clientside, prod branch production-14.1): `/report/family/<method name|id>/<id>` → Mongo doc; MSA
  (`cluster/msa`), tree (`cluster/tree`), microsynteny (`cluster/region` from pac_synteny_view).
- Exporter: `data_wrangling/CHADOio/extractors/export_family_records.py` (Python; replaces daveg's
  getChadoFamilyRecords.pl + shell loaders): `export` (read-only CHADO session, set param), `load` (NEW collection only,
  verifies ids/counts), `compare` (read-only field diff vs live), `swap` (`--confirm`; live→backup, new→live).
- Old pipeline (daveg `/global/cfs/cdirs/plantbox/daveg/CHADO_FAMILY_v13`): exported set 0 annotations; its loader moved
  JSON files >16 MB to TOO_BIG/ without loading (mongoimport 100.5.2 handles a 16.1 MB --jsonArray file fine — tested) →
  SorghumPan lost families 140078905–140079004. Its scripts contain plaintext passwords — never print them.

## Families tab wiring (njphytozome.json)
- Clade `searchNode.chado_id` comes from a `deploy_node` row (clade_id, chado_id, chado_name, proteomes) and requires
  release_metadata `inFamilies` for those proteomes; generated ONLY by `deploy_config_metadata/bin/update_njphytozome.sh
  <tag>` (wrapper, untracked) → `reportClientSideConfig.pl`. `additionalClusterNodes` are copied from the existing file,
  never generated. Never hand-edit njphytozome.json.

## Browsers (pattern = SorghumPan/PennyPan; BrachyPan has no pangenes track)
- trackList top keys: `panGenome`/`pangenome` = project, `panColors` (Core #009E73, SoftCore skyblue, Shell orange,
  Cloud black, Private peachpuff, default lightgray) + lowercase `pancolors`. Functions in IGB pod
  `/jbrowse/plugins/zomeExtras/functions.conf` (repo dsi/phytozome/zome-jbrowse): `select_pangenome_color` (Transcripts,
  mRNA `Clusterclass`), `select_pangenome_colorb` (pangenes track, gene `Clusterclass` + `jbname`),
  `select_pangenome_pie_color` (VCF `CT`), `select_transcript_label`.
- Pangenes track ("<Pan> Pangenes", `tracks/liftoffs_from_pangenome`, uncompressed NCList): merged liftoffs from all other
  genomes; gene attrs Clusterclass + jbname. Bugs to avoid: duplicate trackList entries; label function missing `return`.
- Pie track: tracks.conf `[tracks.family_pie]` VCFTabix + `PiechartPlugin/View/FeatureGlyph/PieAF`; per-genome
  bgzip+tabix VCF; INFO AF=present/N, CT=class, FN=gene:defline; FORMAT Gene:Presence per genome; ID = CHADO family id
  (link `/report/family/<Pan>/<id>`).
- GFF exporter (`exportGFFFromChado.pl`) writes clusterClass on the GENE line only; jbrowse-primary/alt styles have no
  gene line → transcript coloring needs the class on the mRNA.
