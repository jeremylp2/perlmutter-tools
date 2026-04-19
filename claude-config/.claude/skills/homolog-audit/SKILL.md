---
description: Run the defline completeness audit for all released + pending-release proteomes; report CRITICAL/STALE/MISSING flags
---

Run the defline audit script. Arguments: $ARGUMENTS

Read `~/.claude/defline-guide.md` for reference on what deflines are and why they go stale.

## What this does

Runs `/pscratch/sd/p/phillips/inparanoid/audit_deflines_fast.py`, which for every proteome with `released_in_phytozome >= 1 OR to_compute > 0`:
- Queries PostgreSQL via the same joins as `pac_gene_view_callt` (counts only)
- Reads the local defline file
- Compares populated-row counts
- Flags:
  - CRITICAL: PG has 0 deflines (upstream problem)
  - STALE: file has fewer populated rows than PG
  - MISSING: no defline file exists
  - OK: file matches PG

Read-only: issues SELECT queries to PG and reads defline files. No writes, drops, or deletes.

## Steps

1. If `$ARGUMENTS` contains `--limit N`, pass it through to the script for a small test (default: audit all ~485 proteomes).

2. Launch in a screen session on login18 (takes 10-60 min depending on current PG load):
   ```bash
   ssh login18 "screen -dmS audit bash -l -c 'module load python/3.11-24.1.0 && python3 -u /pscratch/sd/p/phillips/inparanoid/audit_deflines_fast.py $ARGUMENTS > /pscratch/sd/p/phillips/inparanoid/audit_deflines_fast.log 2>&1'"
   ```

3. Monitor by tailing `/pscratch/sd/p/phillips/inparanoid/audit_deflines_fast.log`. Flags are printed as they're found (no buffering).

4. When complete, summarize the findings:
   - How many OK / CRITICAL / STALE / MISSING
   - List the CRITICAL and STALE/MISSING pids
   - Cross-reference with MySQL proteome_progress to show which are `released_in_phytozome = 2` (those most urgent to fix)

## Follow-up

For STALE or MISSING proteomes, suggest regenerating with:
```bash
python3 /pscratch/sd/p/phillips/inparanoid/pipeline/get_deflines.py \
    --prots <comma,separated> --force
```
(The `--force` flag is required to overwrite existing files.)
