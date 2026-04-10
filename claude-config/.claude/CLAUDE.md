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

## Perlmutter / Shifter

**If the user asks you to do anything involving JAWS, read `~/.claude/jaws-guide.md` before proceeding.**

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

**ABSOLUTE RULE: Always run long-running processes fully detached. NOTHING may depend on a Claude Code session or SSH session remaining open.**
- Write a self-contained shell script that logs all output to a file.
- Launch it in a `screen` or `tmux` session so it survives logout.
- Example: `screen -dmS jobname bash /path/to/script.sh`
- `nohup` alone is NOT sufficient — use screen/tmux.
- This applies to ALL long-running operations: DB queries, file copies, pipeline submissions, builds — everything.

**ABSOLUTE RULE: Never launch overlapping processes that do the same work.**
- Before launching ANY process (background shell, screen session, or foreground command), check that no existing process is already doing the same work. Check: screen -ls, pgrep, and Claude Code's own task list.
- If a previous attempt appears stuck or produced no output, INVESTIGATE before retrying. Check file sizes, wait for completion, check exit codes. Do not assume failure from empty output — it may be buffered I/O or a pipe filter swallowing results.
- Never launch a second process that writes to the same files, databases, or collections as a running process. This causes data corruption.
- If you must retry, explicitly kill/stop the previous attempt first and confirm it is dead.
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
