# Homolog orthoType Guide

`orthoType` is the inparanoid ortholog-multiplicity classification on each homolog
record: `1-1`, `1-M`, `M-1`, `M-M`, or `""` (empty for non-ortholog diamond hits).
It is an **absolute requirement** of the homolog data — it was silently dropped in
the JAWS migration and had to be restored + backfilled.

## What happened (the regression)

- The OLD pipeline parser `parsers/diamond_to_homolog_json.py` REQUIRED a
  `--multiplicity-file` and set `linejson["orthoType"] = mult.get((qseqid,sseqid),"")`.
- The JAWS migration commit **12224cea (2026-03-20)** rewrote `to_json.py` from
  scratch and **omitted orthoType entirely**, leaving a TODO comment
  ("to_json.py does not yet consume it... add back when updated"). The TODO was
  never completed. `compute_multiplicity` kept producing `multiplicity_{pid}.tsv`
  every run, but generate_json discarded it.
- Every proteome run through JAWS since then had homolog records WITHOUT orthoType
  (~8.66B records across ~17,584 collections).
- Fixed 2026-06 (commit 8499fc9a): image rebuilt to
  `sha256:119ec72b2301f66ff7366bbb9f486f10910942961ffae61823338f7b65f39c28`.

## How orthoType is produced (current, fixed pipeline)

```
run_inparanoid (scatter)
  → compute_multiplicity  → multiplicity_{pid}.tsv  (gene1<TAB>gene2<TAB>orthoType)
run_diamond (scatter)     → diamond tars
  → generate_json: to_json.py --multiplicity-file multiplicity_{pid}.tsv
       sets record["orthoType"] = mult.get((qseqid, sseqid), "")
```

- `get_multiplicity_wdl.py` parses inparanoid tables and emits BOTH directions per
  ortholog group: `(geneA, geneB, mult_ab)` and `(geneB, geneA, mult_ba)`.
  For a group with `count_a` A-genes and `count_b` B-genes:
  1/1→`1-1`/`1-1`; 1/M→`1-M`/`M-1`; M/1→`M-1`/`1-M`; M/M→`M-M`/`M-M`.

## Directionality (verified — get this right)

The lookup key is **(queryIdentifier, hitIdentifier)**:
- `homologs_P_X` record: query=P-gene, hit=X-gene → key `(Pg, Xg)` → `mult_ab`
- `homologs_X_P` record: query=X-gene, hit=P-gene → key `(Xg, Pg)` → `mult_ba`

Because the multiplicity TSV emits both orderings, a SINGLE `multiplicity_{P}.tsv`
correctly covers BOTH `homologs_P_*` and `homologs_*_P`. "1-M" means: from the
query gene's perspective, one query maps to many hits.

Only ~6% of diamond-hit records are inparanoid orthologs (get a real value); the
other ~94% are `""` in the old data / absent after the Option-2 backfill.

## Backfilling existing data

Engine: `/pscratch/sd/p/phillips/inparanoid/backfill_orthotype.py`
(also see the `homolog-orthotype-backfill` skill).

Two critical correctness points learned the hard way:

1. **Use the COMPLETE multiplicity TSV, not per-run inparanoid tables.** JAWS call
   caching means a run's `call-run_inparanoid/shard-*/execution/` only holds tables
   for NON-cached pairs (cached pairs' tables live in earlier runs' dirs). The
   `multiplicity_{pid}.tsv` in `call-compute_multiplicity/execution/` is complete
   (the gather localizes every table).

2. **Use an EXACT gene→proteome map, not PAC ranges.** ~10 proteome pairs have
   OVERLAPPING PAC-id ranges (e.g. 827/828), so range-binary-search misassigns
   genes. Build an exact dict from defline files (`secondaryidentifier=PAC:<id>`).

### Backfill approach options
- **Option 1 (exact match to old):** set orthoType on EVERY record incl. `""` on
  non-orthologs. ~8.66B server writes — weeks single-thread. Avoid unless required.
- **Option 2 (chosen):** set orthoType only on the ~520M ORTHOLOG records (real
  values); leave non-orthologs without the field. Absent behaves like `""` for all
  consumers found (web service returns records as-is; dotplot reads inparanoid files
  directly, not mongo). ~16× lighter on Mongo.

### Procedure (Option 2)
```bash
# Single process, single thread, gentle on mongo (see feedback_mongo_server_protection)
cd /pscratch/sd/p/phillips/inparanoid
# in a screen, with: source ~/jaws-prod.sh && module load python/3.11-24.1.0 && conda activate chado
python3 -u backfill_orthotype.py <pid> [<pid> ...]   # or --all for the built-in cohort
```
It builds the gene→proteome map once (~1 min, ~19M genes), then for each proteome
streams `multiplicity_{pid}.tsv`, routes each `(g1,g2)` to `homologs_{prot(g1)}_{prot(g2)}`,
and bulk `UpdateOne({queryIdentifier:g1,hitIdentifier:g2},{$set:{orthoType}})`.
Idempotent. Updates are indexed on `queryIdentifier`.

### Verify after backfill
```python
# ~6-7% of a collection's records should have orthoType (the ortholog fraction)
db.homologs_<pid>_113.count_documents({"orthoType": {"$exists": True}})  # vs total
```

## Cohort that needed backfill (JAWS-run proteomes, 2026-06)
447,771,858,859,862,863,864,865,894,944,945,946,947,948,962,988,1044–1054.
(962 + 1053 done first; the other 25 via `backfill_25.log` on login32.)
