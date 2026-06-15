# How to Rename a Proteome in CHADO (and related databases)

This guide covers renaming an organism/proteome across all Phytozome databases. It was developed during the rename of proteome 864 (Boechera lemmonii X paupercula X retrofracta → Boechera sierraensis) in April 2026.

## Overview

A proteome rename touches **three databases** and potentially **filesystem artifacts**:

| Database | Engine | Tables affected |
|----------|--------|----------------|
| plant_chado | PostgreSQL | organism, feature, analysis, materialized views |
| PAC2_0 | MySQL | proteome, transcript |
| deploy_config_metadata | MySQL | proteome_progress |

If the proteome is deployed, you also need to update:
- njp_content / njp_content_dev (MySQL) — proteome_content
- deploy_metadata (MySQL) — deploy metadata entries
- njphytozome.json (file) — both branches

## Pre-flight checklist

1. **Identify the organism_id**: Query via PACProteome dbxref.
2. **Check if the organism_id is shared** across multiple proteomes — if so, renaming the organism affects all of them.
3. **Decide on the new feature name prefix** (e.g., `Bosie` for Boechera sierraensis). The convention is a compressed form of genus+species.
4. **Determine the old prefix** from existing feature names.
5. **Check if the proteome is deployed** — this determines how many databases need updating.
6. **Confirm the NCBI taxon ID** for the new species name, if available.

### Discovery queries

```sql
-- Find organism_id and current names for a proteome
SELECT DISTINCT o.organism_id, o.genus, o.species, o.abbreviation, o.common_name
FROM organism o
JOIN feature f ON f.organism_id = o.organism_id
JOIN feature_dbxref fd ON fd.feature_id = f.feature_id
JOIN dbxref dx ON dx.dbxref_id = fd.dbxref_id
JOIN db ON db.db_id = dx.db_id
WHERE db.name = 'PACProteome' AND dx.accession = '<PROTEOME_ID>';

-- Check current feature name prefix
SELECT DISTINCT split_part(f.name, '.', 1) as prefix, t.name as type, count(*)
FROM feature f
JOIN cvterm t ON t.cvterm_id = f.type_id
WHERE f.organism_id = <ORG_ID> AND f.is_obsolete = false
AND t.name IN ('gene','mRNA','polypeptide')
GROUP BY split_part(f.name, '.', 1), t.name;

-- Count all features by type
SELECT t.name as type, count(*)
FROM feature f
JOIN cvterm t ON t.cvterm_id = f.type_id
WHERE f.organism_id = <ORG_ID> AND f.is_obsolete = false
GROUP BY t.name ORDER BY count(*) DESC;

-- Check if organism is shared across proteomes
SELECT DISTINCT dx.accession as proteome_id
FROM feature f
JOIN feature_dbxref fd ON fd.feature_id = f.feature_id
JOIN dbxref dx ON dx.dbxref_id = fd.dbxref_id
JOIN db ON db.db_id = dx.db_id
WHERE db.name = 'PACProteome' AND f.organism_id = <ORG_ID>;

-- Check analysis records
SELECT analysis_id, name, program, sourcename
FROM analysis
WHERE name LIKE '%<OLD_ABBREVIATION>%' OR sourcename LIKE '%<OLD_ABBREVIATION>%';

-- Check dbxref provenance records (usually left as-is)
SELECT dx.dbxref_id, db.name as db_name, dx.accession, dx.version
FROM dbxref dx
JOIN db ON db.db_id = dx.db_id
WHERE dx.accession LIKE '%<OLD_NAME_FRAGMENT>%';
```

## Execution steps

### Tables that DO NOT need renaming

- **feature.uniquename** — uses PAC: identifiers, not name-based (except genome/peptide_collection)
- **Chromosome names** — typically generic (Chr01, scaffold_1, etc.)
- **feature_dbxref** — cross-references use numeric IDs
- **dbxref provenance** (FASTA/GFF_source accessions) — these record original source filenames; changing them would be historically inaccurate
- **organism_dbxref / taxonomy** — update only if you have the correct new taxon ID

### Step 1: CHADO — organism table

```sql
BEGIN;
UPDATE organism
SET species = '<NEW_SPECIES>',
    abbreviation = '<NEW_ABBREVIATION>'
WHERE organism_id = <ORG_ID>;
-- Also update genus if needed, and common_name if set
COMMIT;
```

### Step 2: CHADO — genome and peptide_collection features

These two features use the abbreviation as both `name` and `uniquename`.

```sql
BEGIN;
UPDATE feature
SET name = '<NEW_ABBREVIATION>Peptide_collection',
    uniquename = '<NEW_ABBREVIATION>Peptide_collection'
WHERE organism_id = <ORG_ID>
  AND name = '<OLD_ABBREVIATION>Peptide_collection';

UPDATE feature
SET name = '<NEW_ABBREVIATION>Genome',
    uniquename = '<NEW_ABBREVIATION>Genome'
WHERE organism_id = <ORG_ID>
  AND name = '<OLD_ABBREVIATION>Genome';
COMMIT;
```

