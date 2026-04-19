# Defline Guide

Deflines are the short human-readable descriptions of proteins (e.g., "CATION/H(+) ANTIPORTER 28", "kinase, putative") that appear in the `hitDefline` field of homolog records. They come from PostgreSQL `plant_chado` via the `json_export.pac_gene_view_callt()` function.

## Source and generation

- **Authoritative source**: PostgreSQL function `json_export.pac_gene_view_callt(proteome_id, rank)` on plant-db-7
- **Populated by**: `pipeline/get_deflines.py`
- **Written to**: `/pscratch/sd/p/phillips/inparanoid/defline/output_files/output_{pid}.tsv.gz`
- **Consumed by**: `pipeline/to_json.py` (inside the homolog-pipeline Docker image, via the deflines tarball staged by JAWS)

## Two defline columns

The defline file (and PG) has two columns. The consumer logic (in `to_json.py`'s `load_deflines`) prefers the first, falls through to the second:

| Column | Populated when |
|--------|----------------|
| `deflines` | Manually curated or computed canonical defline exists (type_id=39157, rank != 2) |
| `provisional_deflines` | Automated defline from pipeline analysis (type_id=39341, rank = 1) |

A proteome with all-provisional (no curated `deflines`) is HEALTHY — the pipeline uses provisional_deflines as fallback. Only when BOTH columns are empty does a PAC end up with empty hitDefline.

## Filter joins in `pac_gene_view_callt`

The canonical function does NOT return all PACs for a proteome. It filters to genes that have:
- `feature.type_id = 818` (gene) AND `NOT is_obsolete`
- A non-obsolete transcript (`feature_relationship` + `feature.type_id=349`)
- A scaffold location (`featureloc` + scaffold `feature.type_id=455`)
- An entry in `pac_genome_worklist` matching the proteome

So a gene without transcripts or without a scaffold location is **excluded** from the defline file even though it exists in PG. An audit that doesn't apply these same joins will produce false positives (flagging a file as stale when it's actually complete).

## Regenerating defline files

`get_deflines.py` **skips existing files by default** — rerunning won't refresh stale data. Use `--force`:

```bash
source ~/jaws-prod.sh && module load python/3.11-24.1.0
cd /pscratch/sd/p/phillips/inparanoid

python3 pipeline/get_deflines.py \
    --prots 447,771,946,947 \
    --output-dir defline/output_files \
    --force
```

Each proteome takes ~15 sec (the PG function is slow). Output is a gzipped TSV with 35 columns.

## Auditing defline completeness

`audit_deflines_fast.py` compares each defline file's content to current PG state. Flags:

| Flag | Meaning | Action |
|------|---------|--------|
| OK | File matches PG | None |
| CRITICAL | PG has non-zero PACs but 0 with any defline column populated | Upstream PG data problem — can't be fixed from our side |
| STALE | File has fewer populated rows than PG currently has | Regen with `--force` |
| MISSING | No defline file exists | Run `get_deflines.py` (no `--force` needed) |

Invocation (read-only, no writes):
```bash
python3 /pscratch/sd/p/phillips/inparanoid/audit_deflines_fast.py
```

Or via the `/homolog-audit` skill.

## Why files go stale

Observed causes during April 2026 session:
- **Bad writes**: `get_deflines.py` does `fetchall()` + write + gzip + delete-uncompressed. If any step fails partway (OOM, disk full, interrupted), the gzip is truncated. The script does **no post-write verification**.
- **PG data updated after generation**: `provisional_deflines` column gets populated over time as proteomes are analyzed. Files generated before a proteome's analysis was complete will have empty provisional columns even though PG now has them populated.

`get_deflines.py` should ideally verify the written file (re-read gzip, count rows, compare to fetchall count) — not currently implemented.

## Impact of stale deflines on homologs

When a partner's defline file is stale, `to_json.py` will write empty `hitDefline` for records pointing to that partner. This is silent — no error, no warning.

The fix is two-step:
1. Regenerate the stale defline file (`get_deflines.py --force`)
2. Rerun JAWS for any new proteome that referenced the stale partner, so its `mongoloader_*.json` files get fresh `hitDefline` data
3. Load MongoDB (drop+create, which collect_results.py does by default)

In practice, it's easier to rerun the JAWS for the proteomes whose DATA was served with stale deflines, since each JAWS run also regenerates the reverse-direction JSON for all partners.
