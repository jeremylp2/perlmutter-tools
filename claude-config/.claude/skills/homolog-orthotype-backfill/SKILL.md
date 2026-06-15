---
description: Backfill the orthoType field into a proteome's homolog MongoDB records from its inparanoid multiplicity TSV (for JAWS-pipeline data that predates the orthoType fix). Use when records are missing orthoType.
---

Backfill `orthoType` into homolog records that lack it. Arguments: $ARGUMENTS (one or
more proteome IDs, or "all").

**Read first**: `~/.claude/homolog-orthotype-guide.md` (the full background + correctness
points) and `~/.claude/feedback_mongo_server_protection.md` (HARD mongo limits).

## When to use
- A proteome's `homologs_*` records are missing `orthoType` (data loaded by the JAWS
  pipeline before the 2026-06 orthoType fix, image `119ec72b`).
- Confirm need: `db.homologs_<pid>_113.find_one()` has no `orthoType` key.

## Background (why this is needed)
orthoType (1-1/1-M/M-1/M-M, "" for non-orthologs) was silently dropped in the JAWS
migration (commit 12224cea). Future runs include it natively; existing data needs
backfill from each proteome's preserved `multiplicity_{pid}.tsv`.

## How to run
The engine is `/pscratch/sd/p/phillips/inparanoid/backfill_orthotype.py`.

ALWAYS run in a `screen`, single process, single thread (mongo protection):
```bash
# wrapper logs hostname first (mandatory), uses jaws-prod + module python + chado
screen -dmS orthobackfill bash -lc '
  echo "Running on $(hostname) at $(date)" > /pscratch/sd/p/phillips/inparanoid/orthobackfill.log
  cd /pscratch/sd/p/phillips/inparanoid
  module load python/3.11-24.1.0 && conda activate chado
  python3 -u backfill_orthotype.py <PIDS> >> orthobackfill.log 2>&1
  echo "Done at $(date)" >> orthobackfill.log'
```
Report the login node. It is detached and survives logout.

## What the engine does (and why, correctness-critical)
1. Builds an EXACT gene→proteome map from defline files (~19M genes, ~1 min). Do NOT
   use PAC ranges — ~10 proteome pairs have overlapping ranges.
2. For each proteome, streams the COMPLETE `multiplicity_{pid}.tsv` from the JAWS run's
   `call-compute_multiplicity/execution/` (NOT per-run inparanoid tables — JAWS call
   caching makes those incomplete).
3. Routes each `(g1,g2,orthoType)` to `homologs_{prot(g1)}_{prot(g2)}` and bulk
   `UpdateOne({queryIdentifier:g1, hitIdentifier:g2}, {$set:{orthoType}})`.
   Only ortholog records are touched (~6% of all records). Idempotent.

## Pre-launch checks
- No other backfill/load running (multi-node check; respect 5-worker / 20-thread limits).
- The proteome has a succeeded JAWS run with a `multiplicity_{pid}.tsv`.

## Verify after
```python
# ~6-7% of a collection's records should have orthoType
n = db["homologs_<pid>_113"].count_documents({"orthoType": {"$exists": True}})
t = db["homologs_<pid>_113"].estimated_document_count()   # n/t ≈ 0.06-0.07
```
Spot-check a known ortholog's value matches the multiplicity TSV.
