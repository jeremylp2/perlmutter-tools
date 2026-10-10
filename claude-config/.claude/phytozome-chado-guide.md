# Phytozome CHADO Schema Reference

This guide covers the non-obvious CHADO table structure, type IDs, and query patterns
for the Phytozome database as exposed in the JGI community Lakehouse
(`"plant-db-7 postgresql"`).

## ⛔ NEVER select or compare by organism — ALWAYS scope by proteome

**`WHERE f.organism_id = N` is NEVER a valid scope for a proteome's features, counts,
loads, or dev-vs-prod comparisons. Scope on the PROTEOME (`PACProteome:<pac_id>`), always.**

One organism can have **many proteomes, many annotations, and even many assemblies**.
Keying on `organism_id` silently sweeps in features from *other* proteomes/assemblies of
the same organism, so counts, set-diffs, and residue/coordinate comparisons come out wrong
(inflated, mismatched, or mixing unrelated data). This is a data-integrity landmine, not a
style preference.

**Correct, org-free scope chain** (validated on PACProteome:931):

1. `PACProteome:<pac>` is a **secondary** cross-ref (`feature_dbxref`) on the annotation
   features (gene/mRNA/polypeptide) + the `peptide_collection` + the `genome` feature.
2. Those features' **primary `feature.dbxref_id`** is the `GFF_source:<file>` **annotation
   dbxref** — every annotation feature (gene/mRNA/**exon**/polypeptide/peptide_collection)
   shares it. (Note: exons do NOT get the `PACProteome` secondary xref, so scope the full
   annotation set by the primary `dbxref_id`, not by the `PACProteome` xref.)
3. The **assembly** (genome + chromosomes) is a *separate* `FASTA:<file>` dbxref, reached
   **for this proteome** only via `featureloc.srcfeature` of the proteome's own features —
   NEVER by grabbing the organism's `genome`/`chromosome` features.

```sql
-- annotation dbxref(s) for a proteome (resolve independently in each DB — ids differ):
SELECT DISTINCT f.dbxref_id
  FROM feature f
  JOIN feature_dbxref fdx ON fdx.feature_id = f.feature_id
  JOIN dbxref dx ON dx.dbxref_id = fdx.dbxref_id
  JOIN db    ON db.db_id = dx.db_id
 WHERE db.name = 'PACProteome' AND dx.accession = '<pac>' AND f.dbxref_id IS NOT NULL;
-- -> returns the FASTA (assembly) dbxref AND the GFF_source (annotation) dbxref.
-- annotation features: WHERE f.dbxref_id = <that GFF_source dbxref>
-- assembly features:   the shared dbxref of DISTINCT featureloc.srcfeature of those features
```

If that query returns **more than one** GFF_source dbxref for a proteome, that's a real
finding (multiple annotation loads) — report it, don't assume it's benign.

## Schema Layout

The analytics/pre-joined schemas are confirmed:

| Schema | Contents |
|--------|----------|
| `denormalized` | Pre-joined views: `all_partitioned_proteomes`, `pac_synteny_grps`, `pac_synteny_pairs` |
| `expression` | scRNA-seq tables: `experiment_set`, `cell`, `gene` |
| `go` | GO term annotations |
| `genetic_code` | Genetic code reference |
| `phillips` | scRNA atlas (J. Carlson): `atlas_*` tables |

The raw CHADO tables are in an unconfirmed schema. Discover it:

```sql
SHOW SCHEMAS IN "plant-db-7 postgresql";
SHOW TABLES IN "plant-db-7 postgresql".<candidate>;
-- Look for: pac_gene_expression2, feature, pac_proteome_properties
```

## Key CHADO Type IDs

These are stable CVterm IDs in the Phytozome CHADO instance:

| Entity | type_id |
|--------|---------|
| gene | 818 |
| mRNA / transcript | 349 |
| peptide / protein | 219 |
| proteome feature | 1608 |
| defline featureprop | 39157 |
| coexpression JSON | 39249 |
| cluster release | 39214 |

Always filter `feature` by `type_id` — the table holds genes, mRNAs, proteins,
and proteome entries all mixed together.

## Key CHADO Tables

