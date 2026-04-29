# Global Claude Code Notes

## ABSOLUTE RULE: All guides, skills, and scripts go in the stow repo

**Never write `.md` files, skills (`SKILL.md`), or scripts (`.sh`, `.R`, `.py`) directly to `~/.claude/`.** Those files are symlinks managed by GNU Stow. The source of truth is `~/gh/perlmutter-tools/`.

- **Guides and CLAUDE.md**: Write to `~/gh/perlmutter-tools/claude-config/.claude/`
- **Skills**: Write to `~/gh/perlmutter-tools/claude-config/.claude/skills/<skill-name>/SKILL.md`
- **After creating/editing**: Run `cd ~/gh/perlmutter-tools && ~/local/bin/stow -t ~ claude-config` to update symlinks
- **After Claude creates a new file in `~/.claude/` that should be in the repo**: Run `cd ~/gh/perlmutter-tools && ~/local/bin/stow --adopt -t ~ claude-config` to pull it into the repo
- A PreToolUse hook enforces this — writes to `~/.claude/*.md`, `~/.claude/skills/`, etc. will be blocked

## After modifying njp_content: verify on the live page

After any change to `njp_content` or `njp_content_dev`, always fetch the live page to verify the result looks correct before reporting done:
- `https://phytozome-next.jgi.doe.gov/info/{proteome_id}` — this is a public page (no login required), but WebFetch returns 403 because LBL/JGI security blocks requests from Anthropic's servers. Always ask the user to verify the page directly in their browser instead. The numeric proteome ID redirects to the full species name URL, which is convenient.
- Check that the affected text renders correctly — no literal `\n`, no garbled HTML, no missing sections.
- Do this for at least one representative proteome per batch of changes.

## ABSOLUTE RULE: Never pass credentials on the command line

**Passwords and secrets must NEVER appear as plain-text command-line arguments.** They are visible in `ps`, shell history, and process listings.

- **MySQL**: ALWAYS use a login path (`mysql_config_editor`) or `~/.my.cnf`. NEVER use `--password=secret` or `-psecret`. The `[njp_content]`, `[plant_chado]`, etc. sections in `~/.confFile` describe the connection; use `mysql_config_editor set` to store credentials securely, then invoke `mysql --login-path=<name>`.
- **PostgreSQL**: credentials go in `~/.pgpass` (already configured). NEVER pass `-W` with a literal password.
- **Any other tool**: use environment variables, config files, or secret managers — never inline secrets in the command.
- This rule applies to all commands Claude runs directly, generates for scripts, or suggests to the user.

## ABSOLUTE RULE: Never commit credentials to git

**THIS IS THE SINGLE MOST IMPORTANT RULE. VIOLATING IT IS A SECURITY INCIDENT.**

**Committing credentials (passwords, tokens, API keys, secrets of any kind) to git is strictly forbidden in all cases, without exception.**
- **NEVER** hardcode credentials in any file that is or could be committed to a repository.
- **NEVER** copy credentials from config files into source code, even temporarily, even "just to test."
- **NEVER** use string literals for passwords, tokens, or secrets anywhere in committed code.
- Always use config files (e.g. `~/.confFile`, `~/.pgpass`), environment variables, or secret managers.
- When writing code that connects to a database: ALWAYS use `db_utils.ConfFile` or equivalent config file reader. NEVER inline the credentials.
- **Before every `git add` or `git commit`**: mentally verify that NO file being staged contains credentials of any kind. If in doubt, `grep` for passwords.
- If credentials are accidentally committed, immediately rewrite history (`git reset`, then `git push --force`) to remove them from all commits before anything else. Then rotate the exposed credentials.
- This applies to ALL repositories, ALL branches, ALL file types.

## ABSOLUTE RULE: Never assume data loss is negligible

**Never silently discard, coerce to NA, or lossy-convert data without asking the user first.** This applies to all data transformations, format conversions, and ETL operations.
- If a conversion step would lose information (even for a single cell, row, or record), stop and ask.
- If values can be preserved with a different approach (e.g., taking the identical value instead of joining and coercing to NA), use that approach.
- "Only N records are affected" is never a justification for silent data loss. Scientific data integrity requires explicit decisions about every value.
- When handling edge cases (ties, nulls, mixed types), always preserve the maximum information and document what was done.

## ABSOLUTE RULE: Empirical data and facts only — never assume, never guess

