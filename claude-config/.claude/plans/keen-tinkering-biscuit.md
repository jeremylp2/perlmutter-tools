# Rename Proteome 864: Boechera sierraensis

## Context

Proteome 864 is currently registered as *Boechera lemmonii X paupercula X retrofracta var. Yosemite 224299* (organism_id 596). It needs to be renamed to *Boechera sierraensis* with feature name prefix `Bosie` (replacing `BolemXpauXret`). The proteome is not yet deployed, so njp_content and deploy_metadata are not affected. Dbxref provenance records (FASTA/GFF source filenames) will be left as-is. Taxonomy cross-reference stays at taxon 93889 for now.

## Summary of changes

| Database | Table | What changes | Row count |
|----------|-------|-------------|-----------|
| **plant_chado** (PostgreSQL) | `organism` | species, abbreviation | 1 row (organism_id=596) |
| | `feature` (genome) | name + uniquename | 1 row |
| | `feature` (peptide_collection) | name + uniquename | 1 row |
| | `feature` (gene) | name | 79,354 rows |
| | `feature` (mRNA) | name | 126,078 rows |
| | `feature` (polypeptide) | name | 126,078 rows |
| | `feature` (CDS) | name | 126,078 rows |
| | `feature` (exon) | name | 801,430 rows |
| | `feature` (intron) | name | 675,352 rows |
| | `feature` (five_prime_UTR) | name | 112,898 rows |
| | `feature` (three_prime_UTR) | name | 113,665 rows |
| | `feature` (match) | name | 2,836,646 rows |
| | `feature` (match_part) | name | 3,872,748 rows |
| | `analysis` | name + sourcename | 7 rows |
| | materialized views | refresh after above | — |
| **PAC2_0** (MySQL) | `proteome` | name, displayName, description | 1 row (id=864) |
| | `transcript` | locusName, transcriptName, peptideName | 126,078 rows |
| **deploy_config_metadata** (MySQL) | `proteome_progress` | organism, jbrowse_tarball_path | 1 row |

### Not changed (intentionally)
- `dbxref` accessions (FASTA/GFF_source) — provenance records of original filenames
- `organism_dbxref` / taxonomy link — stays at taxon 93889 until correct sierraensis taxon ID is known
- `feature.uniquename` — uses PAC: identifiers, not name-based (except genome/peptide_collection)
- Chromosome names — already generic (`Chr01L`, `Chr02P`, etc.)
- njp_content / njp_content_dev — proteome not deployed
- deploy_metadata — proteome not deployed
- JBrowse tarball file on disk — will be rebuilt later
- PAC2_0 `proteome.taxId` (currently 2034904) — leave until correct taxon known

## Execution steps

All SQL will be run inside transactions so we can roll back on error.

### Step 1: CHADO — organism table

```sql
BEGIN;

UPDATE organism
SET species = 'sierraensis',
    abbreviation = 'B.sierraensis'
WHERE organism_id = 596;

-- Verify
SELECT organism_id, genus, species, abbreviation FROM organism WHERE organism_id = 596;
COMMIT;
```

### Step 2: CHADO — genome and peptide_collection features

```sql
BEGIN;

UPDATE feature
SET name = 'B.sierraensisPeptide_collection',
    uniquename = 'B.sierraensisPeptide_collection'
WHERE organism_id = 596
  AND name = 'B.lemmonii_X_paupercula_X_retrofracta_var._Yosemite_224299Peptide_collection';

UPDATE feature
SET name = 'B.sierraensisGenome',
    uniquename = 'B.sierraensisGenome'
WHERE organism_id = 596
  AND name = 'B.lemmonii_X_paupercula_X_retrofracta_var._Yosemite_224299Genome';

-- Verify
SELECT name, uniquename FROM feature
WHERE organism_id = 596 AND type_id IN (
  SELECT cvterm_id FROM cvterm WHERE name IN ('genome','peptide_collection')
);
COMMIT;
```

### Step 3: CHADO — analysis table

