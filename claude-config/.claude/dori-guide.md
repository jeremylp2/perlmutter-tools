# dori access guide (from Perlmutter)

dori = JGI compute cluster (`jgi-interactive07.jgi.lbl.gov`, user `jlphillips`); it runs the
JAWS `dori-prod` Cromwell backend. **Login requires password + MFA** (no key-only auth), so
Claude cannot `ssh dori` non-interactively on its own. The user sets up SSH connection
multiplexing once; Claude then reuses the authenticated master.

## Filesystem isolation (critical)
- **dori has NO access** to NERSC `/global/cfs` or `/global/dna`.
- **Perlmutter has NO access** to dori `/clusterfs`.
- They are mutually inaccessible → move files with `scp` over the SSH mux (below). Build
  (shifter) and deploy-to-`/global/dna` (via dtn01) must happen on Perlmutter; dori is
  source/record only.

## One-time setup (connection multiplexing)
1. Add to `~/.ssh/config` (shared home):
   ```
   Host dori
       HostName jgi-interactive07.jgi.lbl.gov
       User jlphillips
       ControlMaster auto
       ControlPath ~/.ssh/cm-%r@%h:%p
       ControlPersist 8h
       ServerAliveInterval 60
   ```
2. **From the SAME login node Claude's Bash tool runs on** (the control socket is host-local —
   ask Claude `hostname`; e.g. `login13`): establish a **master-only** connection, NOT an
   interactive shell:
   ```
   ssh -fNM dori        # -N no shell, -f background, -M master; authenticate (password+MFA) once
   ```
   Why `-fNM`: dori's sshd has **`MaxSessions 1`**. An interactive `ssh dori` consumes the one
   session slot, so Claude's muxed commands get `mux_client_request_session: Session open
   refused by peer`. `-N` holds the master with **no** session, freeing the slot for commands.
3. Verify: `ssh -O check dori` → "Master running (pid=…)".

After that, Claude can run `ssh -o BatchMode=yes dori '<cmd>'` and `scp dori:/path local`
over the master — **sequentially** (MaxSessions=1, so no parallel dori sessions).
Tear down with `ssh -O exit dori`.

## Useful dori paths
- JAWS run staging (annotation pipelines — Correct_CCS/pTran/etc., NOT JBPrivate):
  `/clusterfs/jgi/scratch/science/wcplant/phytzm-jaws/{szaman,tbruna}/<run_id>/<uuid>/`
  (each has `inputs.json`, `metadata.json`; key format `"<WorkflowName>.<input>"`).
- JBPrivate Cromwell execution: `/clusterfs/jgi/scratch/dsi/aa/jaws/dori-prod/cromwell-executions/JBPrivate/<uuid>/`
  (auto-purged; usually only very recent runs survive).
- Annotation data (mirror of cfs `/global/cfs/cdirs/plantbox/annotation`):
  `/clusterfs/jgi/groups/science/wcplant/annotation/<Species>/.../0X_jbrowse/[hap]/` —
  holds the per-browser JBPrivate `input.json` (the persistent record of each private
  browser's build inputs).

## Gotchas
- The SSH banner is verbose; filter it from command output.
- The control socket is bound to one login node; if Claude's tool moves to a different login
  node the mux won't be found (use `-o BatchMode=yes` so it fails fast instead of prompting).
- Banner/`Permission denied` in output = the mux was NOT used (master down or wrong node /
  MaxSessions). Re-establish with `ssh -fNM dori`.