**Never make assumptions. Always investigate. Every claim about the state of a file, process, database, run, config, history, or any other determinable thing must be backed by empirical data gathered right now — not memory, not intuition, not "it was like that last time."**
- Forbidden words and phrases when discussing things that can be determined factually: "probably", "should be", "must be", "likely", "I think", "I believe", "presumably", "seems like", "appears to be", "I'd guess", "my guess is".
- Before stating any fact about the system: run the command, read the file, query the DB. State what you actually observed, then draw the conclusion.
- Before modifying anything (memory, code, config, data) based on a belief: VERIFY the belief is true first. If you catch yourself about to edit something because "I think X is outdated", stop — check X first.
- If data is incomplete or a lookup returns fewer results than expected (e.g. `r[0]` from an API), check the ordering and scope before drawing conclusions. One result is not "the only result."
- When you cannot determine something factually (rare): say so explicitly — "I don't know and cannot determine it from here" — rather than guess.
- This rule applies to every statement in every response, not just failure diagnosis or destructive actions. Hedged language in a routine status report is just as forbidden as in a postmortem.

## ABSOLUTE RULE: Investigate — never assume — when anything dies, hangs, or misbehaves

**When a process dies, hangs, produces no output, or behaves unexpectedly, STOP and investigate before retrying.** Never use "probably" to explain what happened in a deterministic system — that is an assumption, not a diagnosis.
- Read the actual log. Check actual exit codes. Check file sizes/mtimes.
- Check for the process on every possible login node (on Perlmutter there are many); finding nothing on one node does NOT mean the process is dead.
- Check Claude Code's own task list for background tasks — task completion notifications indicate whether a background command finished.
- Only after the actual cause is known, decide on the next action. Relaunching "just in case" is forbidden — it can produce duplicates (see overlapping-processes rule).
- "Probably killed by timeout" / "probably crashed" / "probably done" are not acceptable explanations. Replace with: "I checked X and saw Y, which means Z."

## ABSOLUTE RULE: Test long-running work on ONE example before running the full batch

**Before launching any pipeline, data load, or long-running script, run it on a single item (one file, one proteome, one record, one row) and verify the output is correct.**
- Time the single-item run to estimate total runtime.
- Verify the single-item output against expectations — not just "the command completed" but "the result is what we expected and can be consumed by the next step."
- Only after a small-scale success should you commit to the full run.
- This applies every time you introduce a new code path: a new SQL query, a new library call, a new config format, a new subprocess invocation, a new transformation.
- Committing ~hours of compute before a 30-second single-example test is reckless. Small tests fail cheaply; full-batch failures waste enormous time.

## ABSOLUTE RULE: Check data integrity at every pipeline step

**After every step that produces a data product (defline file, JSON file, MongoDB collection, table row), verify its integrity immediately before the next step runs.**
- Expected number of items (and compare against authoritative source when possible).
- Expected fields populated — not just "existence" or "nonzero count" but content completeness (e.g., defline strings actually present, not just PAC ids present).
- Sample records match expectations (field ranges, cross-referential sanity).
- Integrity checks should be part of the routine pipeline — not something added only when the user complains about bad data.
- Whenever code that produces data is changed, rerun integrity checks — a fix in one place can silently break another.
- "Mongoimport exit 0" / "json.load worked" / "file has nonzero bytes" are NOT integrity checks; they are weakest-possible existence checks.

## ABSOLUTE RULE: Check for duplicate/overlapping processes BEFORE launching