### Step 3: CHADO — analysis table

Analysis records use the old abbreviation in `name` and `sourcename`.

```sql
BEGIN;
UPDATE analysis
SET name = '<NEW_ABBREVIATION>Peptide_collection',
    sourcename = '<NEW_ABBREVIATION>:<ANNOTATION_VERSION>'
WHERE name = '<OLD_ABBREVIATION>Peptide_collection';
COMMIT;
```

### Step 4: CHADO — bulk feature name rename

This is the largest operation. All annotation features (gene, mRNA, polypeptide, CDS, exon, intron, UTRs, match, match_part) have the old prefix in `feature.name`.

Use `REPLACE()` rather than a numeric substring offset — it's explicit and avoids off-by-one errors.

```sql
BEGIN;
-- Dry-run count
SELECT count(*) FROM feature
WHERE organism_id = <ORG_ID> AND name LIKE '<OLD_PREFIX>%';

-- Execute (can take 15-20+ minutes for ~9M rows; run in background)
UPDATE feature
SET name = REPLACE(name, '<OLD_PREFIX>', '<NEW_PREFIX>')
WHERE organism_id = <ORG_ID> AND name LIKE '<OLD_PREFIX>%';

-- Verify
SELECT name FROM feature WHERE organism_id = <ORG_ID> AND name LIKE '<NEW_PREFIX>%' LIMIT 5;
SELECT count(*) FROM feature WHERE organism_id = <ORG_ID> AND name LIKE '<OLD_PREFIX>%';
-- ^ should be 0
COMMIT;
```

### Step 5: CHADO — refresh materialized views

```sql
SELECT * FROM refresh_pac_genome_worklist();
SELECT * FROM refresh_pac_proteome_properties();
-- pac_synteny_view is a regular view (auto-updates) — refresh_pac_synteny_view() will ERROR, do not call it
REFRESH MATERIALIZED VIEW CONCURRENTLY pac_protein;  -- no function wrapper; takes several minutes
```

Verify:
```sql
SELECT organism_name, organism_abbreviation, organism_shortname, organism_portalname
FROM pac_proteome_properties WHERE proteome_id = '<PROTEOME_ID>';
-- spot-check pac_protein names
SELECT name FROM pac_protein WHERE organism_id = <ORG_ID> LIMIT 3;
```

### Step 6: PAC2_0 — proteome table

```sql
UPDATE proteome
SET name = '<NEW_GENUS> <NEW_SPECIES>',
    displayName = '<NEW_GENUS> <NEW_SPECIES>',
    description = '<NEW_GENUS> <NEW_SPECIES> annotation <ANN_VER> on assembly <ASM_VER> (IGC)'
WHERE id = <PROTEOME_ID>;
```

### Step 7: PAC2_0 — transcript table

Update each column separately with a prefix guard, using REPLACE() to avoid numeric offset errors.

```sql
UPDATE transcript
SET locusName = REPLACE(locusName, '<OLD_PREFIX>', '<NEW_PREFIX>')
WHERE proteomeId = <PROTEOME_ID> AND locusName LIKE '<OLD_PREFIX>%';

UPDATE transcript
SET transcriptName = REPLACE(transcriptName, '<OLD_PREFIX>', '<NEW_PREFIX>')
WHERE proteomeId = <PROTEOME_ID> AND transcriptName LIKE '<OLD_PREFIX>%';

UPDATE transcript
SET peptideName = REPLACE(peptideName, '<OLD_PREFIX>', '<NEW_PREFIX>')
WHERE proteomeId = <PROTEOME_ID> AND peptideName LIKE '<OLD_PREFIX>%';
```

### Step 8: deploy_config_metadata — proteome_progress

```sql
UPDATE proteome_progress
SET organism = '<NEW_GENUS> <NEW_SPECIES>',
    jbrowse_tarball_path = NULL  -- will be rebuilt
WHERE proteome_id = <PROTEOME_ID>;
```

### Step 9 (if deployed): njp_content, deploy_metadata, njphytozome.json

If the proteome has already been deployed to Phytozome:
- Update organism references in `njp_content` and `njp_content_dev`
- Update deploy_metadata entries
- Update njphytozome.json on both branches and commit

## Verification checklist

