# Phytozome download tool (outside the JDP) — plan

Started 2026-10-28. Dev only for now. Work dir (ad hoc inventory): `$SCRATCH/dl_tool/`.

## Goal
1. Premade downloads served from CFS (NERSC portal `plantbox/www` → `https://portal.nersc.gov/cfs/plantbox/...`),
   three tiers, for every labeled node of the prod tree (34 clades + 2 cluster nodes, `njphytozome.json` on
   `production-14.1`):
   - **all**: every standard file of every proteome under the node
   - **strain**: one representative proteome per organism/strain (shortName; 418 strains, 42 with >1 proteome)
   - **taxid**: one representative per NCBI taxid (user helps choose; default = main reference, newest version)
2. Custom downloader: clientside route (dev only), styled/built like `/dashboard`: selection tree + file-type
   checkboxes + email → a tarball is built from the CFS files and a link is emailed.

## Decided (user, 2026-10-28)
- Per-node tarballs would duplicate data 9.1x (sum of node sizes / 471) and plantbox CFS is 97% full
  (109,560/112,640 GB, inodes 92%) → **store each proteome's files once + per-node manifests**; full node
  tarballs only through the custom builder.
- Include unrestricted + restricted (with DataReleasePolicy.html bundled); exclude embargoed (930, 931).
- UI: in zome-clientside, like the dashboard (route + scss scoped under a page class, real Chrome top bar).
  **No clientside builder exists anymore → local builds.** Node **22.23.4** only (security-patched) anywhere.
- A reasonably human-friendly API alongside the UI (user): readable resource names (tree nodes by name, proteomes
  by id or shortName, file types by plain names), plain JSON, documented (OpenAPI like the dashboard's
  `/dashboard/api/docs/`), same endpoints the page uses.
- Taxid source for the one-per-taxid tier = CHADO organism (`organism_dbxref`, db `Taxonomy`), reached per
  proteome: PACProteome:<pid> → its peptide_collection feature → organism_id
  (`$SCRATCH/dl_tool/sql/taxid_by_proteome.sql`).
- 95 legacy-only `gene_exon.gff3.gz` files are renamed `gene_exons.gff3.gz` in downloads.
- One-per-taxid tier is grouped by the NCBI **species** ancestor of each proteome's CHADO taxid (CHADO mixes ranks:
  11 of 199 taxids are subspecies/varietas/strain/isolate/no rank; brapapan members split 3711 vs 1813537).
  NCBI efetch `$SCRATCH/dl_tool/ncbi_taxa.xml`; map `species_by_proteome.tsv`. CHADO 337451 (531 Cinnamomum
  kanehirae) is now an NCBI alias of 337465 Camphora micrantha (reported to user; CHADO not changed).
- Representative choice: a pangenome's designated reference (CHADO grp type `pangenome`, grpmemberprop
  `pangenome_reference=1`) wins; a hap-resolved genome always comes with its pair (grp type `organism_haplotype`,
  83 groups, all 2 members); otherwise user picks (draft rule: plain "Genus species" name, newest id).
  Draft: `$SCRATCH/dl_tool/taxid_reps_draft.tsv` (196 species, 216 proteomes).

## Inventory (ad hoc, read-only) — `$SCRATCH/dl_tool/inventory_canonical.py`
Rules from pz_file_export regen_v2_http.py + regen_strict.py (strict '14' tag, display_location, canonical suffix
allowlist, rename-aware dedup). Run 2026-10-28 on prod tree: 469 proteomes, 8,912 files, 454.7 GB; status
RESTORED 8,539 (410.2 GB), BACKUP_COMPLETE 204 (15.2 GB), RESTORE_REGISTERED 164 (29.3 GB), PURGED 5 (proteome 500
P14 files + policy). Output `inv_full.json`, classified `inv_full_cls.json`.

## Custom tarballs (user, 2026-10-28)
Temporary: the user gets at most 24 h to download; sweep at least daily. If CFS space is short they go on a
SPIN PV instead.

## Selection rules (user, 2026-10-28) — `$SCRATCH/dl_tool/select_canonical.py` → selected.json, dropped.tsv
- Version rule (tree assembly_version / displayVersion in `_<pid>_<version>`); if several match, version followed
  directly by the type suffix (833 → the 2022 Zm-B73-REFERENCE-NAM-5.0 files).
- Ambiguous repeatmasked gff3 → newest file. lowConfidence → not a standard type, dropped.
- gene_exon vs gene_exons → canonical spelling gene_exons; legacy-only gene_exon files (95) are renamed to
  gene_exons in the downloads (`dl_name`). Readmes: assembly + annotation both kept.
- Result: 8,912 → 8,510 files (406.3 GB), 469 proteomes, 0 unresolved, no (proteome,type) lost.

## Open — need user decisions
1. **One file per type per proteome.** JAMO's displayed v14 set has >1 file of a type for many proteomes (legacy
   names, v1.0+v1.1 assemblies, stray files like `Esalsugineum_173_v1.fa.gz` under 173). Proposed rule: match
   `_<pid>_<version>` with the tree's `assembly_version` (assembly/masked/repeatmasked) or `displayVersion`
   (annotation types) → resolves 276 groups; two readmes (assembly + annotation) both kept. ~74 groups still
   ambiguous (repeatmasked 49, gene_exons 8, cds 7, protein 7, assembly/soft/hard 3) → list for user review.
2. Storage layout: individual files once (≤455 GB) + per-node/tier manifests (file list, sizes, md5, wget/curl
   script); per-proteome tarballs in addition would be ~same size again.
3. Taxid source for tier 3: JAMO `ncbi_taxon_id` is inconsistent (323/499: 4530+39947; 462/702: 4513+112509;
   795; several None) → pick authoritative source (CHADO organism?) before building tier 3.
4. 13 restricted proteomes have no DataReleasePolicy.html in JAMO: 793 794 798 799 815 816 817 819 820 821 825
   826 991. Also missing: P14 annotation_info (167, 790, 791, 1061); readme (840 841 865 1049 1052 1059 1061
   1064 1065).
5. Backend for the custom builder: service on SPIN dev (zome-webservices style, image by digest on Node 22.23.4)
   with CFS mount writing `www/.../custom/<token>.tar`, email sender, expiry cleanup. Need: how mail is sent,
   whether wwwzome (58058) can write the CFS www target.

## Existing pieces
- `www/phytozome_bundle.tar` (127 GB, 2026-03-10): NOT used by the tool; leave it alone (user 2026-10-28).
- Truncated 924 assembly (91,602,944 bytes, `gzip -t` fails) deleted from www and phillips bundles 2026-10-28
  (user); the full JAMO file (995,452,143 bytes) is copied into www by the staging run.
- 55 bundle files whose size differed from JAMO (54 gene_exons: source column phytozomev13 vs v14) are
  replaced with the JAMO versions (user: "if in doubt, jamo version").
- `plantbox/phillips/phytozome_bundle` + `plantbox/www/phytozome_bundle` (+127 GB `.tar`): only primary assembly
  + gene_exons for 447 proteomes. pscratch copy is empty dirs.
- `~/git/compgen/JAMO/fetchPhytozomeBundle.py` (untracked): `jamo fetch` + copy logic; contains an inline DB
  password → must move to config before reuse.

## Incident 2026-10-28
`www/phytozome_bundle/compgen.tar.gz` (created 16:23, compgen checkout incl. untracked files) was publicly served
(HTTP 200) and contains the inline plant-db-5 `web` password. chmod o-r at ~21:50 (now 403). Password rotation
pending (user).
