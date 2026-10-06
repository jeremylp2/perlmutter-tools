# Portable, image-baked CHADO load pipeline (Perlmutter + dori)

## Context
The CHADO load pipeline must run as a **self-contained baked container image** on both
Perlmutter (shifter) and dori (apptainer), from one shared worklist, host-routed, with two
absolute requirements:

- **A. Zero hardcoded path used at runtime** — everything portable/config-driven. Hardcoded
  values allowed only as fallbacks the pipeline never reaches.
- **B. Zero code loaded from outside the image** — every module/script the tasks import or
  exec resolves to the baked `/usr/local/compgen` or the conda `chado` env. No `/global/common`,
  `/global/dna`, `/clusterfs`, checkout, or another user's home.

The base is the **working Perlmutter pipeline** (correct 256-line `loadFasta.pl`, all current
verify gates), already rebuilt as a **minimal baked image** (load dependency closure only, no
code bind-mounts) on branch `chado_load_rebuild`. The **system-agnostic dori portability** was
already built on `switching_chado_load` (commits 210b9bb7, 412d1536, fe5f41c0, c58d4d7a); this
plan **re-layers that machinery onto the baked base — minus its one repo bind-mount**, which the
image replaces. Net: do exactly what was asked hours ago, now reconciled with the no-code-mount
and no-hardcoded-path rules.

All work stays on `chado_load_rebuild`, **local commits only (no GitLab push)**; the portable
result is later moved onto `switching_chado_load` "in place of what was there". Perlmutter dev
end-to-end first, then prod smoke, then dori.

## Already done this session (uncommitted, on `chado_load_rebuild`)
- Minimal image built (570-file closure; separate graphroot `$SCRATCH/podman_v1/storage`).
- `chado_load_existing_genome_ok.wdl:516,1014` — verify scripts invoked from `/usr/local/compgen` (image).
- `chado_paths.wdl` — `dori_top_path` → `/usr/local/compgen/`.
- `verify_proteome_complete.py` — `staging_root = os.environ.get("PORTAL_STAGING_ROOT", <prod fallback>)`.

## Changes (file-by-file)

### 1. `data_wrangling/CHADOio/pipeline/wdl/chado_load_existing_genome_ok.wdl`
- **Req A:** lines 515, 1013 `export CHADOCONF=/global/cscratch1/p/phillips/.chadoconf` →
  `export CHADOCONF="$HOME/.chadoconf"` (matches old port; `$HOME`-portable).
- **Req A:** remove all **25** `mountOption: "-V ~{config_path}:/global/cscratch1"` — they existed
  only to expose home at that hardcoded path. Config now reaches the container via its **HOME**
  (shifter auto-mounts home on Perlmutter; apptainer `--home` on dori). This eliminates every
  `/global/cscratch1` reference. `config_path` input becomes unused (drop from tasks + `init`).
- **Req A:** `verify_proteome_complete` task — add `String portal_path` input; in the command add
  `export PORTAL_STAGING_ROOT=~{portal_path}`; workflow call passes `portal_path = init.portal_path`
  (dev-aware). Prod path stays only as the script's unused fallback.
- **Req B:** line 1075 — remove `--jamo_path /global/common/software/m342/jamo/prod/lib/python`.
- **Req #4:** all 25 `docker:` lines — replace `chado_load@sha256:ebe45fcf…` with the new
  `compgen_chado_load@sha256:<new digest>` (**full digest, never a tag**).
- `~/.sapsconfig` (402/862/896), `~/.slack_bot_token` (1108) — leave `~`-relative (portable via HOME).

### 2. `data_wrangling/CHADOio/pipeline/wdl/chado_paths.wdl`
- Keep `top_path = "/usr/local/compgen/"` (image). Keep `dev_mode`/`dev_portal_path`/`portal_path`
  (dev-aware). Drop `config_path` if now unused. **Do not** re-add `repo_root`/home-shim binding of
  code (conflicts with no-code-mount); site portal roots stay inputs with unreachable defaults.

### 3. `data_wrangling/CHADOio/pipeline/registerLoadedGenome.py`  (Req B)
- Change `--jamo_path` default (line 28) and the child invocation (line 114
  `PYTHONPATH={jamo}... python jamo_<pac>`) so the child `python jamo_<pac>` runs with **no
  external PYTHONPATH** and imports the **baked `sdm_curl`** (conda `chado` env). `updateATAP.pl`,
  `updatePMOProjectStatus.pl`, `jamoProteomeFiles.py` are already baked and invoked via
  `$RealBin/..` (image) — no change.

