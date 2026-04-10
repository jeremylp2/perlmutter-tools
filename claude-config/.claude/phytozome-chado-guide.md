# Phytozome CHADO Schema Reference

This guide covers the non-obvious CHADO table structure, type IDs, and query patterns
for the Phytozome database as exposed in the JGI community Lakehouse
(`"plant-db-7 postgresql"`).

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

## PAC ID Handling

PAC IDs appear as both `PAC:27370627` and bare `27370627`.
Strip prefix when needed: `REPLACE(uniquename, 'PAC:', '')`

## SQL Dialect Reminders (Dremio / ANSI SQL)

- Use `CAST(x AS type)` not `::`
- Use `REGEXP_LIKE(col, pattern)` not `~`
- Double-quote identifiers with dashes: `"plant-db-7 postgresql"`
- No `array_to_json`, `json_build_object`, or `array_agg` — use Python for JSON manipulation
