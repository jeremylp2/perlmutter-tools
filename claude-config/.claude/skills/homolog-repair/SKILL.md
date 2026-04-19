---
description: Guided repair workflow for broken homolog data — regen deflines, submit JAWS, monitor + collect
---

Guided repair of the homolog pipeline for specific proteomes. Arguments: $ARGUMENTS (expects comma-separated proteome IDs)

Read `~/.claude/homolog-pipeline-guide.md` and `~/.claude/defline-guide.md` for context.

## What this does

Repairs homolog data for the given proteomes by:
1. Regenerating their defline files from PostgreSQL (fixes stale defline issues)
2. Submitting all of them to JAWS in one batch (parallel JAWS execution)
3. Monitoring to auto-collect and load MongoDB when each completes

**This workflow is destructive** — `collect_results` drops and recreates each proteome's homolog collections during reload. All steps need explicit user approval at the time.

## Steps

Before starting, verify:
- `$ARGUMENTS` parses as a comma-separated list of integer proteome IDs
- Each is in `proteome_progress` (MySQL query)
- The pipeline lock is free (via `SELECT IS_USED_LOCK('homolog_pipeline')`)

1. **Confirm with user**: list the proteomes to be repaired and the fact that each will have ~688 MongoDB collections dropped+recreated. **Ask for explicit "yes" before proceeding.**

2. **Regenerate defline files** (needs user approval):
   ```bash
   source ~/jaws-prod.sh && module load python/3.11-24.1.0
   cd /pscratch/sd/p/phillips/inparanoid
   python3 -u pipeline/get_deflines.py --prots $ARGUMENTS \
       --output-dir defline/output_files --force
   ```
   (Takes ~15 sec per proteome.)

3. **Verify defline files** against PG (read-only, no approval needed):
   Run `audit_deflines_fast.py` for just these proteomes; confirm all show `OK`. If any still show `CRITICAL`, that proteome's upstream PG data has no deflines — remove it from the list and flag for user.

4. **Submit JAWS run** (needs user approval — holds `pipeline_lock` for hours):
   Launch in a screen session on login18 so it survives disconnections:
   ```bash
   ssh login18 "screen -dmS repair bash -l -c '
     source ~/jaws-prod.sh && module load python/3.11-24.1.0
     cd /pscratch/sd/p/phillips/inparanoid
     python3 -u pipeline/wdl/prepare_jaws.py \
       --new-prots $ARGUMENTS \
       --site dori \
       --monitor --poll-interval 300 \
       > /pscratch/sd/p/phillips/inparanoid/repair.log 2>&1
   '"
   ```
   Log: `/pscratch/sd/p/phillips/inparanoid/repair.log`. Report the login node (login18) to the user.

5. **Point user at the log** to monitor progress. Expected timing:
   - JAWS (parallel): ~1-2 hrs for all
   - Collect + MongoDB load: serialized per proteome, ~50-80 min each
   - Total wall-clock: roughly `(1-2) + N * (50-80)` minutes where N = number of proteomes

## Safety

Never:
- Drop collections directly — let `collect_results.py` do it per-file in the normal flow
- Use `--force` on `get_deflines` without confirming the user wants stale files overwritten
- Submit JAWS for a proteome whose defline audit still shows CRITICAL (no PG data)
- Proceed if pipeline_lock is held by another instance

Ask for user confirmation at each destructive step even within this guided workflow.