1. `SELECT genus, species, abbreviation FROM organism WHERE organism_id = <ORG_ID>`
2. `SELECT count(*) FROM feature WHERE organism_id = <ORG_ID> AND name LIKE '<NEW_PREFIX>%'` — matches total
3. `SELECT count(*) FROM feature WHERE organism_id = <ORG_ID> AND name LIKE '<OLD_PREFIX>%'` — is 0
4. `SELECT organism_name, organism_abbreviation FROM pac_proteome_properties WHERE proteome_id = '<PROTEOME_ID>'`
5. `SELECT name, displayName FROM proteome WHERE id = <PROTEOME_ID>` (PAC2_0)
6. `SELECT locusName, transcriptName FROM transcript WHERE proteomeId = <PROTEOME_ID> LIMIT 5` (PAC2_0)
7. `SELECT organism FROM proteome_progress WHERE proteome_id = <PROTEOME_ID>` (deploy_config_metadata)

## Things to rebuild after rename

- JBrowse tarball (jbrowse_tarball_path was nulled)
- BLAST databases (if blast_dbs_created was set)
- Portal files (if portal_files was set)
- Any downstream caches or search indices

## Renaming chromosome features (separate from organism/prefix rename)

Sometimes chromosomes need to be renamed independently — e.g., when a genome is loaded with accession-style names (GWHFIHF00000001.1) that should be replaced with canonical names (Chr01).

### What changes
Only `feature.name` and `feature.uniquename` on the chromosome features themselves. Child features (gene, mRNA, CDS, exon, etc.) are located on chromosomes via `featureloc.srcfeature_id` (integer FK) — they are unaffected by a chromosome name change.

### What to check before renaming
- `featureprop` values — confirm none store the old chromosome name as text
- `dbxref.accession` — confirm no cross-references use the old name
- `analysis.name` / `analysis.sourcename` — confirm no analysis records use the old name
- `pac_synteny_grps.chrom1` / `chrom2` — text columns; confirm 0 records with old name
- `pac_exon.scaffold` — text column (regular table, not matview); confirm 0 records with old name

All of these were clean for the P. patens V7 rename (2026-04-09). If a genome has been through the full portal pipeline, re-check `pac_exon` and synteny tables.

### Uniqueness constraint note
CHADO has a nominal unique constraint on `(organism_id, uniquename, type_id)` for feature, but multiple assemblies for the same organism can produce duplicate chromosome names (e.g., Chr01 appears for both old and new assemblies under organism_id=56). The constraint is not strictly enforced — do not expect it to block the rename.

### Reusable script
`~/bin/rename_chado_chromosomes.py` — takes a TSV mapping file and organism_id, runs the rename in a transaction with verification. Generate the mapping from a FASTA with OriSeqID attributes:

```bash
grep '^>' genome.fasta | awk '{
    match($0, /OriSeqID=([^ ]+)/, arr);
    print substr($1,2) "\t" arr[1]
}' > mapping.tsv

python3 ~/bin/rename_chado_chromosomes.py --organism-id <ID> --mapping mapping.tsv --dry-run
python3 ~/bin/rename_chado_chromosomes.py --organism-id <ID> --mapping mapping.tsv
```

### Downstream after chromosome rename
- **featureloc / child features**: safe — use integer srcfeature_id
- **JBrowse tarball**: needs rebuild if already built with old names
- **Portal GFF files**: needs regeneration if already generated with old names
- **BLAST databases**: needs rebuild if already built with old names (sequence names come from FASTA, not CHADO)
- **PAC2_0**: no chromosome name storage — unaffected

## Notes

- The bulk feature rename (Step 4) is the slowest step. For ~9M rows expect 15-20 minutes.
- `feature.uniquename` uses PAC: identifiers and does NOT need renaming (except genome/peptide_collection).
- Chromosome names are typically generic and don't contain the organism prefix — but sometimes a chromosome rename IS the job (see section above).
- dbxref provenance records (FASTA source, GFF source) should generally be left as-is to preserve data lineage.
- If the organism_id is shared across multiple proteomes, renaming the organism affects all of them.
- Periodic database backups exist; no need for a manual full backup before the operation.
- `pac_synteny_view` is a **regular view**, not a materialized view — calling `refresh_pac_synteny_view()` will error.
- `pac_protein` is a materialized view with feature names baked in. There is no refresh function — use `REFRESH MATERIALIZED VIEW CONCURRENTLY pac_protein` directly. It covers all proteomes and takes several minutes.
- `defline` mat view stores featureprop data (defline text), not feature names — not affected by a prefix rename. Deflines are stored on **genes**, not polypeptides.
- `metabolic_pathway` name/uniquename columns are pathway identifiers (e.g. `SULFMETII-PWY`), not feature names — not affected.
- The analysis pipeline scripts (`createAnalysis.pl`, `submitAnalysis.pl`, `parseAnalysis.pl`, `bubbleUp.pl`, `loadCrownNode.pl`) do not read any materialized views. `loadProvisionalDeflines.pl` calls `refresh_defline()` at the end of its own run, but `defline` is not affected by a prefix rename.
- When running a `psql` command with both DDL and a SELECT in the same session, the SELECT output may be swallowed if the transaction commits without outputting. Run the verification SELECT separately after the COMMIT.