### 4. Perlmutter conf `/global/homes/p/phillips/chado_load_perlmutter_slurm.conf`
- With `mountOption` removed, `${mountOption}` expands empty — drop that line. Keep
  `-V .../refdata:/refdata`. Config reaches the container via shifter's HOME auto-mount (proven:
  perl reads `~/.chado.conf` today). WDL `docker:` pinned to the new digest; pre-pull into shifter.

### 5. Dori conf `data_wrangling/CHADOio/pipeline/wdl/chado_load_dori.conf`  (re-layer, no code mount)
- Re-add from `switching_chado_load` **but drop `--bind $REPO:/usr/local/compgen`** (forbidden).
- `apptainer exec --cleanenv --home "$HOME" --bind <cwd>,<refdata>[,translated binds] <SIF> ...`.
  `--home "$HOME"` both sets `HOME` and mounts the running user's home so all six dotfiles resolve.
- **SIF built and referenced by the image digest** (never a tag). Bind **no code**.

### 6. Trigger / job / systemd (re-layer system-agnostic parts from `switching_chado_load`)
- Re-add `run_chado_load_trigger_dori.sh`, `run_chado_load_job_dori.sh`,
  `install_dori_systemd_timer.sh`, `data_wrangling/utils/send_email.py`.
- Env-parametrization: `CHADO_LOAD_BASE`/`CHADO_LOAD_REPO` derived from the trigger's own location;
  slurm account/qos/java/jamo_server/dev_mode/env_label from `~/.chadoconf [chado_load]`.
- **Req A:** fix `run_chado_load_trigger.sh:49` / `run_chado_load_job.sh:41`
  `SENDSLACK=/global/homes/p/phillips/git/compgen/...` — derive from `$CHADO_LOAD_REPO` (or the
  script's own dir), not a personal absolute.

### 7. `~/.chadoconf` config schema (so no path/setting is hardcoded)
- `[chado]`, `[metadata]` — DB creds (already used by python).
- `[site]` — `owned_path_prefixes` (host routing), any container_binds.
- `[chado_load]` — `slurm_account`, `slurm_qos`, `java`, `jamo_server`, `dev_mode`, `env_label`,
  and (dori) `home_shim` if needed. Perlmutter and dori differ only by this file + `$HOME`.

## Verification (Perlmutter dev-only first, then prod smoke, then dori)
1. Rebuild the minimal image with the script edits (separate graphroot, cached conda/pip layers);
   push to container registry; take the **Docker-Content-Digest**; pin it in the WDL; commit locally.
2. In-image proof (no external/hardcoded code): `perl -c` every root `.pl`; `use CHADO::Schema;
   use CHADO::Dataset` (exercises `load_classes` + `_load_class` dynamic loads); `import PlantChado`,
   `plantchadosession`, `ConfigMetadata`, `sdm_curl`; grep the image tree for any non-`/usr/local/
   compgen` code path.
3. Pre-pull the digest into shifter (READY).
4. Dev config: `~/.chadoconf` → dev DBs + `[site] owned_path_prefixes` + `[chado_load] dev_mode=true`;
   pick an existing-genome test proteome; confirm nothing touches prod.
5. Run dev end-to-end: `set_pac → load_fasta → load_gff → verify_load_gff_counts → … →
   verify_proteome_complete` (with `PORTAL_STAGING_ROOT` = dev). `register_loaded_genome` dev-skipped.
6. Prod smoke (`dev_mode=false`) on one proteome — the only path exercising baked `sdm_curl` in
   `register_loaded_genome` (`python jamo_<pac>`, no external PYTHONPATH).
7. Dori (separate): **empirically verify** svc-plant's home is visible on dori compute nodes
   (`apptainer exec --home "$HOME" $SIF ls ~/.chadoconf`). If yes → `--home "$HOME"`. If not →
   `[chado_load] home_shim` on `/clusterfs` holding the 6 dotfiles, `--home "$HOME_SHIM":"$HOME"`
   (still `$HOME`-relative inside, still no code bind). Build SIF by digest; place dotfiles; install
   the systemd timer (svc-plant, ln010); fire one tick.

## Constraints (non-negotiable)
- No code bind-mounts, ever (image `/usr/local/compgen` only).
- No hardcoded path used at runtime; fallbacks only if unreachable.
- No external code path.
- WDL `docker:` = full sha256 digest, always.
- Image tags = versions; provenance in labels; Dockerfile at `pipeline/docker/Dockerfile`.
- Local commits only; **no GitLab push**. Container-registry push OK.
