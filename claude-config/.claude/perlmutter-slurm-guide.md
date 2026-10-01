# SLURM jobs on Perlmutter — submit, monitor, and prove TRUE completion

For any agent that launches compute work on NERSC Perlmutter. Companion guides:
`salloc-screen-guide.md` (detached interactive jobs), `jaws-guide.md` (JAWS/Cromwell — a different
submission path), `es-fast-build-guide.md` (multi-node srun lessons), `pipeline-lock-guide.md`
(cross-host mutual exclusion). **dori is a separate cluster with different rules** — for dori jobs
(including submitting to dori from Perlmutter) read `~/git/dori-tools/claude-config/.claude/dori-slurm-guide.md`.

Facts marked *(verified 2026-10-01)* were checked from login09 with the command shown. Re-verify
limits with the same command before relying on them — QOS tables change.

---

## 0. The non-negotiables

1. **Overlap check before launch.** Read the recorded log(s) of earlier runs of the same work
   (`Running on <host> … PID=… JOB=…` line), then `squeue -u $USER`, and `kill -0`/`screen -ls` on the
   *recorded* login node. Anything alive → STOP. Never launch "just in case".
2. **One item first.** Run a single file/proteome/shard, time it, verify its output, then the batch.
3. **Right-size every job** from what THIS job needs (state the reasoning: cores, GB, minutes).
   Never copy `#SBATCH` lines from another job. Oversized walltime/`--exclusive` kills backfill.
4. **One writer per file.** Each task/node writes its own log and its own result file
   (`$LOGDIR/$SLURMD_NODENAME.log`, `part_$SLURM_ARRAY_TASK_ID.json`). Aggregate by reading them all
   afterwards. Never append from several processes to one file — O_APPEND is not safe on
   pscratch/CFS. Never decide success by parsing the merged `slurm-*.out` of a multi-node job.
5. **Unbuffered output**: `python3 -u`, `stdbuf -oL`, `cat(..., flush=TRUE)`. No `| tail`/`| head`.
6. **Never `pkill -f` / `pgrep -f` / `killall`.** Cancel SLURM work only with `scancel <recorded JOBID>`,
   and only after asking the user (unless it is a job you launched seconds ago that failed to start).
7. **Every controller (screen/salloc wrapper) logs `Running on $(hostname) at $(date) PID=$$` as line 1.**
   Every batch script logs `JOB=$SLURM_JOB_ID NODES=$SLURM_JOB_NODELIST` as line 1.
8. **Anything > ~60 s goes in `sbatch` or a `screen`** — the agent's own tool call times out (2 min
   default in Claude Code) and SIGTERMs whatever is in the foreground.

---

## 1. Accounts, constraint, QOS

- Account: **`-A m342`** (`sacctmgr -nP show assoc user=$USER format=account,qos`).
- **`-C cpu` is MANDATORY.** Without it `sbatch` fails with
  `Job request does not match any supported policy` (*verified 2026-10-01*:
  `sbatch --test-only -A m342 -q regular -t 1 --wrap true` → rejected; same with `-C cpu` → accepted;
  `debug` behaves the same).
- CPU node = 128 cores / 256 hardware threads; `--exclusive` gives the whole node.

| QOS (`-q`) | Max wall | Per-user limits | Use for |
|---|---|---|---|
| `debug` | 00:30:00 (use `--time=00:29:00`) | 2 running, 5 submitted | quick tests |
| `interactive` | 04:00:00 | 2 submitted | `salloc` (1–2 nodes, ≤4 h) — see `salloc-screen-guide.md` |
| `shared` | 2-00:00:00 | — | **small jobs** (a few cores/GB) on shared nodes; no `--exclusive` |
| `regular` | 2-00:00:00 | — | whole-node work (sacct records it as `regular_0`/`regular_1`) |
| `preempt` | 2-00:00:00 | — | cheaper, can be preempted (cluster PreemptMode=REQUEUE) |
| `premium` | 2-00:00:00 | 5 submitted | only with explicit user OK (charged more) |
| `cron` | 1-00:00:00 | 40 jobs | `scrontab` entries only |

(*verified 2026-10-01*: `sacctmgr -nP show qos format=name,maxwall,maxtrespu,maxjobspu,maxsubmitpu`.)
`sbatch --test-only …` validates a request and prints an estimated start **without submitting** — use
it before the real submission.

Cluster config *(verified 2026-10-01, `scontrol show config`)*: `MinJobAge=300 sec`, `KillWait=30 sec`,
`MaxArraySize=65000`, `JobRequeue=0`, `PreemptMode=REQUEUE`.

## 2. Environment