**Before launching any process — foreground, background, or screen session — check that no existing instance of the same work is already running.**
- `screen -ls` on every potentially-relevant login node (Perlmutter has many — one node's listing is not authoritative).
- `pgrep` / `ps` for the script/command name across login nodes.
- Claude Code's own background task list (task completion notifications indicate a running task).
- If ANY matching process is found, STOP. Do NOT launch another. Either wait for it to finish, or kill it first (with user permission per the destructive-action rule).
- Running the same work twice is always wasteful and can corrupt data when both processes write to the same files/collections/tables.
- When a process appears dead, verify across all nodes before concluding — see the investigate-never-assume rule.

## ABSOLUTE RULE: Progress and error output MUST be unbuffered

**Long-running scripts must emit progress and findings AS THEY HAPPEN, not at the end — otherwise a crash loses everything you've learned.**
- Python: use `python3 -u`, or in the script `sys.stdout.reconfigure(line_buffering=True)` and the same for stderr. Do not rely on the default buffering.
- Never pipe unbuffered output through `tail`, `head`, `less`, `cat | ...` or similar at the end of the pipeline — these buffer their stdin until EOF and defeat unbuffered output. Write directly to a log file instead.
- Accumulating findings in a list for "print at the end of the run" is forbidden — if the process crashes, the list evaporates. Print each finding immediately with enough context to act on it. Lists are OK only for final summary totals.
- Error streams (stderr) must ALSO be unbuffered — an error that surfaces only after the run completes is useless during debugging.
- This applies especially to control/head-node scripts whose output is monitored live. (Intermediate pipeline scripts running inside JAWS/Cromwell/SLURM tasks typically have their output collected by the task runner; unbuffering is less critical there.)

## Perlmutter / Shifter

**If the user asks you to do anything involving JAWS, read `~/.claude/jaws-guide.md` before proceeding.**

**If the user asks you to do anything involving njp_content (info pages, restriction text, publications, recent genome releases, viewProjectSection), read `~/.claude/njp_content_guide.md` before proceeding.**

**If the user asks you to do anything involving MongoDB, homolog databases, or connecting to mongo, read `~/.claude/mongo-guide.md` before proceeding.**

**If the user asks you to do anything involving podman or Docker image builds on Perlmutter, read `~/.claude/podman-perlmutter-guide.md` before proceeding.**

**ALL podman build/push commands on Perlmutter MUST be prefixed with `TMPDIR=/run/user/$(id -u)`.**
- Lustre (pscratch) blocks mount namespace operations — every `RUN` step fails without this.
- `TMPDIR=/run/user/$(id -u) podman build -t <image>:<tag> .`
- `TMPDIR=/run/user/$(id -u) podman push <image>:<tag>`
- Get digest after push: use the curl+python3 method in `~/.claude/podman-perlmutter-guide.md`
- Pull into Shifter by digest (NEVER by tag): `shifterimg pull <image>@sha256:<64-char-hex-digest>`
- Docker Hub login: `echo "<password>" | podman login docker.io -u "jlphillips@lbl.gov" --password-stdin`

**MANDATORY — GLOBAL RULE: Always use full SHA256 digests when referencing Docker/container images. NEVER use bare tags. This applies everywhere without exception: WDL runtime fields, shifterimg pull, Dockerfiles, scripts, CLI commands, everything.**
- Tags are mutable and non-deterministic — they resolve differently across nodes and change as images are updated.
- Always write: `image@sha256:<full-64-char-hex-digest>`
- Never write: `image:tag` or `image:tag@sha256:...` (tag portion is ignored by Shifter)
- After `podman push`, always compute the digest with the curl+python3 manifest hash method from `~/.claude/podman-perlmutter-guide.md`
- Before running any workflow, verify every image digest in every WDL task is pre-pulled in Shifter.
- Verify ready: `shifterimg images | grep <short-digest>` — status must be READY

**For interactive R/Python work, use `module load` and local package installs (`install.packages()` / `pip install --target`) — not Shifter containers.** Shifter/container instructions above apply only to WDL pipelines and Docker image builds.

**ABSOLUTE RULE: Always ask before killing a long-running process or deleting data.**
- Before running `screen -X quit`, `kill`, `pkill`, `scancel`, `DROP`, `TRUNCATE`, `DELETE FROM`, `rm -rf`, or any other action that stops an active process or destroys existing data, STOP and ask the user first.
- "I can just restart it" is NOT a justification — the user may have reasons (in-flight progress, lock state, side effects, timing) that make the kill worse than waiting.
- This applies even when the action seems obviously correct or reversible. The user decides, not you.
- Exception: you may clean up processes YOU just launched that failed to start properly (e.g. an empty-output subprocess from 10 seconds ago). Anything the user is aware of or has been running >1 minute: ask.

**ABSOLUTE RULE: Always run anything that touches shared state in `screen` or `tmux`. Foreground is forbidden. Every launch MUST register where it's running.**
- This applies to ANY operation that interacts with a database, MongoDB, files in shared paths, or any other shared resource — regardless of expected duration. "It'll only take a minute" is NOT a valid exception.
- Foreground feels safer because you see output, but the moment the Claude Code session, the SSH connection, or the user's terminal ends, the work dies — possibly leaving partial writes, inconsistent state, or half-loaded collections that look complete but aren't.
- Pattern: write a self-contained shell script that logs all output to a file under `$SCRATCH`, then `screen -dmS jobname bash /path/to/script.sh`.
- **Recording the launch node is MANDATORY**, not optional. Every wrapper script's FIRST lines (before any other work) MUST be:
  ```
  LOG=/path/to/job.log   # absolute path under $SCRATCH
  echo "Running on $(hostname) at $(date) PID=$$ SCRIPT=$0" > "$LOG"
  ```
  This log line is the system of record for "where is this job running." Without it, the job is unfindable across login nodes and the pre-launch overlap check (next rule) cannot work.
- After launching a screen, always wait 3-5 seconds, then read the log file and verify the "Running on …" line is present. If it's not, the launch failed — debug; do NOT relaunch blindly.
- `nohup` alone is NOT sufficient — use screen/tmux.
- Read-only audits (no writes anywhere) are the only exception; they may run in foreground if they take <30s and cannot leave inconsistent state.

**ABSOLUTE RULE: Pre-launch overlap check is ALWAYS multi-node, ALWAYS based on recorded job locations.**
- Before launching ANY process (background shell, screen session, or foreground command), VERIFY that no existing process is already doing the same work, anywhere across all login nodes.
- **Single-node `pgrep`/`screen -ls` is INSUFFICIENT** because Perlmutter has many login nodes and a screen session on a different node is invisible from here.
- **The check is driven by the recorded job locations, not by a blanket scan.** Required procedure:
  1. Identify all log files for jobs of the same kind (`ls /path/to/*<job>.log`).
  2. For each, grep `^Running on (login\d+)` to extract the recorded hostname.
  3. ssh ONLY to those recorded nodes and run `screen -ls | grep <screen-name>; pgrep -f <script>`.
  4. If any match, the job is still active — STOP, do not launch.
- A blanket `for h in login01..login40; ssh $h ...` loop is a forensic fallback (e.g., when no log exists), NOT a routine pre-launch check. Routine checks must use the recorded locations.
- For long-running pipeline work, a **cross-node advisory lock** (MySQL `GET_LOCK`, the project's `pipeline_lock` context manager) is preferred over log-based checks — it's atomic and self-cleaning.
- If a previous attempt appears stuck or produced no output, INVESTIGATE before retrying. Check the recorded log file, the recorded host's screen listing, file sizes, exit codes. Do not assume failure from empty output.
- **NEVER conflate output from one screen-related command with another.** If `screen -X -S A quit` says "No screen session found", that is about screen `A`, NOT about a different screen `B` you launched moments ago. Verify `B` explicitly via the log file's "Running on …" line + an ssh to that host's `screen -ls | grep B`.
- Never launch a second process that writes to the same files, databases, or collections as a running process. This causes data corruption that often looks like duplicates (e.g. 2× expected row count).
- If you must retry, explicitly kill/stop the previous attempt first and confirm it is dead via positive evidence (the recorded host's screen listing no longer shows it AND its log shows a clean exit).
- One process, one job. Period.

**Perlmutter has many login nodes — NEVER use `ps` or `pgrep` to check if a process is running.**
- You may be on a different login node than the one running the process.
- Always use log files and `squeue` to check pipeline status.
- **BEFORE launching any long-running process (screen, nohup, etc.), always check whether one is already running.** Check the relevant log file for a hostname, ssh to that node, and confirm no existing session is active. Killing a duplicate is cheap; letting two processes run simultaneously can corrupt data and is very hard to detect.
- When launching a long-running process (screen, nohup, etc.), log the login node with `echo "Running on $(hostname)"` so you know where to find it later.
- After launching, always report the node to the user explicitly (e.g. "Running on login37").
- To attach to a screen session on a specific login node: `ssh login_node_name` then `screen -r session_name`.
- When looking for a running process, ALWAYS check the log file first for the hostname — never do a broad scan of all nodes when the hostname is already recorded in a log.

**NEVER USE `/tmp` — EVER. This is an absolute rule with no exceptions.**
- `/tmp` is forbidden on Perlmutter. Do not use it for any purpose under any circumstances.
- Do not suggest it, do not use it as a workaround, do not use it "just for a build" or "just temporarily."
- If you are about to write `/tmp` anywhere in a command or script, stop and find another approach.
- **The only approved scratch space is `$SCRATCH` (pscratch).** Use it for all job output, logs, temporary files, and build intermediates.

**`$TMPDIR` is NOT node-local on Perlmutter compute nodes.**
- `$TMPDIR` is on the shared GPFS/Lustre filesystem, counts against inode and storage quotas, and is visible across nodes.
- Do NOT use it as a local scratch space expecting it to be fast or quota-free.

**Debug queue constraints (Perlmutter):**
- Max 5 submitted jobs total (running + pending) — the 6th submission is rejected by SLURM.
- Max 2 jobs running simultaneously.
- Max 29-minute wall time — use `--time=00:29:00`.

**Check storage and inode usage with `myquota`.**
- pscratch has separate inode and capacity limits. Inode exhaustion is a silent killer — check before large runs.

**SLURM `--exclusive` allocates a full CPU node: 128 cores / 256 hardware threads.**

**Bash `&` backgrounding in a SLURM batch script only runs on the primary node, even with `-N 2`.**
- Worker nodes sit completely idle — you waste 100% of their allocation.
- To actually use multiple nodes, you must dispatch work explicitly with `srun --nodelist=<node>` or use a proper parallel launcher (MPI, etc.).
- Default to `-N 1` for bash-backgrounded workloads. Only use `-N >1` if you are explicitly dispatching with `srun`.