### feature
The central table. Contains genes, transcripts, proteins, proteome records.
- `feature_id` — internal PK
- `uniquename` — PAC ID (e.g. `PAC:27370627`)
- `name` — short name (e.g. `Potri.001G000400.1`)
- `type_id` — distinguishes genes/mRNAs/peptides/proteomes (see type IDs above)
- `organism_id` — links to organism
- `dbxref_id` — links to external accession / proteome registry

### feature_relationship
Hierarchy: gene → transcript → protein.
- `subject_id` → child feature_id
- `object_id` → parent feature_id
- Gene is parent of transcript (object=gene, subject=transcript)
- Transcript is parent of protein (object=transcript, subject=protein)

### pac_genome_worklist
Proteome registry linking `dbxref_id + organism_id` to `phytozome_genome_id` (accession).
Use to resolve which proteome a feature belongs to:
```sql
JOIN pac_genome_worklist w ON f.dbxref_id = w.dbxref_id AND f.organism_id = w.organism_id
```

### pac_proteome_properties
One row per proteome. Key columns:
- `phytozome_genome_id` — the numeric proteome ID used in API URLs (e.g. `444`)
- `common_name`, `organism_name`, `organism_abbreviation`
- `transcript_count`, `locus_count`
- `scaffold_n50`, `contig_n50`
- `eukaryote_busco_completeness`, `embryophyte_busco_completeness`
- `data_restriction_policy`

### pac_gene_expression2
Bulk RNA-seq expression values. One row per gene × library.
- `uniquename` — PAC ID (join key to `feature.uniquename`)
- `gene_id` — same as uniquename
- `genename` — short gene name
- `value` / `defline` — gene description
- `sample_name` / `libraryname` — RNA-seq library ID
- `experiment_group` — dataset label
- `expression` — value (typically TPM or FPKM)

### featurepropjson
JSON property blobs stored per feature.
- `feature_id`, `type_id`, `value` (JSON)
- `type_id = 39249` → coexpression data

Coexpression JSON structure:
```json
[
  {
    "group_name": "Athaliana_leaf",
    "data": [
      {"name": "AT1G...", "uniquename": "PAC:...", "coexpression": 0.94, "p-value": 0.001}
    ]
  }
]
```
Threshold/count filtering must be done in Python after retrieval (not in SQL).

### pac_protein_family
Gene family / cluster membership.
- `cluster_id` — family/cluster ID
- `protein_id` → `feature.feature_id` (peptide type)
- `dbxref_id` → `dbxref` for method info

### denormalized.pac_synteny_grps
Syntenic blocks between proteome pairs.
- `uniquename` — group ID (join key to pac_synteny_pairs.grp_uniquename)
- `proteome_id1`, `organism1`, `chrom1`, `start1`, `end1`
- `proteome_id2`, `organism2`, `chrom2`, `start2`, `end2`

### denormalized.pac_synteny_pairs
Gene pairs within a syntenic block.
- `grp_uniquename` — FK to pac_synteny_grps.uniquename
- `gene1`, `gene2` — gene names (case-insensitive match with `LOWER()`)
- `start1`, `end1`, `start2`, `end2`

### expression.experiment_set
scRNA-seq experiment registry.
- `experiment_set_id` — PK
- `name` — experiment identifier used in API calls

### expression.cell
scRNA-seq cell metadata.
- `name` — cell barcode
- `cell_order` — ordering index (aligns with expression vectors)
- `ux`, `uy` — UMAP coordinates (NULL if not computed)
- `cell_type`, `treatment`, `sample`, `replicate`
- `total_expression`
- `bit_vector`, `expression_vector_gz` — compressed binary (decode in Python)

### expression.gene
Per-gene expression vectors for scRNA.
- `name` — gene name
- `experiment_set_id` — FK
- `bit_vector`, `expression_vector_gz` — gzip-compressed float array aligned to `cell.cell_order`

## Sequence storage: what the website reads is `feature_residues`

- Sequence is served through the SQL function `public.residues(feature_id)`, which only assembles the
  chunked table `feature_residues` (`string_agg(residues ORDER BY chunk)`, 100,000-char chunks;
  `CHADO::Session::Db::store_residues` writes it). The web services' `/sequence/protein/<id>` uses it.
