# Phytozome proteome release checklist (dev → prod)

The complete list of what a released proteome needs, how to check each item, how to do it, and the traps.
"dev" = phytozome-dev.jgi.doe.gov (SPIN); "prod" = phytozome-next.jgi.doe.gov (IGB k3s). Detailed guides are linked
per step. Last exercised end to end: 1062/1063 Castanea dentata var. Ellis HAP1/HAP2, 2026-10-09.

## 0. Start with a read-only status audit (never assume — flags lie)

One read-only script, run in screen, covering every step below. Template:
`$SCRATCH/zc_localdev/release_1062_1063/audit.sh` (CHADO properties + `deploy.proteome_progress`, hap/pangenome grp,
properties API dev/prod, `njp_content` rows dev/prod, Recent Releases, deploy_config_metadata deploys, `njphytozome.json`
on trunk + live prod branch, JAMO files). Then verify the important flags against the real artifact
(e.g. `blast_dbs_created=2` → check the DB files on disk; the BLAST cron had never run when the flag said 2).

Source documents (e.g. a collaborator's `.docx` info page) can carry wrong ids/versions: **CHADO is correct** — confirm the
proteome id and annotation version from `pac_proteome_properties` (a MATERIALIZED VIEW) before using any of their text.

## Data products

1. **CHADO** — genome + annotation loaded, `chado_load=2`, `chado_analysis=2`; restriction (`data_restriction_policy`),
   taxon, stats, BUSCO present. (`phytozome-chado-guide.md`; renames `chado-rename-guide.md`.)
   - Common name lives in base table `organism.common_name` (shared by every proteome on that organism row — check first),
     then `SELECT * FROM refresh_pac_proteome_properties();` (~90 s). It feeds `njphytozome.json` `commonName` on the next
     regeneration.
2. **Haplotype / pangenome group** (hap-resolved pairs, pangenomes) — CHADO `grp` (type 39334 organism_haplotype /
   39366 pangenome) with both members; mirror in PAC2_0 `proteomeGrp`. Feeds the groups API (daily loader).
   (memory `reference_groups_service.md`, `pac2_pangenome_grp_scheme.md`.)
3. **JAMO portal files** — 16-file standard set per proteome: `fa.gz`, `softmasked`/`hardmasked.fa.gz`,
   `repeatmasked_assembly.gff3.gz`, `gene.gff3.gz`, `gene_exon.gff3.gz`, `cds`/`transcript`/`protein`(+`_primaryTranscriptOnly`)
   `.fa.gz`, `P14.analysis.tsv/xml.gz`, `P14.annotation_info.txt.gz`, `P14.defline.txt.gz` — **plus `readme.txt` (17)**.
   (`jamo-guide.md`.)
   - Readmes: `~/git/compgen/JAMO/generateReadmes.py` (untracked; template `conf/ftp/phytozome_readme.tmpl`). **Its
     `get_released_proteome_ids()` runs mysql with a password on the command line — never run it as-is.** Use a driver that
     replaces only that function with a fixed id list (`$SCRATCH/zc_localdev/release_1062_1063/readme_driver.py`):
     `--no-register` first, diff against a released readme (e.g. 1053's), then **chmod 664 file / 775 dir and verify with
     `stat`** (the script does not), then `--register`. Verify the JAMO record reaches `BACKUP_READY`.
   - Data-portal visibility is gated by `analysis_project.visibility`, not `portal.identifier`.
4. **MongoDB gene documents** — `phytozome_v14.genes_<pid>`, `gene_mongo_load=2`. (`chado-gene-extract-guide.md`.)
   Prod Elasticsearch `gene` index is fed DAILY on IGB from mongo for `gene_mongo_load=2` (memory `es_gene_index_generation.md`).
5. **JBrowse** — `jbrowse_tarball=2`, `jbrowse_deployed=2`. (`jbrowse-guide.md`.)
6. **BLAST databases** — three per proteome under `/global/dna/projectdirs/plant/phytozome/blastdb/blast_phytozome_spin/`:
   `Proteomes/<pid>.fullHeader.p*`, `Genomes/<pid>.n*`, `Genomes/MASKED/<pid>.n*`. Check real sequence bytes (nsq ≈ genome bp/4)
   or a `.nal/.pal` alias for multi-volume DBs (1059 once shipped as an empty 98-byte alias).
   - Built by the scrontab BLAST cron (every 4 h, 2 proteomes/run; trigger `chado_load=2 AND chado_analysis=2 AND
     (released_in_phytozome>0 OR to_compute>0) AND blast_dbs_created=0`). Code runs from the dedicated worktree
     `~/git/compgen-blast` (branch `blast-cron`) — NOT the main `~/git/compgen` checkout, which changes branches.
     Log `$SCRATCH/blast/blast_cron.log`; `--dry-run` lists what it would build; `--proteome-ids X` for one.
     Needs `use_pure=True` on mysql.connector (C ext cannot load mysql_native_password) and passwordless ssh to dtn01.
7. **BioMart** — THREE parts, never only one (memory `biomart_genome_add_procedure.md`, `biomart-guide.md`):
   a. annotation → `phytozome_mart_C` (plant-db-6): `exportFromChado.pl -type BioMart` → per-table `DELETE … WHERE
      organism_id=<pid>; LOAD DATA LOCAL INFILE`; then `restricted=0` on gene/transcript main for unrestricted orgs.
      Gene table = one row per gene, transcript table = one per transcript (they differ when there are alt transcripts — normal).
   b. genome sequence → `sequence_mart_C.sequence_phytozome__dna_chunks__main` (`-type BioMartGenome`); verify total bp ==
      `scaffold_size` and N bp == gaps (scaffold−contig). Skipping it = all-N genomic downloads.
   c. dropdown/meta-XML re-export + `load_xml_metadata.py`, then rebuild prod's registry cache on IGB (live restart — ask).
   Orthologs are a separate later load. Exports: re-export fresh, never reuse old staging. Flag `biomart_load_complete=2`.
   Templates: `$SCRATCH/biomart_others*`, `$SCRATCH/biomart_1062_1063`.

## Config / content

8. **Deployment + `njphytozome.json`** (`deploy-config-metadata-guide.md`):
   - Confirm live prod first: `curl -s https://phytozome-next.jgi.doe.gov/info/<pid> | tail -12` → deployTag, branch
     (`production-14.1` as of 2026-10), commitHash; match deployTag to `current_release` env 4 → deploy_id.
   - Clade: the smallest clade holding the proteome in the dev deploy (`deploy_clade.proteomes`), confirm it exists in the prod deploy.
   - `add_proteomes_to_deployment.py --deploy-id <live prod> --input <pid TAB clade>` (chado-env python; answers yes/no).
   - Regenerate in a **prod worktree** (`$SCRATCH/zc_prod141_wt`, updated to the prod branch tip) — **never run
     `update_njphytozome.sh` as-is**: it writes into `~/git/zome-clientside`, which may be on a feature branch. Replicate its
     steps with outputs redirected: `reportClientSideConfig.pl --tag <tag> -o <scratch>/nj.json -c node_cladecuts.cfg`,
     `jq --sort-keys`, inject `additionalClusterNodes` from the WORKTREE's current file, write the worktree's
     `config/njphytozome.json`.
   - Diff review is mandatory: +N proteomeId, **0 removed**; each clade list gains exactly the new ids; explain EVERY other
     changed line (e.g. 2026-10-09: 1049 commonName, 381 losing a wrongly-attached JGIAP xref removed from CHADO earlier).
   - Commit only that file, push the prod branch (fast-forward). Dev: the same against trunk / dev deploy (`current_release` env 2).
9. **Restriction** — `dataPolicy` in `njphytozome.json` is generated from CHADO; set CHADO first. (`restriction-guide.md`.)
   Proteomes with a reference DOI get NO vstId 8 restrictions row (1053/1054, 1059, 1061 pattern).
10. **Info pages (`njp_content.viewInfoSection`)** — write `njp_content_dev` first, verify byte-for-byte via
    `https://phytozome-dev.jgi.doe.gov/api/content/info/<pid>` (this also proves the dev content service reads the dev DB),
    user checks in browser, then copy the rows dev→prod (refuse if prod already has rows). Sections for a published hap pair:
    1 overview, 4 Sequencing/Assembly/Annotation (`<dl>` Assembly / Gene Prediction / References, as 783), 6 contacts,
    14 bare DOI, 18 related genomes (link the other haplotype). Keep the source's italics and links. (`njp_content_guide.md`.)
11. **Recent Genome Releases** (`viewProjectSection id=32`, dev + prod) — rows at the top of `<tbody>`,
    `<a href="/info/<jbrowseName>">Name vX.Y</a>`, common name, date "Mon D, YYYY" = that site's release date (prod = the day
    it goes live). Back up the HTML; assert the target row occurs once and nothing else changed.
12. **Prod front-end build — MANUAL** (memory `prod_frontend_build_igb.md`): the IGB builder does NOT pick up pushes by itself.
    `KUBECONFIG=~/.kube/zome-igb-2.yaml`, ns `igb-dev`, deployment `zome-clientsidebuilder`; check node conditions (DiskPressure)
    first; in the pod `cd /home/svc-plant/code && nohup ./build-zome-clientside.sh > /home/svc-plant/build_<date>.log 2>&1 &`
    (repo is `code/zome-clientside`; the script re-clones when behind). Wait for the PID to go Z, 0 `ERROR in|npm ERR`,
    new `dist/main-*.js` + `njphytozome.json.tgz`; then the live shell must show the new commitHash and bundle, and
    `https://phytozome-next.jgi.doe.gov/njphytozome.json.tgz` must contain the new proteomeIds.
13. **Bookkeeping** — `deploy.proteome_progress`: `released_in_phytozome` (2 = prod), `portal_files`, `org_page_finalized`,
    `biomart_load_complete`. Update only with the user's go.

## Verify live (prod and dev)

- Shell: `curl -s https://<host>/info/<pid> | tail -12` (deployTag, branch, commitHash) and `grep -o 'main-[0-9a-f]*\.js'`.
- Config: `njphytozome.json.tgz` from the site (tar) — node present, `dataPolicy`, `jbrowseName`.
- Content: `/api/content/info/<pid>` (check `html`, not just typeName presence), `/api/content/project/phytozome` (Recent Releases).
- Properties: `/api/db/properties/proteome/<pid>` (list → `[0]`).
- WebFetch is blocked and the page is client-rendered: the user checks the page visually in a browser.