```sql
BEGIN;

UPDATE analysis
SET name = 'B.sierraensisPeptide_collection',
    sourcename = 'B.sierraensis:v3.1'
WHERE name = 'B.lemmonii_X_paupercula_X_retrofracta_var._Yosemite_224299Peptide_collection';

-- Verify (should be 7 rows)
SELECT analysis_id, name, program, sourcename FROM analysis
WHERE name LIKE '%sierraensis%';
COMMIT;
```

### Step 4: CHADO — bulk feature name rename (~8.87M rows)

Replace prefix `BolemXpauXret` (13 chars) with `Bosie` (5 chars) in `feature.name`.

```sql
BEGIN;

-- Dry-run count
SELECT count(*) FROM feature
WHERE organism_id = 596 AND name LIKE 'BolemXpauXret%';

-- Execute
UPDATE feature
SET name = 'Bosie' || substring(name from 14)
WHERE organism_id = 596 AND name LIKE 'BolemXpauXret%';

-- Verify samples
SELECT name FROM feature WHERE organism_id = 596 AND name LIKE 'Bosie%' LIMIT 5;

-- Confirm zero stragglers
SELECT count(*) FROM feature WHERE organism_id = 596 AND name LIKE 'BolemXpauXret%';

COMMIT;
```

### Step 5: CHADO — refresh materialized views

```sql
SELECT * FROM refresh_pac_genome_worklist();
SELECT * FROM refresh_pac_proteome_properties();
SELECT * FROM refresh_pac_synteny_view();
```

Verify:
```sql
SELECT organism_name, organism_abbreviation, organism_shortname
FROM pac_proteome_properties WHERE proteome_id = '864';
```

### Step 6: PAC2_0 — proteome table

```sql
UPDATE proteome
SET name = 'Boechera sierraensis',
    displayName = 'Boechera sierraensis',
    description = 'Boechera sierraensis annotation v3.1 on assembly v3.0 (IGC)'
WHERE id = 864;
```

### Step 7: PAC2_0 — transcript table (126,078 rows)

```sql
UPDATE transcript
SET locusName = CONCAT('Bosie', SUBSTRING(locusName, 14)),
    transcriptName = CONCAT('Bosie', SUBSTRING(transcriptName, 14)),
    peptideName = CONCAT('Bosie', SUBSTRING(peptideName, 14))
WHERE proteomeId = 864;

-- Verify
SELECT locusName, transcriptName, peptideName FROM transcript
WHERE proteomeId = 864 ORDER BY transcriptName LIMIT 5;
```

### Step 8: deploy_config_metadata — proteome_progress

```sql
UPDATE proteome_progress
SET organism = 'Boechera sierraensis',
    jbrowse_tarball_path = NULL
WHERE proteome_id = 864;
```

## Verification checklist

1. **CHADO organism**: `SELECT genus, species, abbreviation FROM organism WHERE organism_id = 596`
2. **CHADO features**: `SELECT count(*) FROM feature WHERE organism_id = 596 AND name LIKE 'Bosie%'` — should match total feature count
3. **CHADO no stragglers**: `SELECT count(*) FROM feature WHERE organism_id = 596 AND name LIKE 'BolemXpauXret%'` — should be 0
4. **CHADO mat views**: `SELECT organism_name, organism_abbreviation FROM pac_proteome_properties WHERE proteome_id = '864'`
5. **PAC2_0 proteome**: `SELECT name, displayName FROM proteome WHERE id = 864`
6. **PAC2_0 transcripts**: `SELECT locusName, transcriptName FROM transcript WHERE proteomeId = 864 LIMIT 5`
7. **deploy_config_metadata**: `SELECT organism FROM proteome_progress WHERE proteome_id = 864`

## Post-execution: Write rename guide

After completing, write a reusable guide to `~/gh/perlmutter-tools/claude-config/.claude/chado-rename-guide.md` documenting the general procedure for renaming any proteome, covering all tables/views identified here. Stow it into place.
