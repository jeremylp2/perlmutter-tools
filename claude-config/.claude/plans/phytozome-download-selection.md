# Phytozome download tool — how the files and representatives were selected

Done 2026-10-28. All work files in `$SCRATCH/dl_tool/` (= `/pscratch/sd/p/phillips/dl_tool/`). Every script there
is ad hoc (not pipeline code). Plan: [phytozome-download-tool.md](phytozome-download-tool.md).

## 1. Which genomes
- Source: the prod organism/clade tree `config/njphytozome.json` on zome-clientside `origin/production-14.1`
  (last change 4dae0334, deploy_tag `phytozome-next_20260909`). Copy: `njphytozome_prod.json`.
- 471 genomes in the tree: 433 unrestricted, 36 restricted, 2 embargoed.
- Kept: unrestricted + restricted (restricted ship with their DataReleasePolicy.html). Dropped: embargoed 930, 931.
  **469 genomes.**

## 2. Which files (JAMO inventory) — `inventory_canonical.py` → `inv_full.json`
Read-only JAMO `pagequery` per genome (`metadata.phytozome.phytozome_genome_id`). A file is kept when:
1. its `phytozome_release_id` contains `14`;
2. `metadata.portal.display_location` is non-empty (shown on the portal);
3. its name ends in a standard Phytozome suffix (allowlist from `pz_file_export/regen_strict.py`):
   assembly `.fa.gz`, softmasked/hardmasked `.fa.gz`, cds/protein/transcript `.fa.gz` (+ primaryTranscriptOnly),
   `.gene.gff3.gz`, `.gene_exons.gff3.gz` / `.gene_exon.gff3.gz`, `.repeatmasked_assembly*.gff3.gz`,
   P14 `.annotation_info.txt.gz` / `.defline.txt.gz` / `.analysis.tsv.gz` / `.analysis.xml.gz`, `.synonym.txt`,
   `.locus_transcript_name_map.txt`, `.geneName.txt`, `.description.txt`, `.readme.txt`, `DataReleasePolicy.html`;
   and its name has none of: inparanoid, `_Est_`/`_Ests_`, EstClusters, gene_atlas, `.sql.gz`;
4. duplicates with the same name tail after `_<pid>_` → newest JAMO file_date (then on-disk status);
   an uncompressed file is dropped when its `.gz` exists.

Result: 8,912 files, 469 genomes, 454.7 GB. Then each file was classed by type (`inv_full_cls.json`).

## 3. One file per type per genome — `select_canonical.py` → `selected.json`, `dropped.tsv`
JAMO's displayed v14 set often has more than one file of a type (legacy names, two assembly versions, stray files).
Rules, in order (user decisions):
1. `lowConfidence` files: not a standard type → dropped (24 files).
2. Version rule: keep the file named `_<pid>_<version>` where version = the tree's `assembly_version` for
   assembly / softmasked / hardmasked / repeatmasked, `displayVersion` for annotation types.
   If several match, the one where the version is followed directly by the type suffix
   (833: `Zm-B73-REFERENCE-NAM-5.0.fa.gz`, not `…NAM-5.0.55.fa.gz` — the 2022 files, user's choice).
3. `gene_exon` vs `gene_exons` both present → the canonical spelling `gene_exons`.
4. Repeatmasked gff3 still ambiguous → the newest file (JAMO file_date).
5. Readmes: an assembly readme and an annotation readme are both kept.
6. Legacy-only `gene_exon.gff3.gz` (95 files) → renamed `gene_exons.gff3.gz` in the downloads (`dl_name`).

Result: **8,510 files, 406.3 GB, 469 genomes**; 402 dropped, each with its reason in `dropped.tsv`.
Checks: 0 unresolved groups; no genome lost a type it had; no type has >1 file except readme pairs; no duplicate
download name within a genome.
Content check on 9 kept/dropped assembly pairs: same sequence IDs, counts and bases in 8; 801 and 880 differ
only in header text (dropped copies have empty `ID=…` / `annot-version=`) and line width (sequence md5 identical);
836 v1.1 has one extra scaffold (`scaffold_124`) — user kept v1.0 (tree's assembly_version).

Gaps in JAMO (no file to select): P14 annotation_info for 167, 790, 791, 1061; readme for 840, 841, 865, 1049,
1052, 1059, 1061, 1064, 1065; DataReleasePolicy.html for 113 genomes, of them 13 restricted
(793 794 798 799 815 816 817 819 820 821 825 826 991).

## 4. Taxid of each genome — CHADO
- Source (user): CHADO organism. Per genome, never by organism name:
  `PACProteome:<pid>` cross-ref on the genome's `peptide_collection` feature (cvterm 1608) → `organism_id` →
  `organism_dbxref` in db `Taxonomy`. Query `sql/taxid_by_proteome_v4.sql` (peptide_collection features first,
  index scans only, 3 s). Output `taxid_v4.tsv`: 469/469 genomes, exactly one taxid each, 199 taxids.
- CHADO records taxids at mixed ranks (NCBI efetch of all 199, `ncbi_taxa.xml`): 188 species, 11 below species
  (subspecies / varietas / strain / isolate / no rank), e.g. brapapan's reference 795 = 1813537
  *B. rapa* subsp. *trilocularis*, the other members 3711 *B. rapa*.
- So the tier is grouped by each taxid's **NCBI species ancestor** (user accepted). Merged ids resolved through
  NCBI AkaTaxIds (CHADO 337451 for 531 Cinnamomum kanehirae → 337465 Camphora micrantha).
  Map: `species_by_proteome.tsv`. **196 species.**

## 5. Groups used in the choice — CHADO
- Hap-resolved pairs: `grp` type `organism_haplotype` (`sql/hap_groups.sql` → `hap_groups.tsv`): 83 groups, all
  exactly 2 members and 1 reference; 32 have both members in the 469, none has only one.
- Pangenomes: `grp` type `pangenome`, reference = grpmemberprop `pangenome_reference=1`
  (`sql/pangenome_groups.sql` → `pangenome_groups.tsv`): brachypan 283, brapapan 795, cowpeapan 469,
  eucypan 993+994, pennypan 872, sorghumpan 730.

## 6. One representative per species — `species_reps.tsv` (196 species, 217 genomes)
Rules (user):
1. A species with pangenome members → the pangenome's designated reference.
2. A hap-resolved genome always comes with its pair (both haps).
3. Otherwise only one candidate → that one; else draft rule = plain "Genus species" name, newest id.
4. Groups with no plain-name genome → best **embryophyta** BUSCO (tree `busco_completeness`; same winner for
   min / max / mean of a pair): Agave 924+925, Castanea 731+732 (Nanking), Ceratodon 539, Cornus 974+975
   (Cherokee Brave), Corylus 835, Fragaria 701. Camelina sativa: user pick 898 DH55 (embryophyta tie).
Counts: 139 only candidate, 6 pangenome reference, 44 draft rule, 7 user/BUSCO.

## 7. One representative per strain — `strain_reps.tsv` (416 strains, 416 genomes)
Strain = the tree's `shortName` (each hap has its own shortName, so both haps are always in). 42 strains have
more than one genome: pangenome reference if one is in the group (Bdistachyon 283, EgrandisvarTAG0014HAP1/HAP2
993/994, Sbicolor 730, Vunguiculata 469), otherwise the newest version (highest genome id). No hap pair split.