- **Chromosomes**: sequence only in `feature_residues` (`feature.residues` is NULL for post-2023 genomes).
- **Polypeptides**: in BOTH `feature.residues` AND `feature_residues` (loadGFF.pl has copied them since
  2023-05-09). Checking only `feature.residues` proves nothing about what the site serves.
- Any loader that writes polypeptides must also write `feature_residues`. Verify with
  `public.residues(f.feature_id) = f.residues` for every polypeptide of the proteome.
- 2026-10-09: the Python `load_gff.py` skipped the table copy, so 1061-1076 served no peptide sequence
  (repaired; fixed on compgen master 782dbb10, gate `poly_residues_served` in verify_proteome_complete.py).

## CHADO load inputs: FASTA is a tracked file, GFF is REGENERATED from PAC2_0

The two load inputs come from **different sources** — a frequent source of confusion when a
dev load's GFF md5 doesn't match prod's:

| input | how the load gets it | source of truth |
|-------|----------------------|-----------------|
| **FASTA** | `getReferenceGenomeFile.pl <pac>` → looks up the **tracking data** and returns the path to the **actual archived genome file** | the tracked/archived file (identical bytes across dev/prod if tracking was cloned) |
| **GFF** | `exportGffFromPAC.pl … PAC2_0 <pac> <abbrev>_<pac>` → **regenerates** GFF text from the **PAC2_0 database** | PAC2_0 — **there is no stored/tracked GFF file at all** |

So a dev-vs-prod **GFF md5 difference is expected and usually benign**: the GFF is rebuilt
from PAC2_0 each run, and `exportGffFromPAC.pl` writes the `<abbrev>_<pac>` string into
**column 2 (the "source" field) of every feature line**. A different `<abbrev>` → every line
differs → different md5, but the gene models (IDs, coords, pacids) are identical. **Both
`load_gff.py` and `loadGFF.pl` DISCARD column 2** (it never enters CHADO), so this md5 diff
does not affect loaded data. To prove equality, compare feature-level outcomes (counts,
`featureloc` coords, polypeptide residue md5s, relationships), not the GFF file bytes.

### The three-abbreviation quirk (don't mistake it for a bug)

Three *different* abbreviation strings coexist for one organism; only one reaches loaded data:

1. **`organism.abbreviation`** (CHADO `organism` row) — e.g. `A.triloba_var._Atwood_HAP2`.
   `load_gff.py`/`loadFasta.pl` use THIS (via `resolve_organism`) for the `peptide_collection`
   and `genome`/`chromosome` **feature names**. Cloned identically dev↔prod → loaded names match.
2. **unpack_json's computed abbrev** — e.g. `Atrilobavar_AtwoodHAP2`. Computed *from the
   organism name string* by an inline python in the `unpack_json` WDL task
   (`(words[0][0] + ''.join(words[1:])).replace("'","").replace(".","_")`). Used **only** for the
   regenerated GFF's filename + column-2 label. **Discarded on load.**
3. **The GFF_source accession stored at the original prod load** — e.g. `AtrilobavarAtwoodHAP2`.
   Reflects the unpack_json code *as it was when prod loaded that proteome*. The `.`-handling
   changed over time (older: delete the `.`; now: `.`→`_`), so #2 and #3 differ across code
   versions even though the organism string is unchanged.

Bottom line: a mismatch between these abbreviations is a **code-version artifact in a discarded
GFF label**, not a loaded-data bug. Verify by checking `organism.abbreviation` and the
`peptide_collection`/`genome` feature names are identical dev↔prod (they will be if CHADO was
cloned) — using the proteome-scoped queries in the "NEVER select by organism" section above.

## PAC ID Handling

PAC IDs appear as both `PAC:27370627` and bare `27370627`.
Strip prefix when needed: `REPLACE(uniquename, 'PAC:', '')`

## SQL Dialect Reminders (Dremio / ANSI SQL)

- Use `CAST(x AS type)` not `::`
- Use `REGEXP_LIKE(col, pattern)` not `~`
- Double-quote identifiers with dashes: `"plant-db-7 postgresql"`
- No `array_to_json`, `json_build_object`, or `array_agg` — use Python for JSON manipulation