- Output, logs, temp: **`$SCRATCH`** (`/pscratch/sd/p/phillips`). **Never `/tmp`.** `$TMPDIR` is NOT node-local.
- Containers: Shifter, image by full digest only (`image@sha256:<64 hex>`), pre-pulled and READY
  (`shifterimg images | grep <short digest>`).
- `module load X && cmd` in the SAME command/script line (each agent Bash call is a fresh shell).
- Login nodes: hard 30 GiB per-user cgroup on every login node → memory-heavy work goes to a compute node.
- Many login nodes: `ps`/`screen -ls` only see the current one. The recorded log is the system of record.

## 3. Templates

**Batch job** (`job.sbatch`):
```bash
#!/bin/bash
#SBATCH -A m342
#SBATCH -C cpu
#SBATCH -q shared            # or regular/debug — right-size!
#SBATCH -c 4
#SBATCH --mem=8G
#SBATCH -t 00:45:00
#SBATCH -J myjob
#SBATCH -o /pscratch/sd/p/phillips/myjob/logs/%x_%j.out   # %x=name %j=jobid → one file per job
set -euo pipefail
OUT=/pscratch/sd/p/phillips/myjob/out_$SLURM_JOB_ID
mkdir -p "$OUT"
echo "Running on $(hostname) at $(date) PID=$$ JOB=$SLURM_JOB_ID NODES=$SLURM_JOB_NODELIST"
trap 'rc=$?; echo "rc=$rc job=$SLURM_JOB_ID end=$(date -Is)" > "$OUT/RC.tmp" && mv "$OUT/RC.tmp" "$OUT/RC"' EXIT
module load python && python3 -u /path/to/work.py --out "$OUT/result.tsv"
python3 -u /path/to/verify.py "$OUT/result.tsv"      # integrity gate: exact expected counts; exits non-zero on mismatch
echo "job=$SLURM_JOB_ID ok $(date -Is)" > "$OUT/DONE.tmp" && mv "$OUT/DONE.tmp" "$OUT/DONE"   # LAST line, only after the gate
```
The `-o` log directory must exist before `sbatch` (SLURM does not create it).

Submit and capture the ID (record it in a log/notes file, not only in the conversation):
```bash
JOB=$(sbatch --parsable job.sbatch); echo "submitted $JOB"
```
- Dependencies: `sbatch --parsable --dependency=afterok:$JOB next.sbatch` (afterok = only if exit 0).
- Arrays: `--array=0-99%20` (`%20` = max concurrent); each task writes its own `part_$SLURM_ARRAY_TASK_ID`.
- Multi-node: bash `&` runs only on the first node. Dispatch with `srun` (one task per node), never
  `srun -c 1` (pins the whole step to one core), and use `srun --kill-on-bad-exit=0` when one node's
  failure should not cancel the others. Each node writes `$LOGDIR/$SLURMD_NODENAME.log`.
- Pending job with too long a walltime: `scontrol update jobid=$JOB TimeLimit=00:20:00` (keeps the ID,
  so dependencies stay intact).

## 4. scrontab (Perlmutter cron)
- Entries run as `cron`-QOS jobs. **`REQUEUED` is their normal state between runs** — not an error;
  the `ExitCode` column is the last run's result (*observed 2026-10-01*: `run_blast_cron.sh` REQUEUED 1:0;
  `run_homolog_cron.sh` REQUEUED 0:125 with its `.batch` step OUT_OF_MEMORY).
- `scontrol release` / plain `scancel` do not work on scrontab jobs; `scancel --cron` DISABLES the entry.
  To un-stick a held entry, reinstall the scrontab (see `homolog-pipeline-guide.md` "Cron stuck held").

---

## 5. Monitoring

```bash
squeue -j $JOB -o '%i %j %T %M %l %R'            # state, elapsed, limit, reason/nodes
squeue -j $JOB --start                            # estimated start for PENDING
sacct -j $JOB -P --format=JobID,JobName%30,State,ExitCode,DerivedExitCode,Elapsed,Timelimit,MaxRSS,ReqMem,NodeList
scontrol show job $JOB                            # full detail while queued/running
```
- **A job vanishing from `squeue` says nothing about success** — finished jobs drop out after
  `MinJobAge` (300 s). Use `sacct`.
- **Perlmutter `sacct` rejects wide date ranges**: `-S 2026-08-01` (61 days back) → `Too wide of a date
  range in query`; `-S 2026-09-01` (30 days) worked (*verified 2026-10-01*). Query by `-j <id>` when you have it.
- Poll gently (minutes, not seconds) — or use the agent harness's scheduled wake-up instead of a sleep loop.
- Watch the logs, not just the state: `tail -n 50 <log>` for progress lines.
- Common PENDING reasons: `Priority`/`Resources` (wait), `QOSMaxSubmitJobPerUserLimit` (too many queued),
  `ReqNodeNotAvail` (maintenance), `DependencyNeverSatisfied` (parent failed — cancel with permission and resubmit).

---

## 6. Proving TRUE completion — the checklist

"Job finished" ≠ "work done." **All** of these must hold, with the evidence quoted in your report:

1. **SLURM accounting, including steps.**
   `sacct -j $JOB -P --format=JobID,State,ExitCode` (WITHOUT `-X`, so `.batch`/`.extern`/`.N` steps show).
   - Allocation `COMPLETED` with `ExitCode 0:0` AND every step `COMPLETED 0:0`.
   - **`ExitCode 0:0` alone proves nothing**: TIMEOUT jobs show `0:0` (*observed*: 58822663/58822664
     `TIMEOUT 0:0`, Elapsed 04:00:28 vs Timelimit 04:00:00).
   - **The allocation line can hide a failed step**: *observed* 58326316 allocation `REQUEUED` while
     `58326316.batch` was `OUT_OF_MEMORY 0:125`. Always read the step lines.
   - ExitCode is `rc:signal`. A batch script's exit status is its LAST command's — use `set -euo pipefail`
     so an earlier failure is not masked by a final `echo`.
2. **The job's own completion artifacts.** A `DONE` sentinel written as the script's last action after
   the integrity gate, and an `RC` file with `rc=0`, each created via temp file + `mv`.
   - **Check freshness**: the sentinel's job ID matches `$JOB` and its mtime is after the job's start.
     A sentinel from an earlier run means nothing (same failure mode as the stale JAWS refdata
     `.complete` in `jaws-guide.md`).
   - A **missing** RC file after the job left the queue = killed hard (SIGKILL from OOM, or after
     timeout's 30 s KillWait — no trap runs). Treat it as failure, never as "probably fine."
3. **Logs are clean.** Read the job log AND every per-node/per-task log for: `Traceback`, `Error`,
   `Killed`, `oom`, `CANCELLED`, `DUE TO TIME LIMIT`, `srun: error`, `slurmstepd: error`, non-zero `rc=`.
   For arrays: one log per task — check ALL of them, not a sample.
4. **Output integrity (the step that matters most).**
   - Every expected output exists: count of per-task/per-node files == number of tasks/inputs.
   - No leftover partial files (`*.tmp`, `*.partial`, zero-byte outputs).
   - **Exact** record counts match the independently computed expected count (input rows, `_DONE`
     totals, DB counts). No approximate counts (HLL/`cardinality`/sampling) in any comparison.
   - Content is complete: required fields populated, not just rows present.
   - Any mismatch → stop everything and find the full root cause before anything downstream runs.
5. **Downstream-consumable.** The next step can actually read it (parse it, load one record) — a
   format check, not just "file exists."
6. **Arrays / dependencies**: every array index COMPLETED
   (`sacct -j $JOB -X -n -P --format=JobID,State | grep -v COMPLETED` prints nothing), and dependent
   jobs actually ran (not `DependencyNeverSatisfied`).

Report in the form: "job 12345 COMPLETED 0:0, all 3 steps COMPLETED 0:0 (sacct); DONE written
2026-10-01T14:02 by job 12345; 0 error lines in 12 node logs; 4,812,991 rows == 4,812,991 expected."

### State / exit reference
| sacct State | Meaning | Next step |
|---|---|---|
| `COMPLETED` | exited 0 | still run checks 2–6 |
| `FAILED` | non-zero exit | read the log; fix; rerun one item first |
| `TIMEOUT` | hit walltime (ExitCode can read 0:0) | find where it stopped; resize or make it resumable |
| `OUT_OF_MEMORY` | cgroup OOM (often only on the step line) | `MaxRSS` vs `ReqMem`; raise `--mem` with reasoning |
| `CANCELLED by <uid>` | someone scancel'd it | find out who/why before rerunning |
| `NODE_FAIL` / `PREEMPTED` | system cause | check partial outputs — never assume nothing was written |
| `REQUEUED` | requeued (normal for scrontab jobs) | look at ExitCode + step lines |

Exit 137 = SIGKILL (often OOM), 143 = SIGTERM (timeout/cancel), 127 = command not found.

---

## 7. Before you rerun anything
- Find the cause first (log, sacct steps, outputs). Never "relaunch just in case."
- Check for partial outputs from the failed run. **Never write into a partitioned/bucketed output dir
  that is not verified empty** — use a fresh output directory per run and swap on success.
- Confirm the previous job is really gone (`sacct` final state, `squeue -j` empty) before relaunching,
  so two runs never write the same files.
